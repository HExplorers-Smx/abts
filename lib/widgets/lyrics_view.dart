import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_theme.dart';
import '../models/lyric_line.dart';
import '../player/book_player.dart';
import '../services/bili_api.dart';
import '../services/download_store.dart';
import '../services/lyrics_parser.dart';

/// 仿 folia-major「Monet」歌词效果。
///
/// 还原要点（参数取自 folia-major 源码）：
/// - 当前行居中高亮，其余行按距离缩小 / 变暗 / 模糊（resolveLineTone 的移植）；
/// - 当前行**逐字点亮**（MonetRailTokens 方案）：未唱到的字保持暗色、
///   正在唱的字从暗色渐变成主题亮色并带辉光脉冲、唱过的字保持主题亮色
///   并随辉光缓慢驻留衰减（resolveMonetGlow 的 Smoothstep 起峰/驻留/衰减）；
/// - 上下渐隐遮罩；整轨用 SpringSimulation 弹簧滚动（folia MONET_SCROLL_SPRING）；
/// - 支持手动上下拖动浏览歌词，1.8s 无操作自动回到跟随（folia idle reset）；
/// - 全局歌词偏移（设置页可调 ±1.5s，保存本机，folia lyricOffsetMemory 的移植）；
/// - 点击歌词行跳转播放，点击空白区域切回封面。
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.player, this.onToggleCover});

  final BookPlayer player;
  final VoidCallback? onToggleCover;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  // ---------- 布局/动效参数（对应 folia monetRailLayout / monetLyricMotion） ----------
  // folia 当前行字号较大、行内上下留白充分（textPaddingTop=fontPx*0.16 /
  // textPaddingBottom=fontPx*0.34），前后各保留 1~2 行即可（before:1 after:1）
  static const double _fontSize = 20;
  static const double _lineHeight = 1.5;
  static const double _inactiveGap = 22;
  static const int _visibleBefore = 2;
  static const int _visibleAfter = 2;
  static const double _glowPad = 10;
  static const double _inactiveScale = 0.84; // ≈ inactiveFontPx / lyricFontPx
  // folia MONET_SCROLL_SPRING：过阻尼弹簧（无回弹、平滑趋近）
  static const SpringDescription _spring = SpringDescription(
    mass: 0.82,
    stiffness: 142,
    damping: 28,
  );
  /// 手动滚动后无操作多久自动回到跟随模式（folia MONET_SCROLL_IDLE_RESET_MS）
  static const Duration _idleReset = Duration(milliseconds: 1800);
  /// 手动滚动最大范围（像素，上下约各 4 屏歌词）
  static const double _manualClampPx = 1200;

  // ---------- 状态 ----------
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _timeSec = 0;
  bool _playing = false;
  double _rate = 1;

  /// 全局歌词偏移（ms，设置页可调）：正数=歌词提前显示（字幕比声音晚时往正调）
  double _offsetMs = 0;

  String? _loadedKey;
  List<LyricLine>? _lines;
  bool _loading = false;
  String? _error;

  /// 本地章节未配文稿（区别于在线书「本集确实没有文稿」）
  bool _noLyrics = false;

  /// 文本行高测量缓存（文本 + 宽度 -> 高度）
  final Map<String, double> _heightCache = {};

  /// 加权逐字时间起点缓存（标点停顿感知，按行文本缓存）
  final Map<String, List<double>> _charStartCache = {};

  // ---------- 轨道滚动（folia：弹簧跟随 + 手动浏览 + idle 复位） ----------
  late final AnimationController _scrollCtrl =
      AnimationController.unbounded(vsync: this)
        ..addListener(_onScrollValue);
  late final AnimationController _manualCtrl =
      AnimationController.unbounded(vsync: this)
        ..addListener(_onManualValue);

  /// 跟随滚动的当前偏移（弹簧驱动，目标 = 让当前行中心到焦点线）
  double _offsetY = 0;
  /// 手动浏览偏移（垂直拖动产生，idle 后弹簧归零）
  double _manualPx = 0;
  /// 当前跟随目标（避免对同一目标重复启动弹簧）
  double _scrollTarget = double.nan;
  Timer? _manualTimer;

  // ---------- 生命周期 ----------
  @override
  void initState() {
    super.initState();
    _playing = widget.player.isPlaying;
    _rate = widget.player.rate;
    _timeSec = widget.player.currentPosition.inMilliseconds / 1000.0;
    _ticker = createTicker(_onTick);
    if (_playing) _ticker.start();
    widget.player.positionTick.addListener(_onPosition);
    widget.player.addListener(_onPlayerChanged);
    // 读取用户设置里的全局歌词偏移（folia lyricOffsetMemory 的简化版）
    SharedPreferences.getInstance().then((p) {
      final v = p.getInt('lyrics_offset_ms');
      if (!mounted) return;
      setState(() => _offsetMs = (v ?? 0).toDouble());
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _manualTimer?.cancel();
    _scrollCtrl.dispose();
    _manualCtrl.dispose();
    widget.player.positionTick.removeListener(_onPosition);
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  // ---------- 轨道滚动 ----------
  void _onScrollValue() {
    _offsetY = _scrollCtrl.value;
    if (mounted) setState(() {});
  }

  void _onManualValue() {
    _manualPx = _manualCtrl.value;
    if (mounted) setState(() {});
  }

  /// 弹簧滚到目标偏移（folia MONET_SCROLL_SPRING）
  void _animateOffset(double target) {
    _scrollCtrl.animateWith(
      SpringSimulation(_spring, _offsetY, target, 0),
    );
  }

  /// 手动浏览：拖动时累加偏移，超过 idle 时长后自动复位跟随
  void _onManualDragUpdate(DragUpdateDetails d) {
    _manualPx =
        (_manualPx + d.delta.dy).clamp(-_manualClampPx, _manualClampPx);
    _manualTimer?.cancel();
    _manualTimer = Timer(_idleReset, _resetManual);
    if (mounted) setState(() {});
  }

  void _onManualDragEnd(DragEndDetails d) {
    _manualTimer?.cancel();
    _manualTimer = Timer(_idleReset, _resetManual);
  }

  void _resetManual() {
    _manualTimer?.cancel();
    _manualTimer = null;
    _manualCtrl.animateWith(SpringSimulation(_spring, _manualPx, 0, 0));
  }

  void _onPlayerChanged() {
    final playing = widget.player.isPlaying;
    final rate = widget.player.rate;
    if (playing != _playing) {
      _playing = playing;
      if (playing) {
        _timeSec = widget.player.currentPosition.inMilliseconds / 1000.0;
        _lastTick = Duration.zero;
        _ticker.start();
      } else {
        _ticker.stop();
      }
    }
    if (rate != _rate) _rate = rate;
    _maybeLoad();
    if (mounted) setState(() {});
  }

  /// 播放位置流：校准（seek / 换章 / 播放器回传）
  void _onPosition() {
    _timeSec = widget.player.currentPosition.inMilliseconds / 1000.0;
    // 重置插值基准：下一个 tick 从校准点重新开始累计，避免位置流
    // 滞后/回跳时插值继续沿着旧轨迹漂移
    _lastTick = Duration.zero;
    if (mounted) setState(() {});
  }

  /// 高频时钟：在两次位置流之间插值，保证扫字/辉光平滑
  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      // 刚被位置流校准：本帧只记录基准，不累加（避免一次性吞掉大 dt）
      _lastTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (!_playing) return;
    if (dt <= 0) return;
    // 单帧上限 0.25s：卡顿帧不丢弃也不暴走，继续累计
    _timeSec += math.min(dt, 0.25) * _rate;
    if (mounted) setState(() {});
  }

  /// 应用全局偏移后的"校准时间"（参与行索引与逐字点亮）
  double get _t => _timeSec + _offsetMs / 1000.0;

  // ---------- 字幕加载 ----------
  void _maybeLoad() {
    final book = widget.player.book;
    final chapter = widget.player.currentChapter;
    if (book == null || chapter == null) return;
    final key = '${book.bvid}/${chapter.cid}';
    if (key == _loadedKey) return;
    _loadedKey = key;
    _loading = true;
    _error = null;
    _noLyrics = false;
    _lines = null;
    _fetch(key, book.bvid, chapter.cid);
  }

  Future<void> _fetch(String key, String bvid, int cid) async {
    try {
      // 本地导入的书：优先读章节同目录的 `<音频名>.lyrics.json`
      // （用户通过章节页「文稿」导入的 txt/LRC/SRT 解析产物，离线可用）
      if (bvid.startsWith('local_')) {
        List<LyricLine>? lines;
        final localPath = widget.player.currentChapter?.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          try {
            lines = LyricsParser.readLyricsFile(File(localPath));
          } catch (_) {}
        }
        if (!mounted || _loadedKey != key) return;
        setState(() {
          _lines = lines ?? <LyricLine>[];
          _loading = false;
          // 没有文稿：显示引导占位而非空白
          _noLyrics = lines == null || lines.isEmpty;
        });
        return;
      }
      // 本地优先：已下载章节直接读随音频落盘的文稿文件（离线可用）
      List<LyricLine>? lines;
      try {
        lines = await DownloadStore.instance.localLyricsFor(bvid, cid);
      } catch (_) {}
      // 没有本地文稿（未下载/旧版下载/该书无文稿）→ 在线调 B 站 AI 字幕生成
      lines ??= await BiliApi.instance.fetchLyrics(bvid, cid);
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _lines = lines;
        _loading = false;
        _noLyrics = false;
      });
    } catch (e) {
      debugPrint('[LyricsView] 文稿获取失败: $e');
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _error = '文稿获取失败，点此重试';
        _loading = false;
      });
    }
  }

  void _retry() {
    _loadedKey = null;
    _maybeLoad();
    setState(() {});
  }

  // ---------- 时间同步 ----------
  int _activeIndexFor(List<LyricLine> lines, double t) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].start <= t) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans < 0 ? 0 : ans;
  }

  void _seekTo(LyricLine line) {
    _timeSec = line.start; // 先立即响应，等播放器回传校准
    setState(() {});
    widget.player.seek(line.startDuration);
  }

  /// 长按歌词：现场微调同步偏移（边听边调，±50ms 一档，全局保存）
  Future<void> _showOffsetAdjuster() async {
    var value = _offsetMs.toInt();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('歌词同步偏移',
              style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value == 0
                    ? '对齐（0 ms）'
                    : value > 0
                        ? '提前 $value ms'
                        : '延后 ${-value} ms',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.accent),
              ),
              const SizedBox(height: 12),
              Slider(
                value: value.toDouble(),
                min: -1500,
                max: 1500,
                divisions: 60,
                activeColor: AppTheme.accent,
                inactiveColor: AppTheme.divider,
                label: '$value ms',
                onChanged: (v) {
                  value = (v / 50).round() * 50;
                  setDialogState(() {});
                },
              ),
              const SizedBox(height: 4),
              Text(
                '歌词比声音快 → 往正调；\n歌词比声音慢 → 往负调。±50ms 一档，边听边试。',
                style: TextStyle(
                    fontSize: 11, color: AppTheme.textHint, height: 1.5),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                value = 0;
                setDialogState(() {});
              },
              child: Text('重置', style: TextStyle(color: AppTheme.textSub)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('保存', style: TextStyle(color: AppTheme.accent)),
            ),
          ],
        ),
      ),
    );
    if (value != _offsetMs.toInt()) {
      final p = await SharedPreferences.getInstance();
      await p.setInt('lyrics_offset_ms', value);
      if (!mounted) return;
      setState(() => _offsetMs = value.toDouble());
    }
  }

  // ---------- 样式 ----------
  TextStyle _textStyle({bool active = false}) => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
        color: AppTheme.textMain,
      );

  Color get _baseColor => AppTheme.textMain.withValues(alpha: 0.34);
  Color get _brightColor => AppTheme.textMain;
  Color get _glowAccent =>
      AppTheme.isDark ? AppTheme.accentSoft : AppTheme.accentDeep;

  double _measureHeight(String text, double maxWidth) {
    final key = '$text|${maxWidth.toStringAsFixed(1)}';
    return _heightCache.putIfAbsent(key, () {
      final painter = TextPainter(
        text: TextSpan(text: text, style: _textStyle()),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      return painter.height;
    });
  }

  // ---------- 构建 ----------
  @override
  Widget build(BuildContext context) {
    _maybeLoad();
    final lines = _lines;
    if (lines == null) {
      return _statusBox(
        _error != null ? _error! : '正在获取文稿…',
        loading: _loading,
      );
    }
    if (lines.isEmpty) {
      return _statusBox(
        _noLyrics
            ? '本章暂无文稿\n去章节页点「文稿」导入 txt / LRC / SRT\n（点空白返回封面）'
            : '本集暂无文稿\n（点空白返回封面）',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final railW = constraints.maxWidth;
        final railH = constraints.maxHeight;
        final active = _activeIndexFor(lines, _t);
        final maxTextW = math.max(railW - 24, 80).toDouble();

        // 全量行高（≤40 行，走测量缓存）
        final hs = <double>[];
        for (final l in lines) {
          hs.add(_measureHeight(l.text, maxTextW) + _glowPad * 2);
        }
        // 绝对坐标：从第 0 行顶排起，与 active 无关 → 换行时内容不跳变，
        // 整轨由弹簧 translate 平滑滚动（folia 轨道方案）
        final absTop = <double>[];
        var acc = 0.0;
        for (var i = 0; i < lines.length; i++) {
          absTop.add(acc);
          if (i < lines.length - 1) acc += hs[i] + _inactiveGap;
        }
        // 跟随目标：当前行中心落在焦点线（railH * 0.46）
        final target = railH * 0.46 - (absTop[active] + hs[active] / 2);
        if (_scrollTarget.isNaN) {
          // 首帧直接落位，避免入场弹跳
          _scrollTarget = target;
          _offsetY = target;
        } else if (target != _scrollTarget) {
          _scrollTarget = target;
          _animateOffset(target);
        }
        final totalTranslate = _offsetY + _manualPx;
        final first = math.max(0, active - _visibleBefore);
        final last = math.min(lines.length - 1, active + _visibleAfter);

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onToggleCover,
          onLongPress: _showOffsetAdjuster,
          onVerticalDragUpdate: _onManualDragUpdate,
          onVerticalDragEnd: _onManualDragEnd,
          child: ClipRect(
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black,
                  Colors.black,
                  Colors.transparent,
                ],
                stops: [0.0, 0.10, 0.90, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: SizedBox(
                width: railW,
                height: railH,
                child: Transform.translate(
                  offset: Offset(0, totalTranslate),
                  child: Stack(
                    children: [
                      for (var i = first; i <= last; i++)
                        _buildLine(
                          i,
                          lines,
                          active,
                          absTop[i] - absTop[first],
                          hs[i],
                          maxTextW,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLine(
    int i,
    List<LyricLine> lines,
    int active,
    double top,
    double h,
    double maxTextW,
  ) {
    final isActive = i == active;
    final d = (i - active).abs();
    final tone = _resolveTone(isActive, i > active, d);
    final line = lines[i];

    return Positioned(
      top: top,
      left: 12,
      right: 12,
      child: RepaintBoundary(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _seekTo(line),
          child: Transform.scale(
            alignment: Alignment.topLeft,
            scale: tone.scale,
            child: Opacity(
              opacity: tone.opacity,
              child: _blur(tone.blur, _lineContent(line, isActive, maxTextW, h)),
            ),
          ),
        ),
      ),
    );
  }

  /// 行色调：当前行 1.0；等待/已过行随距离衰减（folia resolveLineTone）
  ({double opacity, double scale, double blur}) _resolveTone(
    bool isActive,
    bool waiting,
    int d,
  ) {
    if (isActive) return (opacity: 1, scale: 1, blur: 0);
    final scale =
        (_inactiveScale * math.pow(0.9, d - 1)).clamp(0.68, 0.92).toDouble();
    if (waiting) {
      return (
        opacity: (0.72 - (d - 1) * 0.18).clamp(0.36, 0.72).toDouble(),
        scale: scale,
        blur: d == 1 ? 0.7 : 1.8 + (d - 2) * 0.8,
      );
    }
    return (
      opacity: (0.52 - (d - 1) * 0.12).clamp(0.28, 0.52).toDouble(),
      scale: scale,
      blur: 1.1 + (d - 1) * 0.7,
    );
  }

  Widget _blur(double sigma, Widget child) {
    if (sigma < 1.2) return child;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
  }

  /// 逐字点亮（folia MonetRailTokens 方案）：
  /// 未唱到的字 = 暗色；正在唱的字 = 暗色→主题亮色渐变 + 辉光脉冲；
  /// 唱过的字 = 主题亮色 + 辉光驻留缓慢衰减。
  /// 时间分配：整句时间均分到每个字符（folia buildEvenGraphemeTimings 同款兜底）。
  Widget _lineContent(
    LyricLine line,
    bool isActive,
    double maxTextW,
    double h,
  ) {
    if (!isActive) {
      return SizedBox(
        width: maxTextW,
        height: h,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: _glowPad),
          child: Text(
            line.text,
            style: _textStyle().copyWith(color: _baseColor),
          ),
        ),
      );
    }

    final text = line.text;
    final t = _t;
    final n = text.length;
    // 加权逐字时间起点：标点前的字分配更长（朗读会在标点处停顿），
    // 长句的扫字节奏比"纯均分"更贴语感（folia 对无逐字 timing 的
    // 数据也做感知分配，而不是机械均分）
    final starts = _weightedStarts(line);
    // 行渲染结束时间：至少本行 end+1.05s，且不早于下一句开始（folia renderEndTime）
    final lineEnd = line.end + 1.05;
    final spans = <TextSpan>[];
    for (var i = 0; i < n; i++) {
      final s = starts[i];
      final e = starts[i + 1];
      final glow = _charGlow(t, s, e, lineEnd);
      final status =
          (t < s ? 0 : (t < e ? (t - s) / math.max(0.001, e - s) : 1))
              .toDouble();
      Color color;
      if (status >= 1) {
        // 唱过：主题亮色（folia resolvedBaseColor = wordColor）
        color = _sungColor;
      } else if (status > 0) {
        // 正在唱：暗色 → 主题亮色渐变（folia mixColors(base, word, progress)）
        color = Color.lerp(_baseColor, _sungColor, status)!;
      } else {
        color = _baseColor;
      }
      spans.add(TextSpan(
        text: text[i],
        style: TextStyle(
          color: color,
          shadows: glow > 0.02
              ? [
                  Shadow(
                    color: Color.lerp(_baseColor, _glowAccent, glow)!
                        .withValues(alpha: 0.85 * glow),
                    blurRadius: _fontSize * 0.22,
                  ),
                  Shadow(
                    color: Color.lerp(_baseColor, _glowAccent, glow)!
                        .withValues(alpha: 0.6 * glow),
                    blurRadius: _fontSize * 0.5,
                  ),
                ]
              : null,
        ),
      ));
    }

    return SizedBox(
      width: maxTextW,
      height: h,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _glowPad),
        child: Text.rich(
          TextSpan(children: spans),
          style: _textStyle(active: true),
        ),
      ),
    );
  }

  /// 唱过的字使用的主题亮色（介于白与主题色之间，folia wordColor 的移植）
  Color get _sungColor =>
      Color.lerp(_brightColor, _glowAccent, 0.5) ?? _brightColor;

  /// 加权逐字时间起点（长度 = 字数+1，末位 = 行结束）：
  /// 标点前的字符分配更长时长（朗读停顿），其余字符均分。
  /// 计算一次按行缓存，避免每帧重复。
  List<double> _weightedStarts(LyricLine line) {
    final text = line.text;
    final n = text.length;
    final key = '${line.start}|$text';
    return _charStartCache.putIfAbsent(key, () {
      const pausePunct = '，。！？；：、,.!?;:…—～';
      final weights = List<double>.filled(n, 1.0);
      for (var i = 0; i < n; i++) {
        if (i > 0 && pausePunct.contains(text[i])) {
          weights[i - 1] = 1.6; // 标点前停顿
        }
      }
      final total = weights.fold<double>(0, (a, b) => a + b);
      final dur = line.duration;
      final out = <double>[];
      var acc = 0.0;
      for (var i = 0; i < n; i++) {
        out.add(line.start + acc);
        acc += dur * weights[i] / total;
      }
      out.add(line.start + dur);
      return out;
    });
  }

  /// 逐字辉光强度：Smoothstep 起峰 + 驻留 + 衰减（folia resolveMonetGlow 移植，
  /// tail 用行渲染结束时间，保证整行唱完前辉光不提前熄灭）
  double _charGlow(double time, double start, double end, double lineEnd) {
    if (time <= start) return 0;
    final rise = math.max(0.001, end - start) * 1.18;
    final peak = start + rise;
    final tail = math.max(lineEnd, end + 1.05);
    if (time <= peak) {
      final p = ((time - start) / rise).clamp(0.0, 1.0).toDouble();
      return p * p * (3 - 2 * p);
    }
    final remaining = 1 -
        ((time - peak) / math.max(0.18, tail - peak)).clamp(0.0, 1.0).toDouble();
    return remaining * remaining * (3 - 2 * remaining);
  }

  Widget _statusBox(String text, {bool loading = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleCover,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: AppTheme.accent,
                  ),
                ),
              ),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSub,
                height: 1.6,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重试'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

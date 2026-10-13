import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

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
/// - 当前行逐字扫字点亮 + 柔化前缘 + 辉光（resolveMonetFillWidth / resolveMonetGlow / mask 的移植）；
/// - 上下渐隐遮罩；整轨用 SpringSimulation 弹簧滚动（folia MONET_SCROLL_SPRING）；
/// - 支持手动上下拖动浏览歌词，1.8s 无操作自动回到跟随（folia idle reset）；
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
  static const double _fontSize = 17;
  static const double _lineHeight = 1.4;
  // 行距统一用 inactiveGap（folia 的 active/inactive 双间距在默认字号下相差仅 4px，
  // 统一间距让轨道坐标与 active 无关，换行时不跳变）
  static const double _inactiveGap = 14;
  static const int _visibleBefore = 4;
  static const int _visibleAfter = 4;
  static const double _glowPad = 8;
  static const double _inactiveScale = 0.85; // ≈ inactiveFontPx / lyricFontPx
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

  String? _loadedKey;
  List<LyricLine>? _lines;
  bool _loading = false;
  String? _error;

  /// 本地章节未配文稿（区别于在线书「本集确实没有文稿」）
  bool _noLyrics = false;

  /// 文本行高测量缓存（文本 + 宽度 -> 高度）
  final Map<String, double> _heightCache = {};

  /// 逐字 x 位置缓存（当前行扫字用）
  final Map<String, List<double>> _offsetCache = {};

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
    if (mounted) setState(() {});
  }

  /// 高频时钟：在两次位置流之间插值，保证扫字/辉光平滑
  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (!_playing) return;
    if (dt <= 0 || dt > 0.1) return;
    _timeSec += dt * _rate;
    if (mounted) setState(() {});
  }

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
        final active = _activeIndexFor(lines, _timeSec);
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

    // 逐字扫字（folia MonetRailTokens 方案）：
    // 底层整行暗字；上层整行亮字用横向渐变 mask 裁剪——
    // 扫过的字全亮、正在扫的字渐变柔化、未扫的保持暗色。
    final glow = _lineGlow(line);
    final glowColor =
        Color.lerp(_baseColor, _glowAccent, glow)!.withValues(alpha: 0.88 * glow);
    final offsets = _charOffsets(line.text, maxTextW);
    final sweepX = _sweepX(line, offsets);
    final w = maxTextW;
    final soft = _fontSize * 0.35; // 前缘柔化宽度（folia sweep edge softness）
    final solidEnd = (sweepX - soft * 0.55).clamp(0.0, w);
    final featherStart = (sweepX - soft * 0.2).clamp(0.0, w);
    final featherEnd = (sweepX + soft).clamp(0.0, w);

    final brightStyle = _textStyle(active: true).copyWith(
      color: _brightColor,
      shadows: glow > 0.02
          ? [
              Shadow(
                color: glowColor,
                blurRadius: _fontSize * 0.28,
              ),
              Shadow(
                color: glowColor,
                blurRadius: _fontSize * 0.65,
              ),
            ]
          : null,
    );

    return SizedBox(
      width: maxTextW,
      height: h,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _glowPad),
        child: Stack(
          children: [
            Text(line.text, style: _textStyle(active: true).copyWith(color: _baseColor)),
            if (sweepX > 0.004)
              ShaderMask(
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    _brightColor,
                    _brightColor,
                    _brightColor.withValues(alpha: 0.92),
                    Colors.transparent,
                    Colors.transparent,
                  ],
                  stops: [
                    0,
                    w <= 0 ? 0 : solidEnd / w,
                    w <= 0 ? 0 : featherStart / w,
                    w <= 0 ? 0 : featherEnd / w,
                    1,
                  ],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: Text(line.text, style: brightStyle),
              ),
          ],
        ),
      ),
    );
  }

  /// 测量每个字符的 x 起点（0..text.length，末位即总宽）
  List<double> _charOffsets(String text, double maxWidth) {
    final key = '$text|w${maxWidth.toStringAsFixed(1)}';
    return _offsetCache.putIfAbsent(key, () {
      final tp = TextPainter(
        text: TextSpan(text: text, style: _textStyle(active: true)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      final out = <double>[];
      for (var i = 0; i <= text.length; i++) {
        final pos = tp.getOffsetForCaret(TextPosition(offset: i), Rect.zero);
        out.add(pos.dx);
      }
      return out;
    });
  }

  /// 当前扫到的像素 x：句内时间按字均匀分配
  /// （folia 对无逐字 timing 的 token 采用同款比例兜底）
  double _sweepX(LyricLine line, List<double> offsets) {
    final t = _timeSec;
    final n = offsets.length - 1;
    if (t <= line.start || n <= 0) return 0;
    if (t >= line.end) return offsets[n];
    final charDur = line.duration / n;
    final idx = ((t - line.start) / charDur).clamp(0.0, n.toDouble());
    final whole = idx.floor();
    final frac = idx - whole;
    if (whole >= n) return offsets[n];
    return offsets[whole] + (offsets[whole + 1] - offsets[whole]) * frac;
  }

  /// 辉光强度：Smoothstep 起峰 + 平滑衰减（folia resolveMonetGlow）
  double _lineGlow(LyricLine line) {
    final t = _timeSec;
    if (t <= line.start) return 0;
    final rise = math.max(0.001, line.duration) * 1.18;
    final peak = line.start + rise;
    final tail = line.end + 1.05;
    if (t <= peak) {
      final p = ((t - line.start) / rise).clamp(0.0, 1.0).toDouble();
      return p * p * (3 - 2 * p);
    }
    final remaining =
        1 - ((t - peak) / math.max(0.18, tail - peak)).clamp(0.0, 1.0).toDouble();
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

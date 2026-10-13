import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_theme.dart';
import '../models/lyric_line.dart';
import '../player/book_player.dart';
import '../services/bili_api.dart';
import '../services/download_store.dart';
import '../services/lyrics_parser.dart';

/// folia-major「Cadenza 华彩」散落式歌词视图的 Flutter 移植。
///
/// 核心视觉（对应 folia cadenzaPlacements / cadenzaEnvelopes）：
/// - 同时显示前 1 句 + 当前句 + 后 1 句，每句按标点/空格切意群（chunk）；
/// - 每个意群按「行带 + 种子随机」散布到整屏（不同位置、大小、旋转），
///   当前句的「强调意群」（hero）放大居中，其余围绕避让；
/// - 当前句逐字点亮 + 辉光（getClassicCharGlow）；唱过意群 5s 缓动外漂旋转淡出；
/// - 点击任意意群跳转该句，点空白切回封面，长按调全局偏移。
class LyricsCadenzaView extends StatefulWidget {
  const LyricsCadenzaView({
    super.key,
    required this.player,
    this.onToggleCover,
    this.coverUrl,
  });

  final BookPlayer player;
  final VoidCallback? onToggleCover;
  final String? coverUrl;

  @override
  State<LyricsCadenzaView> createState() => _LyricsCadenzaViewState();
}

/// 一个意群（chunk）的落点
class _Placement {
  final String text;
  final int lineIndex; // 在 lines 中的下标
  final double start;
  final double end;
  final double width;
  final double height;
  final double x; // 相对屏幕中心
  final double y;
  final double scale;
  final double rotate; // 基础旋转
  final double passedRotate; // 唱过后额外旋转
  final double driftX; // 唱过漂移方向（单位向量）
  final double driftY;
  final bool hero;

  const _Placement({
    required this.text,
    required this.lineIndex,
    required this.start,
    required this.end,
    required this.width,
    required this.height,
    required this.x,
    required this.y,
    required this.scale,
    required this.rotate,
    required this.passedRotate,
    required this.driftX,
    required this.driftY,
    required this.hero,
  });
}

class _LyricsCadenzaViewState extends State<LyricsCadenzaView>
    with SingleTickerProviderStateMixin {
  static const double _fontSize = 21;
  static const double _heroScale = 1.32;
  static const double _lineHeight = 1.3;

  // ---------- 时间驱动 ----------
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _timeSec = 0;
  bool _playing = false;
  double _rate = 1;
  double _offsetMs = 0;

  // ---------- 数据 ----------
  String? _loadedKey;
  List<LyricLine>? _lines;
  bool _loading = false;
  String? _error;
  bool _noLyrics = false;

  // 布局缓存（窗口行变化时重算）
  int _layoutLineIndex = -1;
  double _layoutW = 0;
  double _layoutH = 0;
  List<_Placement> _placements = const [];

  // 文本测量缓存
  final Map<String, double> _widthCache = {};

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
    SharedPreferences.getInstance().then((p) {
      final v = p.getInt('lyrics_offset_ms');
      if (!mounted) return;
      setState(() => _offsetMs = (v ?? 0).toDouble());
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    widget.player.positionTick.removeListener(_onPosition);
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPosition() {
    _timeSec = widget.player.currentPosition.inMilliseconds / 1000.0;
    _lastTick = Duration.zero;
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    if (_lastTick == Duration.zero) {
      _lastTick = elapsed;
      return;
    }
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (!_playing || dt <= 0) return;
    _timeSec += math.min(dt, 0.25) * _rate;
    if (mounted) setState(() {});
  }

  double get _t => _timeSec + _offsetMs / 1000.0;

  void _onPlayerChanged() {
    final playing = widget.player.isPlaying;
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
    _rate = widget.player.rate;
    _maybeLoad();
    if (mounted) setState(() {});
  }

  // ---------- 数据加载 ----------
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
      List<LyricLine>? lines;
      if (bvid.startsWith('local_')) {
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
          _noLyrics = lines == null || lines.isEmpty;
        });
        return;
      }
      try {
        lines = await DownloadStore.instance.localLyricsFor(bvid, cid);
      } catch (_) {}
      lines ??= await BiliApi.instance.fetchLyrics(bvid, cid);
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _lines = lines;
        _loading = false;
        _noLyrics = false;
      });
    } catch (e) {
      debugPrint('[Cadenza] 文稿获取失败: $e');
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

  // ---------- 工具 ----------
  int _activeIndexFor(List<LyricLine> lines, double t) {
    var lo = 0, hi = lines.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].start <= t) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 按标点/空格切意群；长意群从中部均衡切开（避免 12+1 的怪切法）
  List<String> _splitChunks(String text) {
    final parts = text
        .split(RegExp(r'[，。！？；：、,.!?;:…—～\s]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return [text];
    final chunks = <String>[];
    for (var p in parts) {
      while (p.length > 11) {
        final cut = p.length > 15 ? 8 : p.length ~/ 2;
        chunks.add(p.substring(0, cut));
        p = p.substring(cut);
      }
      if (p.isNotEmpty) chunks.add(p);
    }
    return chunks;
  }

  TextStyle _textStyle({bool bold = false}) => TextStyle(
        fontSize: _fontSize,
        height: _lineHeight,
        fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
        color: AppTheme.textMain,
      );

  double _measureWidth(String text) {
    return _widthCache.putIfAbsent(text, () {
      final tp = TextPainter(
        // 统一按粗体测量，保证渲染不会超出容器
        text: TextSpan(text: text, style: _textStyle(bold: true)),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width;
    });
  }

  Color get _baseColor => AppTheme.textMain.withValues(alpha: 0.4);
  Color get _brightColor => AppTheme.textMain;
  Color get _glowAccent =>
      AppTheme.isDark ? AppTheme.accentSoft : AppTheme.accentDeep;
  Color get _sungColor =>
      Color.lerp(_brightColor, _glowAccent, 0.5) ?? _brightColor;

  double _easeInOutQuad(double x) =>
      x < 0.5 ? 2 * x * x : 1 - math.pow(-2 * x + 2, 2).toDouble() / 2;

  double _smoothstep(double x) => x * x * (3 - 2 * x);

  // ---------- 布局（folia cadenzaPlacements 移植 + 全屏散布） ----------
  List<_Placement> _buildPlacements(
      List<LyricLine> lines, int active, double w, double h) {
    final placements = <_Placement>[];
    final occupied = <({double l, double t, double r, double b})>[];

    bool collides(double l, double t, double r, double b) {
      for (final o in occupied) {
        if (r > o.l && l < o.r && b > o.t && t < o.b) return true;
      }
      return false;
    }

    void occupy(double cx, double cy, double cw, double ch, double pad) {
      occupied.add((
        l: cx - cw / 2 - pad,
        t: cy - ch / 2 - pad,
        r: cx + cw / 2 + pad,
        b: cy + ch / 2 + pad
      ));
    }

    // 每句切意群
    final lineChunks = <List<String>>[];
    for (var i = math.max(0, active - 1);
        i <= math.min(lines.length - 1, active + 1);
        i++) {
      lineChunks.add(_splitChunks(lines[i].text));
    }

    // hero = 当前句的中间意群（放大突出）
    final heroText = lineChunks.length > 1 && lineChunks[1].isNotEmpty
        ? lineChunks[1][lineChunks[1].length ~/ 2]
        : null;
    var heroStart = 0.0, heroEnd = 0.0;

    final centerX = w / 2, centerY = h / 2;
    final maxR = math.max(h * 0.55, 130).toDouble();
    final step = math.max(10, _fontSize * 0.14).round();

    // 第一遍：hero 居中占位
    for (var wi = 0; wi < lineChunks.length; wi++) {
      final li = math.max(0, active - 1) + wi;
      final status = li < active ? -1 : (li > active ? 1 : 0);
      final chunks = lineChunks[wi];
      if (chunks.isEmpty) continue;
      final line = lines[li];
      final totalChars = chunks.fold<int>(0, (a, c) => a + c.length);
      for (var ci = 0; ci < chunks.length; ci++) {
        if (status != 0 || chunks[ci] != heroText) continue;
        final cw = _measureWidth(chunks[ci]);
        final chH = _fontSize * _lineHeight;
        final chunkStart = line.start +
            line.duration *
                (ci == 0
                    ? 0
                    : chunks.take(ci).fold<int>(0, (a, c) => a + c.length)) /
                totalChars;
        heroStart = chunkStart;
        heroEnd = chunkStart + line.duration * chunks[ci].length / totalChars;
        occupy(centerX, centerY, cw * _heroScale, chH * _heroScale, 14);
        break;
      }
    }

    // 第二遍：其余意群按「行带 + 种子」散布，围绕 hero 螺旋避让
    for (var wi = 0; wi < lineChunks.length; wi++) {
      final li = math.max(0, active - 1) + wi;
      final line = lines[li];
      final status = li < active ? -1 : (li > active ? 1 : 0);
      final chunks = lineChunks[wi];
      if (chunks.isEmpty) continue;
      final totalChars = chunks.fold<int>(0, (a, c) => a + c.length);

      // 行带：前句上带、当前句中央带、后句下带
      final band = status < 0
          ? (-0.52 * h, -0.17 * h)
          : status > 0
              ? (0.17 * h, 0.52 * h)
              : (-0.15 * h, 0.15 * h);

      for (var ci = 0; ci < chunks.length; ci++) {
        final text = chunks[ci];
        final cw = _measureWidth(text);
        final chH = _fontSize * _lineHeight;
        final isHero = status == 0 && text == heroText;
        final seed = li * 31 + ci * 13 + 7;
        double rand(double o) {
          final x = math.sin(seed + o) * 10000;
          return x - x.floorToDouble();
        }

        final scale = isHero
            ? _heroScale
            : status == 0
                ? 0.95 + rand(7) * 0.18
                : 0.8 + rand(8) * 0.12;
        final cwScaled = cw * scale, chScaled = chH * scale;
        final chunkStart = line.start +
            line.duration *
                (ci == 0
                    ? 0
                    : chunks.take(ci).fold<int>(0, (a, c) => a + c.length)) /
                totalChars;
        final chunkEnd = chunkStart + line.duration * text.length / totalChars;

        if (isHero) {
          placements.add(_Placement(
            text: text,
            lineIndex: li,
            start: heroStart,
            end: heroEnd,
            width: cwScaled,
            height: chScaled,
            x: 0,
            y: 0,
            scale: scale,
            rotate: 0,
            passedRotate: 0,
            driftX: 0.6,
            driftY: -0.4,
            hero: true,
          ));
          continue;
        }

        // 目标点：行带内全宽散布 + 种子扰动
        final tx = (rand(5) - 0.5) * w * 0.74;
        final ty = band.$1 + rand(6) * (band.$2 - band.$1);
        var px = tx, py = ty;

        // 与 hero 的避让推挤（围绕感）
        final hd = math.sqrt(px * px + py * py);
        final minSep = _fontSize * _heroScale * 2.2 + cwScaled * 0.5;
        if (heroText != null && hd < minSep && hd > 0.01) {
          px += px / hd * (minSep - hd);
          py += py / hd * (minSep - hd) * 0.9;
        }

        // 螺旋搜索避让碰撞；兜底 = 边界内位移最小
        final baseAngle = math.atan2(py, px + cwScaled / 2);
        var chosenX = px, chosenY = py, found = false;
        var fallbackX = px
            .clamp(-w / 2 + cwScaled / 2 + w * 0.06, w / 2 - cwScaled / 2 - w * 0.06)
            .toDouble();
        var fallbackY = py
            .clamp(-h / 2 + chScaled / 2 + h * 0.04, h / 2 - chScaled / 2 - h * 0.04)
            .toDouble();
        var fallbackScore = double.infinity;
        for (var radius = 0; radius <= maxR && !found; radius += step) {
          final samples = radius == 0
              ? 1
              : math.max(12, ((math.pi * 2 * radius) / math.max(step * 1.1, 10)).round());
          for (var si = 0; si < samples; si++) {
            final angle = baseAngle + (si / samples) * math.pi * 2;
            final rx = math.cos(angle) * radius;
            final ry = math.sin(angle) * radius * 0.92;
            final l = centerX + px + rx - cwScaled / 2;
            final t = centerY + py + ry - chScaled / 2;
            final r = l + cwScaled, b = t + chScaled;
            if (l < w * 0.06 || r > w * 0.94 || t < h * 0.04 || b > h * 0.96) {
              continue;
            }
            final travel = math.sqrt(rx * rx + ry * ry);
            if (collides(l, t, r, b)) {
              var overlap = 0.0;
              for (final o in occupied) {
                final ow = math.max(0, math.min(r, o.r) - math.max(l, o.l));
                final oh = math.max(0, math.min(b, o.b) - math.max(t, o.t));
                overlap += ow * oh;
              }
              final score = overlap * 2.2 + travel;
              if (score < fallbackScore) {
                fallbackScore = score;
                fallbackX = px + rx;
                fallbackY = py + ry;
              }
              continue;
            }
            chosenX = px + rx;
            chosenY = py + ry;
            occupy(centerX + chosenX, centerY + chosenY, cwScaled, chScaled,
                status == 0 ? 8 : 6);
            found = true;
            break;
          }
        }
        if (!found) {
          chosenX = fallbackX;
          chosenY = fallbackY;
          occupy(centerX + chosenX, centerY + chosenY, cwScaled, chScaled, 6);
        }

        // 漂移方向：从屏幕中心向外
        final outX = chosenX + cwScaled / 2, outY = chosenY - chScaled * 0.4;
        final len = math.max(math.sqrt(outX * outX + outY * outY), 1);
        placements.add(_Placement(
          text: text,
          lineIndex: li,
          start: chunkStart,
          end: chunkEnd,
          width: cwScaled,
          height: chScaled,
          x: chosenX,
          y: chosenY,
          scale: scale,
          rotate: (rand(3) - 0.5) * 8,
          passedRotate: (rand(4) - 0.5) * 14,
          driftX: outX / len,
          driftY: outY / len * 0.72,
          hero: false,
        ));
      }
    }
    return placements;
  }

  // ---------- 构建 ----------
  @override
  Widget build(BuildContext context) {
    _maybeLoad();
    final lines = _lines;
    if (lines == null) {
      return _statusBox(_error != null ? _error! : '正在获取文稿…',
          loading: _loading);
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
        final w = constraints.maxWidth, h = constraints.maxHeight;
        final active = _activeIndexFor(lines, _t);
        if (_layoutLineIndex != active || _layoutW != w || _layoutH != h) {
          _layoutLineIndex = active;
          _layoutW = w;
          _layoutH = h;
          _placements = _buildPlacements(lines, active, w, h);
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onToggleCover,
          onLongPress: _showOffsetAdjuster,
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              _backdrop(w, h),
              for (final p in _placements) _buildChunk(p, lines, active, w, h),
            ],
          ),
        );
      },
    );
  }

  /// 背景：封面模糊底 + 氛围光晕
  Widget _backdrop(double w, double h) {
    final url = widget.coverUrl;
    return IgnorePointer(
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, 0),
            radius: 0.95,
            colors: [
              _glowAccent.withValues(alpha: 0.09),
              _glowAccent.withValues(alpha: 0.03),
              Colors.transparent,
            ],
          ),
        ),
        child: url == null || url.isEmpty
            ? null
            : ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      cacheWidth: 480,
                    ),
                    Container(color: Colors.black.withValues(alpha: 0.62)),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildChunk(
      _Placement p, List<LyricLine> lines, int active, double w, double h) {
    final line = lines[p.lineIndex];
    final t = _t;
    final drift = p.lineIndex < active
        ? _easeInOutQuad(((t - line.end) / 5).clamp(0.0, 1.0).toDouble())
        : 0.0;
    final dx = p.x + p.driftX * 46 * drift;
    final dy = p.y + p.driftY * 46 * drift;
    final rotate = p.rotate + p.passedRotate * drift;
    final isActiveLine = p.lineIndex == active;

    Widget child;
    if (isActiveLine) {
      child = _activeChunk(p, t);
    } else {
      final baseAlpha = p.lineIndex < active
          ? (0.5 * (1 - drift * 0.55)).clamp(0.18, 0.5).toDouble()
          : 0.55;
      child = Text(
        p.text,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: _textStyle().copyWith(
          color: _baseColor.withValues(alpha: baseAlpha),
          fontSize: _fontSize * p.scale,
          fontWeight: p.hero ? FontWeight.w700 : FontWeight.w500,
        ),
      );
    }

    // 不定宽高（不裁剪），left/top 定位
    return Positioned(
      left: w / 2 + dx - p.width / 2,
      top: h / 2 + dy - p.height / 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _seekToLine(p.lineIndex, lines),
        child: Transform.rotate(
          angle: rotate * math.pi / 180,
          child: child,
        ),
      ),
    );
  }

  /// 当前句意群：逐字点亮 + 辉光（folia getClassicCharGlow 移植）
  Widget _activeChunk(_Placement p, double t) {
    final text = p.text;
    final n = text.length;
    if (n == 0) return const SizedBox.shrink();
    final charDur = math.max((p.end - p.start), 0.05) / n;
    final spans = <TextSpan>[];
    final fs = _fontSize * p.scale;
    for (var i = 0; i < n; i++) {
      final s = p.start + charDur * i;
      final e = i == n - 1 ? p.end : p.start + charDur * (i + 1);
      final glow = _charGlow(t, s, e);
      final status = (t < s
              ? 0.0
              : t < e
                  ? (t - s) / math.max(0.001, e - s)
                  : 1.0)
          .toDouble();
      final color = status >= 1
          ? _sungColor
          : status > 0
              ? Color.lerp(_baseColor, _sungColor, status)!
              : _baseColor;
      spans.add(TextSpan(
        text: text[i],
        style: TextStyle(
          fontSize: fs,
          height: _lineHeight,
          fontWeight: p.hero ? FontWeight.w700 : FontWeight.w600,
          color: color,
          shadows: glow > 0.02
              ? [
                  Shadow(
                    color: Color.lerp(_baseColor, _glowAccent, glow)!
                        .withValues(alpha: 0.9 * glow),
                    blurRadius: fs * 0.22,
                  ),
                  Shadow(
                    color: Color.lerp(_baseColor, _glowAccent, glow)!
                        .withValues(alpha: 0.65 * glow),
                    blurRadius: fs * 0.5,
                  ),
                ]
              : null,
        ),
      ));
    }
    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.center,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: TextStyle(fontSize: fs, height: _lineHeight),
    );
  }

  double _charGlow(double time, double start, double end) {
    if (time <= start) return 0;
    final anim = 6 * math.max(end - start, 0.001);
    final elapsed = time - start;
    if (elapsed < anim) {
      final x = (elapsed / anim).clamp(0.0, 1.0).toDouble();
      return _smoothstep(x);
    }
    if (time <= end) return 1;
    final fade = math.pow(1 - ((time - end) / 0.9).clamp(0.0, 1.0).toDouble(), 2)
        .toDouble();
    return fade;
  }

  void _seekToLine(int lineIndex, List<LyricLine> lines) {
    _timeSec = lines[lineIndex].start;
    setState(() {});
    widget.player.seek(lines[lineIndex].startDuration);
  }

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

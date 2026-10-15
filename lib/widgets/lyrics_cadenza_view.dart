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
import '../services/baidu_asr.dart';
import '../services/download_store.dart';
import '../services/local_library.dart';
import '../services/lyrics_parser.dart';

/// folia-major「Cadenza 华彩」散落式歌词视图的 Flutter 移植。
///
/// 核心视觉（对应 folia cadenzaPlacements / cadenzaEnvelopes）：
/// - 同时显示前 1 句 + 当前句 + 后 1 句，每句拆成词/字碎片（folia
///   cadenzaFragments：CJK 逐字、英文整词）；
/// - 碎片保持句序在行内铺开 + 种子微扰 + 碰撞避让（folia
///   cadenzaPlacements），当前句时间居中的碎片为 hero，放大居中；
/// - 渲染按 folia cadenzaEnvelopes 状态机：waiting 暗色 → active 混色渐入 +
///   辉光（getClassicKeyframedGlow）→ passed 沿屏幕中心外漂 + 旋转 + 行级淡出；
/// - 词级时间戳存在时逐字跟读，无词级数据回退句内均分；
/// - 点击任意碎片跳转该句，点空白切回封面，长按调全局偏移。
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
  bool _upgrading = false; // 正在后台生成词级文稿（行级 LRC → 词级转写）
  String? _upgradeError; // 词级文稿生成失败原因（百度返回）

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
    _upgrading = false;
    _upgradeError = null;
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
        // 下载的 LRC 只有行级时间戳，字级跟声需要词级转写：
        // 文稿存在但无词级时间戳 → 后台百度转写升级，完成后刷新
        final hasWord = (lines ?? const <LyricLine>[])
            .any((l) => l.words != null && l.words!.isNotEmpty);
        if (lines != null && lines.isNotEmpty && !hasWord) {
          if (localPath != null && localPath.isNotEmpty) {
            _upgradeLyrics(key, localPath);
          }
        }
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

  /// 行级 LRC → 后台百度转写升级为词级文稿，完成后刷新视图（逐字跟声）。
  /// 未配置转写 / 失败静默：保持现有行级文稿不打扰播放。
  Future<void> _upgradeLyrics(String key, String localPath) async {
    if (!mounted || _loadedKey != key) return;
    setState(() => _upgrading = true);
    try {
      final upgraded = await LocalLibrary.instance
          .upgradeLyricsToWordLevel(File(localPath));
      if (!mounted || _loadedKey != key) return;
      if (!upgraded) {
        setState(() {
          _upgrading = false;
          _upgradeError = BaiduAsr.lastError ?? '未配置语音转写（设置页）';
        });
        return;
      }
      final lines = LyricsParser.readLyricsFile(File(localPath));
      setState(() {
        _upgrading = false;
        _lines = lines ?? const <LyricLine>[];
        _noLyrics = false;
      });
    } catch (e) {
      debugPrint('[Cadenza] 词级文稿升级失败（忽略）: $e');
      if (!mounted || _loadedKey != key) return;
      setState(() {
        _upgrading = false;
        _upgradeError = BaiduAsr.lastError ?? '转写异常：$e';
      });
    }
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

  /// 歌词碎片（folia cadenzaFragments 的中文适配）：
  /// CJK 字符逐字散落，英文/数字整词保留，标点独立成片。
  List<String> _fragmentsOf(String text) {
    final frags = <String>[];
    final cjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]');
    final alnum = RegExp(r'[a-zA-Z0-9]');
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (cjk.hasMatch(ch)) {
        frags.add(ch);
        i++;
      } else if (alnum.hasMatch(ch)) {
        var j = i + 1;
        while (j < text.length && alnum.hasMatch(text[j])) {
          j++;
        }
        frags.add(text.substring(i, j));
        i = j;
      } else {
        if (ch.trim().isNotEmpty) frags.add(ch);
        i++;
      }
    }
    return frags;
  }

  /// 每个碎片的 (start, end) 时间：
  /// 词级时间戳与碎片 1:1（逐字识别）时用真实字时间；否则句内按字数均分。
  List<({double s, double e})> _fragTimes(
      LyricLine line, List<String> frags) {
    final words = line.words;
    if (words != null && words.length == frags.length) {
      final out = <({double s, double e})>[];
      for (var i = 0; i < frags.length; i++) {
        out.add((s: words[i].start, e: words[i].end));
      }
      return out;
    }
    final totalChars = frags.fold<int>(0, (a, f) => a + f.length);
    final per = line.duration / math.max(totalChars, 1);
    final out = <({double s, double e})>[];
    var acc = line.start;
    for (final f in frags) {
      final fs = acc;
      final fe = fs + per * f.length;
      out.add((s: fs, e: fe));
      acc = fe;
    }
    return out;
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

  // ---------- 布局（folia cadenzaPlacements 移植：词/字碎片 + hero 居中） ----------
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

    // 三行碎片：前 1 句 / 当前句 / 后 1 句（folia 同屏展示三行）
    final rows =
        <({int li, List<String> frags, List<({double s, double e})> times})>[];
    for (var wi = 0; wi < 3; wi++) {
      final li = math.max(0, active - 1) + wi;
      if (li < 0 || li >= lines.length) continue;
      final line = lines[li];
      final frags = _fragmentsOf(line.text);
      if (frags.isEmpty) continue;
      rows.add((li: li, frags: frags, times: _fragTimes(line, frags)));
    }
    if (rows.isEmpty) return placements;

    // 当前行（folia 主行）
    var curRowIdx = -1;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].li == active) {
        curRowIdx = i;
        break;
      }
    }
    if (curRowIdx < 0) curRowIdx = rows.length - 1;
    final curRow = rows[curRowIdx];

    // hero = 当前行时间居中的碎片（folia 中心偏置强调 → 放大居中，手机端适度 1.28）
    final heroIdx = curRow.frags.length ~/ 2;
    final heroText = curRow.frags[heroIdx];
    const heroScale = 1.28;
    final heroW = _measureWidth(heroText) * heroScale;
    final heroH = _fontSize * _lineHeight * heroScale;
    final heroY = -_fontSize * 0.4;

    // 1) hero 先占位（居中偏上，避开底部控件区）
    occupy(0, heroY, heroW, heroH, 12);
    placements.add(_Placement(
      text: heroText,
      lineIndex: curRow.li,
      start: curRow.times[heroIdx].s,
      end: curRow.times[heroIdx].e,
      width: heroW,
      height: heroH,
      x: 0,
      y: heroY,
      scale: heroScale,
      rotate: 0,
      passedRotate: -8,
      driftX: 0.6,
      driftY: -0.4,
      hero: true,
    ));

    // 2) 其余碎片：按句序在行内铺开（保持原句读顺序），种子微扰 + hero 推挤 +
    //    螺旋搜索避让碰撞；passed 漂移方向 = 从屏幕中心向外。
    //    手机端适配：前/后句弱化缩小（氛围感），当前句为主、行宽不顶边。
    final rowGap = _fontSize * _lineHeight * 2.5;
    final spacing = _fontSize * 0.34;
    final maxR = math.max(h * 0.5, 120).toDouble();
    final step = math.max(10, _fontSize * 0.14).round();

    for (var ri = 0; ri < rows.length; ri++) {
      final row = rows[ri];
      final rowOffsetY = row.li < active
          ? -rowGap
          : (row.li > active ? rowGap : 0.0);
      final isCur = ri == curRowIdx;

      // 行内宽度与每片缩放：当前句大小相近（0.96~1.06），前后句整体缩小弱化
      final scales = <double>[];
      var totalW = 0.0;
      for (var i = 0; i < row.frags.length; i++) {
        final isHero = isCur && i == heroIdx;
        final sc = isHero
            ? heroScale
            : isCur
                ? 0.96 + _randOf(row.li * 31 + i * 13 + 7, 8) * 0.1
                : 0.66 + _randOf(row.li * 31 + i * 13 + 7, 9) * 0.12;
        scales.add(sc);
        totalW +=
            _measureWidth(row.frags[i]) * sc + (i == 0 ? 0 : spacing);
      }
      // 行宽超屏自适应：只缩非 hero 碎片宽度（hero 渲染恒定 1.28，
      // 字间距不缩放），保证排布总宽 = maxRowW、行不顶边
      final maxRowW = isCur ? w * 0.82 : w * 0.86;
      final heroCw = _measureWidth(heroText) * heroScale;
      final allSpacing = math.max(row.frags.length - 1, 0) * spacing;
      if (totalW > maxRowW) {
        final nonHeroCwTotal = totalW - heroCw - allSpacing;
        final targetNonHeroCw = maxRowW - heroCw - allSpacing;
        if (nonHeroCwTotal > 1 && targetNonHeroCw > 1) {
          final ratio = targetNonHeroCw / nonHeroCwTotal;
          for (var i = 0; i < scales.length; i++) {
            if (!(isCur && i == heroIdx)) {
              scales[i] = scales[i] * ratio;
            }
          }
        }
        totalW = maxRowW;
      }
      var xPos = -totalW / 2;

      for (var i = 0; i < row.frags.length; i++) {
        if (ri == curRowIdx && i == heroIdx) {
          // hero 已单独居中放置：行内保留其槽位宽度，避免右侧碎片与 hero
          // 初始重叠而触发螺旋避让整排外推（行边界被打破）
          xPos += heroW + spacing;
          continue;
        }
        final text = row.frags[i];
        final sc = scales[i];
        final cw = _measureWidth(text) * sc;
        final chH = _fontSize * _lineHeight * sc;
        final seed = row.li * 31 + i * 13 + 7;
        double rand(double o) {
          final x = math.sin(seed + o) * 10000;
          return x - x.floorToDouble();
        }

        // 目标点：行序 x + 种子微扰（folia 保持句序，碰撞推挤制造错落）。
        // 首尾碎片不横向扰动，保持行边界整齐不顶边
        final isEdge = i == 0 || i == row.frags.length - 1;
        final jitterX = isEdge ? 0.0 : (isCur ? _fontSize * 0.32 : _fontSize * 0.45);
        final jitterY = isCur ? _fontSize * 0.26 : _fontSize * 0.34;
        var px = xPos + cw / 2 + (rand(5) - 0.5) * jitterX;
        var py = rowOffsetY + (rand(6) - 0.5) * jitterY;

        // 与 hero 的推挤分离（folia minHeroSeparation）
        final hd = math.sqrt(px * px + py * py);
        final minSep = heroW * 0.34 + cw * 0.52 + 12;
        if (hd < minSep && hd > 0.01) {
          px += px / hd * (minSep - hd);
          py += py / hd * (minSep - hd) * 0.92;
        }

        // 螺旋搜索避让碰撞；兜底 = 行内/屏内重叠最小。
        // 横向边界用「行宽一半」而非屏宽，避让不会把碎片推出本行（手机端不顶边）
        final rowHalf = isCur ? w * 0.41 : w * 0.43;
        final baseAngle = math.atan2(py, px + cw / 2);
        var chosenX = px, chosenY = py, found = false;
        var fallbackX = px
            .clamp(-rowHalf + cw / 2 + w * 0.02, rowHalf - cw / 2 - w * 0.02)
            .toDouble();
        var fallbackY = py
            .clamp(-h / 2 + chH / 2 + h * 0.04, h / 2 - chH / 2 - h * 0.04)
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
            final l = px + rx - cw / 2;
            final t = py + ry - chH / 2;
            final r = l + cw, b = t + chH;
            if (l < -rowHalf + cw * 0.3 || r > rowHalf - cw * 0.3 ||
                t < -h / 2 + chH * 0.3 || b > h / 2 - chH * 0.3) {
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
            occupy(chosenX, chosenY, cw, chH, 5);
            found = true;
            break;
          }
        }
        if (!found) {
          chosenX = fallbackX;
          chosenY = fallbackY;
          occupy(chosenX, chosenY, cw, chH, 5);
        }

        // 漂移方向：从屏幕中心向外（folia outwardUnit）
        final outX = chosenX + cw / 2, outY = chosenY - chH * 0.46;
        final len = math.max(math.sqrt(outX * outX + outY * outY), 1);
        placements.add(_Placement(
          text: text,
          lineIndex: row.li,
          start: row.times[i].s,
          end: row.times[i].e,
          width: cw,
          height: chH,
          x: chosenX,
          y: chosenY,
          scale: sc,
          rotate: 0,
          passedRotate: (rand(3) - 0.5) * 16,
          driftX: outX / len,
          driftY: outY / len * 0.72,
          hero: false,
        ));
        xPos += cw + spacing;
      }
    }
    return placements;
  }

  double _randOf(int seed, double o) {
    final x = math.sin(seed + o) * 10000;
    return x - x.floorToDouble();
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
    if (_upgradeError != null) {
      return _statusBox('词级文稿生成失败：\n$_upgradeError\n（已保留行级歌词，重新播放本集可重试）');
    }
    if (_upgrading) {
      return _statusBox('正在生成词级文稿…\n（转写完成后歌词将逐字跟声）', loading: true);
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
  ///
  /// 封面只在「成功加载」后才叠加暗化遮罩：本地文件封面用 Image.file，
  /// 在线封面用 Image.network；无封面 / 加载失败 / 加载中都不绘制遮罩，
  /// 只保留淡淡的氛围光晕（透明），避免出现整块黑屏。
  Widget _backdrop(double w, double h) {
    final url = widget.coverUrl;
    ImageProvider? provider;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('http://') || url.startsWith('https://')) {
        provider = NetworkImage(url);
      } else {
        final f = File(url);
        if (f.existsSync()) provider = FileImage(f);
      }
    }
    final Widget? coverLayer = provider == null
        ? null
        : Image(
            image: provider,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
            frameBuilder: (_, child, frame, _) {
              if (frame == null) return child;
              // 封面真正显示出来后才叠暗化遮罩
              return Stack(fit: StackFit.expand, children: [
                child,
                Container(color: Colors.black.withValues(alpha: 0.62)),
              ]);
            },
          );
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
        child: coverLayer == null
            ? null
            : ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: coverLayer,
              ),
      ),
    );
  }

  /// 词/字碎片渲染（folia cadenzaEnvelopes 状态机）：
  /// waiting（未唱）暗色小字 → active（正在唱）混色渐入 + 辉光 → passed（唱过）
  /// 沿屏幕中心向外漂移 + 旋转 + 行级淡出；hero 词放大突出。
  Widget _buildChunk(
      _Placement p, List<LyricLine> lines, int active, double w, double h) {
    final line = lines[p.lineIndex];
    final t = _t;
    final isActiveLine = p.lineIndex == active;
    final isBefore = p.lineIndex < active;

    // passed 漂移进度（folia getClassicPassedDrift：5s easeInOutQuad）
    final drift = isBefore
        ? _easeInOutQuad(((t - line.end) / 5).clamp(0.0, 1.0).toDouble())
        : 0.0;
    final dx = p.x + p.driftX * 55 * drift;
    final dy = p.y + p.driftY * 55 * drift;
    final rotate = p.passedRotate * drift; // folia 基础不旋转，唱过才转

    // 碎片状态机（folia getWordStatus / getWordProgress / getClassicBodyMix）
    double mix; // 0 = 未唱暗色，1 = 唱完亮色
    double glow;
    if (t < p.start) {
      mix = 0;
      glow = 0;
    } else if (t <= p.end) {
      final dur = math.max(p.end - p.start, 0.045);
      final prog = ((t - p.start) / dur).clamp(0.0, 1.0).toDouble();
      mix = prog;
      glow = _keyframedGlow(prog);
    } else {
      final fadeDur = isBefore ? 0.9 : 5.0;
      final fade = math
          .pow(1 - ((t - p.end) / fadeDur).clamp(0.0, 1.0).toDouble(), 2)
          .toDouble();
      mix = 1;
      glow = 0.9 * fade;
    }

    // 行级包络（手机端）：当前行最亮；前/后句整体弱化，只作氛围；前句随漂移淡出
    final alpha = isActiveLine
        ? 1.0
        : (isBefore
            ? (0.4 * (1 - drift * 0.7)).clamp(0.06, 0.4).toDouble()
            : 0.42);

    // 颜色：未唱主题暗色 → 正在唱渐入主题亮色（folia bodyMix）
    final color = Color.lerp(_baseColor, _sungColor, mix) ?? _baseColor;
    final fs = _fontSize * p.scale;

    final child = Text(
      p.text,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: TextStyle(
        fontSize: fs,
        height: _lineHeight,
        fontWeight: p.hero ? FontWeight.w700 : FontWeight.w600,
        color: color.withValues(alpha: alpha),
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
    );

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

  /// folia getClassicKeyframedGlow：30% 冲高、70% 回落
  double _keyframedGlow(double progress) {
    if (progress <= 0 || progress >= 1) return 0;
    if (progress < 0.3) return _easeOutCubic(progress / 0.3);
    return 1 - ((progress - 0.3) / 0.7).clamp(0.0, 1.0);
  }

  double _easeOutCubic(double x) =>
      1 - math.pow(1 - x.clamp(0.0, 1.0).toDouble(), 3).toDouble();

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

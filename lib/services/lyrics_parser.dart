import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io';

import '../models/lyric_line.dart';

/// 本地文稿解析：把用户导入的 LRC / SRT / 纯文本转成带时间轴的歌词行，
/// 并写入章节同目录的 `<音频名>.lyrics.json`（与 B 站在线文稿同一格式，
/// 歌词视图离线可直接读取）。
class LyricsParser {
  LyricsParser._();

  /// 解析 LRC 歌词文本（[mm:ss.xx] 或 [mm:ss] 时间标签）。
  /// 行没有结束时间时用下一行开始时间补齐。
  static List<LyricLine> parseLrc(String content) {
    final lines = <LyricLine>[];
    final raw = <(double, String)>[]; // (startSec, text)
    final timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    for (final line in content.split('\n')) {
      final matches = timeTag.allMatches(line).toList();
      if (matches.isEmpty) continue;
      // 时间标签后的正文（去掉所有 [xx:xx] 标签）
      var text = line;
      for (final m in matches) {
        text = text.replaceFirst(m.group(0)!, '');
      }
      text = text.trim();
      if (text.isEmpty) continue;
      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        var frac = 0.0;
        if (m.group(3) != null && m.group(3)!.isNotEmpty) {
          final f = m.group(3)!;
          frac =
              int.parse(f) / (f.length == 2 ? 100 : (f.length == 1 ? 10 : 1000));
        }
        raw.add(((min * 60 + sec + frac), text));
      }
    }
    raw.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 0; i < raw.length; i++) {
      final (start, text) = raw[i];
      final end = i + 1 < raw.length ? raw[i + 1].$1 : start + 4.0;
      lines.add(LyricLine(start: start, end: end, text: text));
    }
    return lines;
  }

  /// 解析 SRT 字幕文本（序号 + 时间轴 + 多行文本块）。
  static List<LyricLine> parseSrt(String content) {
    final lines = <LyricLine>[];
    final blocks = content.split(RegExp(r'\n\s*\n'));
    final timeRe = RegExp(
        r'(\d{1,2}):(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{1,2}):(\d{1,2})[,.](\d{1,3})');
    for (final block in blocks) {
      final m = timeRe.firstMatch(block);
      if (m == null) continue;
      double toSec(String h, String mi, String s, String ms) =>
          int.parse(h) * 3600 +
              int.parse(mi) * 60 +
              int.parse(s) +
              int.parse(ms) / 1000.0;
      final start = toSec(m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!);
      final end = toSec(m.group(5)!, m.group(6)!, m.group(7)!, m.group(8)!);
      final text = block
          .replaceFirst(RegExp(r'^\d+\s*'), '')
          .replaceFirst(m.group(0)!, '')
          .trim();
      if (text.isEmpty) continue;
      lines.add(LyricLine(
        start: start,
        end: end > start ? end : start + 4.0,
        text: text,
      ));
    }
    lines.sort((a, b) => a.start.compareTo(b.start));
    return lines;
  }

  /// 纯文本 → 按行拆分；没有时间轴时按 [totalSeconds] 均分（至少 3 秒一行）。
  /// 该模式下逐字扫字效果依然生效（句内时间按字数均分）。
  static List<LyricLine> linesFromPlainText(String content,
      {double totalSeconds = 0}) {
    final textLines = content
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (textLines.isEmpty) return const [];
    final per = totalSeconds > 0 && textLines.isNotEmpty
        ? totalSeconds / textLines.length
        : 4.0;
    return List.generate(textLines.length, (i) {
      final start = i * per;
      return LyricLine(
        start: start,
        end: start + per,
        text: textLines[i],
      );
    });
  }

  /// 按扩展名自动选择解析器；返回 [] 表示无有效内容。
  static List<LyricLine> parseFile(File file, {double totalSeconds = 0}) {
    final content = file.readAsStringSync();
    final name = file.path.toLowerCase();
    if (name.endsWith('.lrc')) return parseLrc(content);
    if (name.endsWith('.srt')) return parseSrt(content);
    return linesFromPlainText(content, totalSeconds: totalSeconds);
  }

  /// 写入章节文稿文件（与音频同目录 `<basename>.lyrics.json`）。
  /// 返回写入路径；失败抛异常由调用方处理。
  static Future<String> saveLyricsFile(
      File audioFile, List<LyricLine> lines) async {
    final base = audioFile.path.replaceFirst(RegExp(r'\.\w+$'), '');
    final target = File('$base.lyrics.json');
    await target.writeAsString(
      _encode(lines),
      flush: true,
    );
    return target.path;
  }

  /// 章节是否已存在文稿（文件存在且非空）
  static bool lyricsFileExists(File audioFile) {
    final base = audioFile.path.replaceFirst(RegExp(r'\.\w+$'), '');
    final f = File('$base.lyrics.json');
    return f.existsSync() && f.lengthSync() > 0;
  }

  /// 读取章节同目录文稿；没有或损坏返回 null
  static List<LyricLine>? readLyricsFile(File audioFile) {
    final base = audioFile.path.replaceFirst(RegExp(r'\.\w+$'), '');
    final f = File('$base.lyrics.json');
    if (!f.existsSync() || f.lengthSync() == 0) return null;
    try {
      final data =
          (jsonDecode(f.readAsStringSync()) as Map?)?['lines'] as List?;
      if (data == null || data.isEmpty) return null;
      return [
        for (final e in data) LyricLine.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return null;
    }
  }

  static String _encode(List<LyricLine> lines) => jsonEncode({
        'version': 1,
        'lines': [for (final l in lines) l.toJson()],
      });
}

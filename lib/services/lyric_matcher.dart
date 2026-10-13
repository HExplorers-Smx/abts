import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/lyric_line.dart';
import 'lyrics_parser.dart';

/// 音乐歌词自动匹配（网易云）。
///
/// 导入本地音频后自动调用：按文件名（支持「歌手 - 歌名」格式）在网易云
/// 搜索歌曲并拉取 LRC 歌词，写入音频同目录 `<音频名>.lyrics.json`，
/// 播放页歌词视图离线直接可读。
/// 匹配失败一律静默返回，不打扰用户（章节页仍有手动导入文稿入口）。
class LyricMatcher {
  LyricMatcher._();

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Referer': 'https://music.163.com',
  };

  /// 从文件名提取搜索词：优先取「歌手 - 歌名」中的歌名，否则整个文件名。
  static String searchKeywordFromFile(String fileName) {
    var base = fileName.trim();
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    if (base.isEmpty) return '';
    final sep = RegExp(r'\s+-\s+');
    if (sep.hasMatch(base)) {
      return base.split(sep).last.trim();
    }
    return base;
  }

  /// 匹配并保存；返回是否成功写入。已有文稿时不覆盖。
  static Future<bool> matchAndSave(File audioFile, String fileName) async {
    final kw = searchKeywordFromFile(fileName);
    if (kw.isEmpty) return false;
    // 用户手动导入过文稿（或之前匹配成功）：不重复覆盖
    if (LyricsParser.lyricsFileExists(audioFile)) return false;
    try {
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
      final search = await dio.get(
        'https://music.163.com/api/search/get',
        queryParameters: {'s': kw, 'type': 1, 'limit': 3},
        options: Options(headers: _headers),
      );
      final result = ((search.data as Map?)?['result'] as Map?)?['songs'] as List?;
      if (result == null || result.isEmpty) return false;
      final id = ((result.first as Map?)?['id'] as num?)?.toInt();
      if (id == null || id <= 0) return false;
      final lyric = await dio.get(
        'https://music.163.com/api/song/lyric',
        queryParameters: {'id': id, 'lv': 1, 'kv': 1, 'tv': -1},
        options: Options(headers: _headers),
      );
      final lrc =
          (((lyric.data as Map?)?['lrc'] as Map?)?['lyric'] as String?)?.trim();
      if (lrc == null || lrc.isEmpty) return false;
      final lines = LyricsParser.parseLrc(lrc);
      if (lines.isEmpty) return false;
      await LyricsParser.saveLyricsFile(audioFile, lines);
      return true;
    } catch (e) {
      debugPrint('[LyricMatcher] 匹配失败（忽略）: $e');
      return false;
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/chapter.dart';
import 'baidu_asr.dart';
import 'lyric_matcher.dart';
import 'lyrics_parser.dart';

/// 本地音频导入：把用户选择的音频文件复制进应用目录，
/// 包装成一本"本地书"（bvid 以 `local_` 开头），
/// 与 B 站有声书共用书架 / 播放 / 进度体系。
///
/// 两种形态：
/// - 多章节书（推荐）：`local_books/<bookId>/` 目录，内含 `cover.jpg`（可选）
///   与按导入顺序命名的 `ch_001.mp3`…，Book.localDir 指向目录、每章带 localPath；
/// - 单文件书（旧入口兼容）：`local_books/<hash>.<ext>` 散文件，Book.localPath 指向文件。
class LocalLibrary {
  LocalLibrary._();
  static final LocalLibrary instance = LocalLibrary._();

  static const _dirName = 'local_books';

  /// 支持导入的音频扩展名（小写，不含点）
  static const supportedExtensions = [
    'mp3', 'm4a', 'm4b', 'aac', 'flac', 'wav', 'ogg', 'opus',
  ];

  /// 应用内本地书根目录（不存在则创建）
  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 是否为一本本地书
  static bool isLocalBook(Book book) => book.bvid.startsWith('local_');
  static bool isLocalBvid(String bvid) => bvid.startsWith('local_');

  /// 文件名去掉扩展名，清理为标题
  static String titleFromFile(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.trim().isEmpty ? '未命名音频' : base.trim();
  }

  static String _hashBytes(String s) {
    final h = md5.convert(Uint8List.fromList(s.codeUnits));
    return h.toString();
  }

  /// 章节 cid：由 文件路径+名称+大小 派生（基本唯一，保底非 0）
  static int _cidFor(String path, String name, int size) {
    final h = _hashBytes('$path|$name|$size');
    return h.codeUnits
            .take(8)
            .fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff) |
        1;
  }

  /// 创建一本书的元数据（目录 + 可选封面），返回空章节的本地书。
  /// 之后调用 [addAudioFiles] 往这本书里导入音频章节。
  Future<Book> createBook({
    required String title,
    String author = '本地文件',
    String desc = '',
    String? coverPath,
  }) async {
    final bookId = _hashBytes(
      '$title|$author|${DateTime.now().microsecondsSinceEpoch}|${_rand()}',
    ).substring(0, 10);
    final root = await _root();
    final dir = Directory('${root.path}/$bookId');
    if (!await dir.exists()) await dir.create(recursive: true);

    String pic = '';
    if (coverPath != null && await File(coverPath).exists()) {
      final cover = File('${dir.path}/cover.jpg');
      await File(coverPath).copy(cover.path);
      pic = 'file://${cover.path}';
    }

    return Book(
      bvid: 'local_$bookId',
      aid: 0,
      title: title.trim().isEmpty ? '未命名书' : title.trim(),
      pic: pic,
      pages: 0,
      duration: 0,
      author: author.trim().isEmpty ? '本地文件' : author.trim(),
      desc: desc.trim(),
      localDir: dir.path,
      chapters: <Chapter>[],
    );
  }

  /// 往本地书里追加音频章节：按导入顺序复制为 `ch_001.mp3`…
  /// 自动跳过已占用的序号，避免与删除后残留的编号冲突。
  /// 返回更新后的 Book（不修改传入对象）。
  Future<Book> addAudioFiles(Book book, List<String> paths) async {
    final dir = Directory(book.localDir!);
    if (!await dir.exists()) await dir.create(recursive: true);
    final chapters = <Chapter>[...?book.chapters];

    for (final p in paths) {
      final src = File(p);
      if (!await src.exists()) continue;
      final name = src.uri.pathSegments.isEmpty
          ? 'audio'
          : src.uri.pathSegments.last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (!supportedExtensions.contains(ext)) continue;
      final size = await src.length();
      var seq = chapters.length + 1;
      var storedName = 'ch_${seq.toString().padLeft(3, '0')}.$ext';
      while (await File('${dir.path}/$storedName').exists()) {
        seq++;
        storedName = 'ch_${seq.toString().padLeft(3, '0')}.$ext';
      }
      final dst = File('${dir.path}/$storedName');
      try {
        final tmp = File('${dst.path}.tmp');
        await src.copy(tmp.path);
        if (!await tmp.exists()) continue;
        await tmp.rename(dst.path);
        chapters.add(Chapter(
          cid: _cidFor(p, name, size),
          page: seq,
          part: titleFromFile(name),
          duration: 0,
          localPath: dst.path,
        ));
        // 导入后自动配文稿：先网易云匹配音乐歌词（免费）；
        // 未命中且用户已在设置里配置百度语音转写 → 自动转写生成文稿。
        // 全部失败静默，章节页仍可手动导入/转写
        unawaited(_autoLyrics(dst, name));
      } catch (_) {}
    }

    return _copyBook(book, chapters: chapters);
  }

  /// 自动生成章节文稿：网易云歌词匹配 → 百度语音转写（可选）。
  /// 网易云 LRC 只有行级时间戳，字级跟声需要词级时间戳，
  /// 因此配置了百度转写时，无论是否匹配到 LRC 都尝试升级为词级文稿。
  Future<void> _autoLyrics(File audioFile, String fileName) async {
    try {
      await LyricMatcher.matchAndSave(audioFile, fileName);
      await upgradeLyricsToWordLevel(audioFile);
    } catch (e) {
      debugPrint('[LocalLibrary] 自动文稿生成失败（忽略）: $e');
    }
  }

  /// 无词级文稿 → 百度转写升级为词级（v2）。
  /// 仅当文稿存在、且不含词级时间戳、且已配置百度转写时触发；
  /// 转写结果含词级时间戳才覆盖保存。返回是否升级成功。
  Future<bool> upgradeLyricsToWordLevel(File audioFile) async {
    try {
      final existing = LyricsParser.readLyricsFile(audioFile);
      if (existing == null || existing.isEmpty) return false;
      final hasWord = existing
          .any((l) => l.words != null && l.words!.isNotEmpty);
      if (hasWord) return false; // 已有词级时间戳，不重复转写
      final cfg = await BaiduAsr.loadConfig();
      if (!cfg.isConfigured || !cfg.enabled) return false;
      final lines = await BaiduAsr.transcribe(
        audioFile,
        apiKey: cfg.apiKey,
        secretKey: cfg.secretKey,
      );
      if (lines == null || lines.isEmpty) return false;
      if (!lines.any((l) => l.words != null && l.words!.isNotEmpty)) {
        return false; // 转写没有词级时间戳，保留原文稿
      }
      await LyricsParser.saveLyricsFile(audioFile, lines);
      debugPrint('[LocalLibrary] 词级文稿升级完成: '
          '${audioFile.path} (${lines.length} 行)');
      return true;
    } catch (e) {
      debugPrint('[LocalLibrary] 词级文稿升级失败（忽略）: $e');
      return false;
    }
  }

  /// 更新本地书的元信息（书名/作者/简介/封面）。
  /// [coverPath] 为空则保留原封面；传新路径则替换封面文件。
  Future<Book> updateBookMeta(
    Book book, {
    required String title,
    String author = '本地文件',
    String desc = '',
    String? coverPath,
  }) async {
    var pic = book.pic;
    final dirPath = book.localDir;
    if (dirPath != null && coverPath != null && await File(coverPath).exists()) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      final cover = File('${dir.path}/cover.jpg');
      try {
        await File(coverPath).copy(cover.path);
        pic = 'file://${cover.path}';
      } catch (_) {}
    }
    return _copyBook(
      book,
      title: title.trim().isEmpty ? book.title : title.trim(),
      author: author.trim().isEmpty ? '本地文件' : author.trim(),
      desc: desc.trim(),
      pic: pic,
    );
  }

  /// 删除一章：先删应用内音频文件，再更新章节列表。
  /// 返回更新后的 Book（不修改传入对象）。
  Future<Book> removeChapter(Book book, int index) async {
    final chapters = <Chapter>[...?book.chapters];
    if (index < 0 || index >= chapters.length) return book;
    final ch = chapters.removeAt(index);
    final p = ch.localPath;
    if (p != null) {
      try {
        final f = File(p);
        final root = await _root();
        if (f.absolute.path.startsWith(root.absolute.path) && await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }
    return _copyBook(book, chapters: chapters);
  }

  Book _copyBook(
    Book b, {
    String? title,
    String? author,
    String? desc,
    String? pic,
    List<Chapter>? chapters,
  }) {
    return Book(
      bvid: b.bvid,
      aid: b.aid,
      title: title ?? b.title,
      pic: pic ?? b.pic,
      pages: chapters?.length ?? b.pages,
      duration: b.duration,
      author: author ?? b.author,
      mid: b.mid,
      authorFace: b.authorFace,
      desc: desc ?? b.desc,
      play: b.play,
      like: b.like,
      coin: b.coin,
      favorite: b.favorite,
      pubdate: b.pubdate,
      upName: b.upName,
      localPath: b.localPath,
      localDir: b.localDir,
      chapters: chapters ?? b.chapters,
    );
  }

  String _rand() => (DateTime.now().millisecondsSinceEpoch % 7919).toString();

  // ---------- 旧单文件入口（向后兼容已导入数据） ----------

  /// 导入单个音频文件：复制进应用根目录并生成单文件 Book。
  /// 返回 null 表示目标文件不存在或不是受支持格式。
  Future<Book?> importFile(String sourcePath, {String? rename}) async {
    final src = File(sourcePath);
    if (!await src.exists()) return null;
    final name = src.uri.pathSegments.isEmpty
        ? 'audio'
        : src.uri.pathSegments.last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!supportedExtensions.contains(ext)) return null;
    final size = await src.length();

    final hash = _hashBytes('$sourcePath|$name|$size').substring(0, 12);
    final bvid = 'local_$hash';
    final storedName = '$hash.$ext';
    final root = await _root();
    final dst = File('${root.path}/$storedName');

    if (!await dst.exists()) {
      final tmp = File('${dst.path}.tmp');
      await src.copy(tmp.path);
      if (!await tmp.exists()) return null;
      await tmp.rename(dst.path);
    }

    final title = rename ?? titleFromFile(name);
    return Book(
      bvid: bvid,
      aid: 0,
      title: title,
      pic: '',
      pages: 1,
      duration: 0,
      author: '本地文件',
      desc: '导入的本地音频',
      localPath: dst.path,
      chapters: [
        Chapter(
          cid: _cidFor(sourcePath, name, size),
          page: 1,
          part: title,
          duration: 0,
          localPath: dst.path,
        ),
      ],
    );
  }

  /// 批量导入（单文件入口）；返回（成功列表，失败路径列表）
  Future<(List<Book>, List<String>)> importFiles(List<String> paths) async {
    final ok = <Book>[];
    final failed = <String>[];
    for (final p in paths) {
      try {
        final book = await importFile(p);
        if (book == null) {
          failed.add(p);
        } else {
          ok.add(book);
        }
      } catch (_) {
        failed.add(p);
      }
    }
    return (ok, failed);
  }

  // ---------- 删除 ----------

  /// 删除一本本地书：多章节书删整个目录，单文件书删文件。
  /// 只动应用内 local_books 目录，绝不触碰用户其他文件。
  Future<void> deleteLocalBook(Book book) async {
    final root = await _root();
    final rootAbs = root.absolute.path;
    final dirPath = book.localDir;
    if (dirPath != null) {
      final d = Directory(dirPath);
      if (d.absolute.path.startsWith(rootAbs) && await d.exists()) {
        try {
          await d.delete(recursive: true);
        } catch (_) {}
      }
      return;
    }
    final p = book.localPath;
    if (p == null) return;
    final f = File(p);
    if (f.absolute.path.startsWith(rootAbs) && await f.exists()) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}

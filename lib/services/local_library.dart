import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/chapter.dart';

/// 本地音频导入：把用户选择的音频文件复制进应用目录，
/// 包装成一本"本地书"（bvid 以 `local_` 开头，localPath 指向应用内文件），
/// 与 B 站有声书共用书架 / 播放 / 进度体系。
class LocalLibrary {
  LocalLibrary._();
  static final LocalLibrary instance = LocalLibrary._();

  static const _dirName = 'local_books';

  /// 支持导入的音频扩展名（小写，不含点）
  static const supportedExtensions = [
    'mp3', 'm4a', 'm4b', 'aac', 'flac', 'wav', 'ogg', 'opus',
  ];

  /// 应用内本地书目录（不存在则创建）
  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 是否为一本本地书
  static bool isLocalBook(Book book) => book.bvid.startsWith('local_');
  static bool isLocalBvid(String bvid) => bvid.startsWith('local_');

  /// 文件名去掉扩展名，清理为书名
  static String titleFromFile(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.trim().isEmpty ? '未命名音频' : base.trim();
  }

  /// 由 路径+文件名+大小 派生稳定 id（同文件重复导入指向同一本书）
  static String _hash(String path, String name, int size) {
    final h = md5.convert(Uint8List.fromList(
        '$path|$name|$size'.codeUnits));
    return h.toString().substring(0, 12);
  }

  /// 导入单个音频文件：复制进应用目录并生成 Book。
  /// 返回 null 表示目标文件不存在或不是受支持格式。
  /// [rename] 可选，覆盖默认书名（文件名去扩展名）。
  Future<Book?> importFile(String sourcePath, {String? rename}) async {
    final src = File(sourcePath);
    if (!await src.exists()) return null;
    final name = src.uri.pathSegments.isEmpty
        ? 'audio'
        : src.uri.pathSegments.last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!supportedExtensions.contains(ext)) return null;
    final size = await src.length();

    final hash = _hash(sourcePath, name, size);
    final bvid = 'local_$hash';
    final storedName = '$hash.$ext';
    final dir = await _dir();
    final dst = File('${dir.path}/$storedName');

    if (!await dst.exists()) {
      // 复制：先写临时文件再改名，避免半截文件被当成已导入
      final tmp = File('${dst.path}.tmp');
      await src.copy(tmp.path);
      if (!await tmp.exists()) return null;
      await tmp.rename(dst.path);
    }

    final title = rename ?? titleFromFile(name);
    final cid = int.tryParse(
            hash.codeUnits.take(8).fold<int>(0, (a, b) => a * 31 + b).toString()) ??
        0;

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
          cid: cid,
          page: 1,
          part: title,
          duration: 0,
        ),
      ],
    );
  }

  /// 批量导入；返回（成功列表，失败原因列表）
  Future<(List<Book>, List<String>)> importFiles(
    List<String> paths, {
    String? Function(String path)? renameFor,
  }) async {
    final ok = <Book>[];
    final failed = <String>[];
    for (final p in paths) {
      try {
        final book = await importFile(
          p,
          rename: renameFor?.call(p),
        );
        if (book == null) {
          failed.add('$p：文件不存在或格式不支持');
        } else {
          ok.add(book);
        }
      } catch (e) {
        failed.add('$p：$e');
      }
    }
    return (ok, failed);
  }

  /// 删除一本书的本地文件（仅限应用内 local_books 目录，防止误删用户文件）
  Future<void> deleteLocalFile(Book book) async {
    final p = book.localPath;
    if (p == null) return;
    final dir = await _dir();
    final canonical = File(p).absolute.path;
    if (!canonical.startsWith(dir.absolute.path)) return; // 非应用内，不动
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/book.dart';

/// 书籍详情本地缓存：把 Book + 章节目录序列化到本地文件，
/// 供离线场景（如无网环境下从书架进入详情页）直接读取。
class BookCache {
  BookCache._();

  static const _dirName = 'book_cache';

  static String _fileName(String bvid) =>
      '${bvid.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.json';

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 保存书籍详情（含章节目录）。失败静默（缓存失败不影响主流程）。
  static Future<void> save(Book book) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_fileName(book.bvid)}');
      await f.writeAsString(jsonEncode(book.toJson()));
    } catch (_) {}
  }

  /// 读取书籍详情缓存；无缓存或损坏返回 null。
  static Future<Book?> load(String bvid) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_fileName(bvid)}');
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final book = Book.fromJson(m);
      if (book.bvid.isEmpty || book.bvid != bvid) return null;
      return book;
    } catch (_) {
      return null;
    }
  }

  /// 删除某本书的缓存（整本删除下载时一并清理）。
  static Future<void> delete(String bvid) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_fileName(bvid)}');
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}

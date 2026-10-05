import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_task.dart';

/// 一本书的下载汇总（下载页按书分组展示用）
class DownloadBookSummary {
  final String bvid;
  final String title;
  final String pic;
  final String author;
  final int total; // 总章节数
  final int done; // 已下载章节数
  final int downloading; // 下载中/排队/暂停/失败 任务数
  final int bytes; // 已落盘字节数（含 .part）
  final int updatedAt;

  DownloadBookSummary({
    required this.bvid,
    required this.title,
    required this.pic,
    required this.author,
    required this.total,
    required this.done,
    required this.downloading,
    required this.bytes,
    required this.updatedAt,
  });

  bool get allDone => total > 0 && done >= total;
}

/// 章节下载任务仓库：内存态 + SharedPreferences 持久化
class DownloadStore extends ChangeNotifier {
  DownloadStore._();
  static final DownloadStore instance = DownloadStore._();

  static const _key = 'abts_downloads_v1';

  final List<DownloadTask> _tasks = [];

  /// 按创建时间倒序返回副本
  List<DownloadTask> get tasks {
    final sorted = [..._tasks]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(sorted);
  }

  /// 某本书的章节（按章节目录顺序，供详情页逐章展示）
  List<DownloadTask> tasksForBook(String bvid) {
    final list = _tasks.where((t) => t.bvid == bvid).toList()
      ..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    return List.unmodifiable(list);
  }

  DownloadTask? taskFor(String bvid, int cid) {
    for (final t in _tasks) {
      if (t.bvid == bvid && t.cid == cid) return t;
    }
    return null;
  }

  bool isDownloaded(String bvid, int cid) =>
      taskFor(bvid, cid)?.completed == true;

  /// 已下载章节的本地路径（无则 null）
  String? localPathFor(String bvid, int cid) {
    final t = taskFor(bvid, cid);
    if (t == null || !t.completed) return null;
    final p = t.localPath;
    if (p == null || p.isEmpty) return null;
    return p;
  }

  int get doneCount => _tasks.where((t) => t.completed).length;
  int get activeCount =>
      _tasks.where((t) => t.active || t.status == DownloadStatus.paused).length;

  /// 已下载文件占用空间（字节）
  int get totalBytes {
    var sum = 0;
    for (final t in _tasks) {
      if (t.completed) {
        sum += t.totalBytes > 0 ? t.totalBytes : t.receivedBytes;
      } else {
        sum += t.receivedBytes;
      }
    }
    return sum;
  }

  /// 按书汇总（用于下载页分组头）
  List<DownloadBookSummary> bookSummaries() {
    final byBook = <String, List<DownloadTask>>{};
    for (final t in _tasks) {
      byBook.putIfAbsent(t.bvid, () => []).add(t);
    }
    final out = <DownloadBookSummary>[];
    for (final entry in byBook.entries) {
      final list = entry.value;
      final done = list.where((t) => t.completed).length;
      final active = list.length - done;
      final bytes = list.fold<int>(
        0,
        (s, t) => s +
            (t.completed
                ? (t.totalBytes > 0 ? t.totalBytes : t.receivedBytes)
                : t.receivedBytes),
      );
      final latest = list
          .map((t) => t.updatedAt)
          .reduce((a, b) => a > b ? a : b);
      final first = list.first;
      out.add(DownloadBookSummary(
        bvid: entry.key,
        title: first.bookTitle,
        pic: first.pic,
        author: first.author,
        total: first.pages > 0 ? first.pages : list.length,
        done: done,
        downloading: active,
        bytes: bytes,
        updatedAt: latest,
      ));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _tasks
        ..clear()
        ..addAll(list.map((e) =>
            DownloadTask.fromJson((e as Map).cast<String, dynamic>())));
      notifyListeners();
    } catch (_) {}
  }

  /// 持久化到 SharedPreferences（进度/状态变更由 DownloadManager 节流调用）
  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_tasks.map((t) => t.toJson()).toList()),
    );
  }

  /// 新增任务（同一章节已存在则不重复添加）
  Future<void> add(DownloadTask task) async {
    if (taskFor(task.bvid, task.cid) != null) return;
    _tasks.add(task);
    notifyListeners();
    await persist();
  }

  /// 批量新增（整本下载用，只通知并落盘一次）
  Future<void> addAll(List<DownloadTask> tasks) async {
    var added = false;
    for (final t in tasks) {
      if (taskFor(t.bvid, t.cid) != null) continue;
      _tasks.add(t);
      added = true;
    }
    if (!added) return;
    notifyListeners();
    await persist();
  }

  Future<void> remove(String bvid, int cid) async {
    _tasks.removeWhere((t) => t.bvid == bvid && t.cid == cid);
    notifyListeners();
    await persist();
  }

  /// 删除某本书的全部任务
  Future<void> removeBook(String bvid) async {
    _tasks.removeWhere((t) => t.bvid == bvid);
    notifyListeners();
    await persist();
  }

  /// 清空全部任务
  Future<void> clearAll() async {
    _tasks.clear();
    notifyListeners();
    await persist();
  }
}

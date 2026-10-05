import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/network/api_config.dart';
import '../models/audio_stream.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/download_task.dart';
import 'bili_api.dart';
import 'download_store.dart';
import 'umeng_analytics.dart';

/// 章节下载管理器：并发队列 + HTTP Range 断点续传 + 自动重试。
///
/// - 断点续传：下载中数据写入 `<bvid>_<cid>.part`，暂停/被杀后保留；
///   恢复时按已落盘字节数发 `Range: bytes=N-`，服务器支持 206 即续传，
///   不支持（200）则从头重下；416 表示区间失效，清空重下。
/// - 队列：最多 [_maxConcurrent] 个并发，其余排队，完成一个自动补位。
/// - 重试：单条候选地址网络失败自动退避重试，候选地址耗尽才判失败；
///   任务开始/恢复时重新解析 playurl（B 站签名链接有时效），避免旧链接失效。
/// - 持久化：状态/进度写入 DownloadStore（SharedPreferences），
///   应用重启或回前台后自动把未完成任务重新入队续传。
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final DownloadStore _store = DownloadStore.instance;
  final BiliApi _api = BiliApi.instance;

  late Dio _dio;
  Directory? _dir;
  bool _ready = false;

  static const int _maxConcurrent = 2;
  static const int _maxRetries = 3;

  /// 进度落盘节流（避免每块数据都写 SharedPreferences）
  static const Duration _persistInterval = Duration(seconds: 3);
  /// UI 通知节流（避免进度导致整页高频重建）
  static const Duration _notifyInterval = Duration(milliseconds: 200);
  /// 速度采样窗口
  static const Duration _speedInterval = Duration(seconds: 1);

  final Map<String, CancelToken> _tokens = {};
  final Map<String, Future<void>> _running = {};
  final List<String> _queue = [];
  final Map<String, int> _lastPersistAt = {};
  final Map<String, int> _lastNotifyAt = {};
  final Map<String, _SpeedSample> _speed = {};
  int _active = 0;

  DownloadStore get store => _store;
  bool get ready => _ready;

  Directory? get downloadDir => _dir;

  /// 下载目录（无则不显示路径）
  String get downloadDirText {
    final d = _dir;
    if (d == null) return '';
    return d.path;
  }

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    _setupDio();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/downloads');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
      debugPrint('[DownloadManager] 下载目录: ${dir.path}');
    } catch (e) {
      debugPrint('[DownloadManager] 初始化目录失败: $e');
    }
    await _store.load();
    // 冷启动恢复：把上次未完成的任务重新入队续传
    for (final t in _store.tasks) {
      if (t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.queued) {
        t.status = DownloadStatus.queued;
        _queue.add(t.key);
      }
    }
    if (_queue.isNotEmpty) {
      notifyListeners();
      _pump();
    }
  }

  void _setupDio() {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 60),
      ),
    );
  }

  // ---------- 对外操作 ----------

  /// 加入下载队列（单章）。已存在且完成/进行中则不重复入队；
  /// 失败的任务再次点击视为重试。
  Future<void> enqueue(Book book, Chapter chapter, int index) async {
    final existing = _store.taskFor(book.bvid, chapter.cid);
    if (existing != null) {
      if (existing.completed) return;
      if (existing.active) return;
      // paused / failed → 恢复
      _setStatus(existing, DownloadStatus.queued);
      existing.error = null;
      _enqueueKey(existing.key);
      _pump();
      return;
    }
    final task = DownloadTask(
      bvid: book.bvid,
      cid: chapter.cid,
      chapterIndex: index,
      part: chapter.part,
      bookTitle: book.cleanTitle,
      pic: Book.normalizePic(book.pic),
      author: book.author,
      durationSec: chapter.duration,
      pages: book.pages,
      status: DownloadStatus.queued,
    );
    await _store.add(task);
    AppAnalytics.onEvent('download_add', {'bvid': book.bvid});
    _enqueueKey(task.key);
    _pump();
  }

  /// 整本书未下载的章节全部入队
  Future<void> enqueueAll(Book book) async {
    final chapters = book.chapters;
    if (chapters == null || chapters.isEmpty) return;
    final fresh = <DownloadTask>[];
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final existing = _store.taskFor(book.bvid, ch.cid);
      if (existing != null) {
        if (existing.completed || existing.active) continue;
        _setStatus(existing, DownloadStatus.queued);
        existing.error = null;
        _enqueueKey(existing.key);
      } else {
        final task = DownloadTask(
          bvid: book.bvid,
          cid: ch.cid,
          chapterIndex: i,
          part: ch.part,
          bookTitle: book.cleanTitle,
          pic: Book.normalizePic(book.pic),
          author: book.author,
          durationSec: ch.duration,
          pages: book.pages,
          status: DownloadStatus.queued,
        );
        fresh.add(task);
        _enqueueKey(task.key);
      }
    }
    if (fresh.isNotEmpty) {
      await _store.addAll(fresh);
      AppAnalytics.onEvent('download_add_all',
          {'bvid': book.bvid, 'count': fresh.length});
    }
    _pump();
  }

  /// 暂停单个任务（保留 .part）
  void pause(String bvid, int cid) {
    final task = _store.taskFor(bvid, cid);
    if (task == null || !task.active) return;
    _tokens.remove(task.key)?.cancel();
    _setStatus(task, DownloadStatus.paused);
    _speed.remove(task.key);
    _removeFromQueue(task.key);
    notifyListeners();
    _persistSoon(task);
  }

  /// 恢复单个任务（paused / failed）
  void resume(String bvid, int cid) {
    final task = _store.taskFor(bvid, cid);
    if (task == null || task.completed || task.active) return;
    _setStatus(task, DownloadStatus.queued);
    task.error = null;
    _enqueueKey(task.key);
    _pump();
  }

  /// 删除单个任务（含本地文件）
  Future<void> delete(String bvid, int cid) async {
    final task = _store.taskFor(bvid, cid);
    if (task == null) return;
    _tokens.remove(task.key)?.cancel();
    _removeFromQueue(task.key);
    _running.remove(task.key);
    _speed.remove(task.key);
    await _deleteFiles(task);
    await _store.remove(bvid, cid);
  }

  /// 删除某本书的全部下载（含本地文件）
  Future<void> deleteBook(String bvid) async {
    final tasks = _store.tasksForBook(bvid);
    for (final t in tasks) {
      _tokens.remove(t.key)?.cancel();
      _removeFromQueue(t.key);
      _speed.remove(t.key);
      await _deleteFiles(t);
    }
    await _store.removeBook(bvid);
  }

  /// 删除所有已完成任务（含文件）
  Future<void> deleteCompleted() async {
    final done = _store.tasks.where((t) => t.completed).toList();
    for (final t in done) {
      await _deleteFiles(t);
    }
    for (final t in done) {
      await _store.remove(t.bvid, t.cid);
    }
  }

  /// 全部开始：把暂停/失败的任务重新入队
  void resumeAll() {
    var changed = false;
    for (final t in _store.tasks) {
      if (t.completed || t.active) continue;
      _setStatus(t, DownloadStatus.queued);
      t.error = null;
      _enqueueKey(t.key);
      changed = true;
    }
    if (changed) {
      notifyListeners();
      _pump();
    }
  }

  /// 全部暂停
  void pauseAll() {
    final tokens = _tokens.values.toList();
    for (final tk in tokens) {
      tk.cancel();
    }
    var changed = false;
    for (final t in _store.tasks) {
      if (!t.active) continue;
      _setStatus(t, DownloadStatus.paused);
      _speed.remove(t.key);
      changed = true;
    }
    _queue.clear();
    if (changed) {
      notifyListeners();
      for (final t in _store.tasks) {
        if (t.status == DownloadStatus.paused) _persistSoon(t);
      }
    }
  }

  /// 应用回前台：把仍标记为下载中/排队但实际已中断的任务重新续传
  void onAppResumed() {
    var changed = false;
    for (final t in _store.tasks) {
      if (t.completed || t.status == DownloadStatus.paused) continue;
      if (t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.queued) {
        _setStatus(t, DownloadStatus.queued);
        _enqueueKey(t.key);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _pump();
    }
  }

  // ---------- 队列调度 ----------

  void _enqueueKey(String key) {
    if (!_queue.contains(key) && !_running.containsKey(key)) {
      _queue.add(key);
    }
  }

  void _removeFromQueue(String key) {
    _queue.remove(key);
  }

  void _pump() {
    while (_active < _maxConcurrent && _queue.isNotEmpty) {
      final key = _queue.removeAt(0);
      if (_running.containsKey(key)) continue;
      final task = _storeTask(key);
      if (task == null || task.completed) continue;
      _running[key] = _run(task);
      _active++;
    }
  }

  DownloadTask? _storeTask(String key) {
    // key = bvid_cid
    final idx = key.indexOf('_');
    if (idx <= 0) return null;
    final bvid = key.substring(0, idx);
    final cid = int.tryParse(key.substring(idx + 1)) ?? 0;
    return _store.taskFor(bvid, cid);
  }

  Future<void> _run(DownloadTask task) async {
    final key = task.key;
    try {
      _setStatus(task, DownloadStatus.downloading);
      task.error = null;
      final ok = await _downloadWithRetry(task);
      if (ok) {
        final finalized = await _finalize(task);
        if (!finalized) {
          _fail(task, '文件写入失败');
        }
      }
    } finally {
      _running.remove(key);
      _tokens.remove(key);
      _active--;
      _pump();
    }
  }

  // ---------- 断点续传核心 ----------

  Future<bool> _downloadWithRetry(DownloadTask task) async {
    final key = task.key;
    List<String> candidates;
    try {
      candidates = await _resolveCandidates(task.bvid, task.cid);
    } catch (e) {
      _fail(task, '获取音频链接失败：$e');
      return false;
    }
    if (candidates.isEmpty) {
      _fail(task, '该章节没有可下载的音频');
      return false;
    }

    String? lastError;
    for (var i = 0; i < candidates.length; i++) {
      for (var attempt = 0; attempt < _maxRetries; attempt++) {
        final token = CancelToken();
        _tokens[key] = token;
        try {
          final done = await _downloadCandidate(task, candidates[i], token);
          if (done) return true;
          // 服务器给了总长但没下全 → 稍等后从断点续传（下一次 attempt 或换候选）
          lastError = '下载不完整';
          if (attempt < _maxRetries - 1) {
            await Future<void>.delayed(const Duration(milliseconds: 600));
          }
          continue;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            // 用户暂停/删除：置为暂停并退出
            if (_store.taskFor(task.bvid, task.cid) != null) {
              _setStatus(task, DownloadStatus.paused);
              _speed.remove(key);
              _persistSoon(task);
            }
            return false;
          }
          lastError = _dioErrorText(e);
          debugPrint('[DownloadManager] 候选$i 第$attempt 次失败: $lastError');
          if (attempt < _maxRetries - 1) {
            await Future<void>.delayed(
                Duration(milliseconds: 800 * (attempt + 1)));
          }
        } catch (e) {
          lastError = '$e';
          debugPrint('[DownloadManager] 候选$i 异常: $e');
          if (attempt < _maxRetries - 1) {
            await Future<void>.delayed(
                Duration(milliseconds: 800 * (attempt + 1)));
          }
        }
      }
    }
    _fail(task, lastError ?? '下载失败');
    return false;
  }

  /// 单次候选地址的断点下载；成功（数据完整）返回 true。
  Future<bool> _downloadCandidate(
      DownloadTask task, String url, CancelToken token) async {
    final key = task.key;
    final dir = _dir;
    if (dir == null) throw StateError('下载目录不可用');

    final partFile = File('${dir.path}/$key.part');
    var received = task.receivedBytes;
    if (await partFile.exists()) {
      final size = await partFile.length();
      if (size != received) {
        // 应用重启后以实际文件为准（进程中断期间文件可能已增长）
        received = size;
        task.receivedBytes = received;
      }
    }

    final res = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (s) =>
            s != null && (s == 200 || s == 206 || s == 416),
        headers: {
          'User-Agent': BiliEndpoints.userAgent,
          'Referer': BiliEndpoints.home,
          // 禁用压缩，保证 Content-Length 与落盘字节一致
          'Accept-Encoding': 'identity',
          if (received > 0) 'Range': 'bytes=$received-',
        },
      ),
      cancelToken: token,
    );

    final status = res.statusCode;
    if (status == 416) {
      // 区间失效（服务端可能已回收或文件已变）：清空从头下
      received = 0;
      task.receivedBytes = 0;
      if (await partFile.exists()) {
        await partFile.delete();
      }
      return false; // 回到外层重试循环（新的一次会用 0 起始）
    }

    if (status == 206) {
      final cr = res.headers.value('content-range');
      final total = _parseContentRangeTotal(cr);
      if (total != null && total > 0) task.totalBytes = total;
    } else if (status == 200) {
      // 服务器忽略 Range：从头下载
      received = 0;
      task.receivedBytes = 0;
      if (await partFile.exists()) {
        await partFile.delete();
      }
      final len = res.headers.value('content-length');
      final total = int.tryParse(len ?? '') ?? 0;
      if (total > 0) task.totalBytes = total;
    }

    final raf = await partFile.open(
        mode: status == 200 ? FileMode.write : FileMode.append);
    final stream = res.data?.stream;
    if (stream == null) {
      await raf.close();
      return false;
    }
    try {
      await for (final chunk in stream) {
        if (chunk.isEmpty) continue;
        await raf.writeFrom(chunk);
        received += chunk.length;
        task.receivedBytes = received;
        _onProgress(task);
      }
    } finally {
      await raf.close();
    }

    task.receivedBytes = received;
    if (status == 200) {
      task.totalBytes = received;
    }
    // 数据完整才判成功
    return task.totalBytes <= 0 || received >= task.totalBytes;
  }

  Future<bool> _finalize(DownloadTask task) async {
    final dir = _dir;
    if (dir == null) return false;
    final key = task.key;
    final partFile = File('${dir.path}/$key.part');
    final finalFile = File('${dir.path}/$key.m4s');
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    if (!await partFile.exists()) {
      return false;
    }
    try {
      await partFile.rename(finalFile.path);
    } catch (e) {
      debugPrint('[DownloadManager] 落盘失败: $e');
      return false;
    }
    task
      ..status = DownloadStatus.completed
      ..localPath = finalFile.path
      ..receivedBytes =
          task.totalBytes > 0 ? task.totalBytes : task.receivedBytes
      ..error = null
      ..speedBps = 0;
    _speed.remove(key);
    notifyListeners();
    await _store.persist();
    AppAnalytics.onEvent('download_complete', {'bvid': task.bvid});
    debugPrint('[DownloadManager] 完成: $key -> ${finalFile.path}');
    return true;
  }

  Future<void> _deleteFiles(DownloadTask task) async {
    final dir = _dir;
    if (dir == null) return;
    final key = task.key;
    for (final name in ['$key.part', '$key.m4s']) {
      try {
        final f = File('${dir.path}/$name');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  // ---------- 状态/进度 ----------

  void _setStatus(DownloadTask task, DownloadStatus status) {
    task.status = status;
    task.updatedAt = DateTime.now().millisecondsSinceEpoch;
  }

  void _onProgress(DownloadTask task) {
    final key = task.key;
    final now = DateTime.now().millisecondsSinceEpoch;

    // 速度采样（每秒）
    final s = _speed.putIfAbsent(
        key, () => _SpeedSample(now: now, bytes: task.receivedBytes));
    if (now - s.now >= _speedInterval.inMilliseconds) {
      final dt = now - s.now;
      if (dt > 0) {
        task.speedBps =
            ((task.receivedBytes - s.bytes) * 1000 / dt).round().clamp(0, 1 << 62);
      }
      s.now = now;
      s.bytes = task.receivedBytes;
    }

    // UI 通知节流
    final lastNotify = _lastNotifyAt[key] ?? 0;
    if (now - lastNotify >= _notifyInterval.inMilliseconds) {
      _lastNotifyAt[key] = now;
      notifyListeners();
    }

    // 落盘节流
    final lastPersist = _lastPersistAt[key] ?? 0;
    if (now - lastPersist >= _persistInterval.inMilliseconds) {
      _lastPersistAt[key] = now;
      unawaited(_store.persist());
    }
  }

  void _persistSoon(DownloadTask task) {
    _lastPersistAt[task.key] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_store.persist());
  }

  void _fail(DownloadTask task, String message) {
    if (_store.taskFor(task.bvid, task.cid) == null) return;
    _setStatus(task, DownloadStatus.failed);
    task
      ..error = message
      ..speedBps = 0;
    _speed.remove(task.key);
    notifyListeners();
    unawaited(_store.persist());
    debugPrint('[DownloadManager] 失败: ${task.key} $message');
  }

  // ---------- 取流 ----------

  /// 与播放器一致的候选地址：AAC 按带宽降序，flac/dolby 兜底，http 转 https
  Future<List<String>> _resolveCandidates(String bvid, int cid) async {
    final audio = await _api.playUrl(bvid, cid);
    final list = <String>[];

    void add(AudioTrack? t) {
      if (t == null) return;
      String toHttps(String u) =>
          u.startsWith('http://') ? 'https://${u.substring(7)}' : u;
      if (t.baseUrl.isNotEmpty) list.add(toHttps(t.baseUrl));
      for (final b in t.backupUrls) {
        if (b.isNotEmpty) list.add(toHttps(b));
      }
    }

    final aac = [...audio.tracks]
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    for (final t in aac) {
      add(t);
    }
    add(audio.flac);
    add(audio.dolby);
    return list.toSet().toList();
  }

  static int? _parseContentRangeTotal(String? cr) {
    if (cr == null) return null;
    final idx = cr.lastIndexOf('/');
    if (idx < 0) return null;
    return int.tryParse(cr.substring(idx + 1).trim());
  }

  static String _dioErrorText(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '网络超时';
    }
    if (e.type == DioExceptionType.connectionError) return '网络连接失败';
    final sc = e.response?.statusCode;
    if (sc == 403) return '链接失效(403)，已自动换源';
    if (sc == 404) return '资源不存在(404)';
    if (sc != null) return 'HTTP $sc';
    return '网络错误';
  }
}

class _SpeedSample {
  int now;
  int bytes;
  _SpeedSample({required this.now, required this.bytes});
}

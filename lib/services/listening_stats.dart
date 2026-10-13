import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 收听时长统计：按天累计（yyyy-MM-dd → 秒）。
/// 播放器每秒 track 一次，攒到 30 秒落一次盘，退出时 flush。
class ListeningStats {
  ListeningStats._();
  static final ListeningStats instance = ListeningStats._();

  static const _key = 'abts_listen_stats_v1';

  Map<String, int> _days = {};
  int _pendingSec = 0;
  bool _loaded = false;

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        _days = (jsonDecode(raw) as Map)
            .map((k, v) => MapEntry('$k', (v as num).toInt()));
      }
    } catch (_) {}
    _loaded = true;
  }

  /// 每秒累计（播放中才调用）
  void track(Duration d) {
    _pendingSec += d.inSeconds;
    if (_pendingSec >= 30) {
      unawaitedFlush();
    }
  }

  void unawaitedFlush() {
    if (_pendingSec <= 0) return;
    final t = DateTime.now();
    _days[_dayKey(t)] = (_days[_dayKey(t)] ?? 0) + _pendingSec;
    _pendingSec = 0;
    unawaited(_save());
  }

  Future<void> flush() async {
    await _load();
    if (_pendingSec <= 0) return;
    final t = DateTime.now();
    _days[_dayKey(t)] = (_days[_dayKey(t)] ?? 0) + _pendingSec;
    _pendingSec = 0;
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_days));
    } catch (_) {}
  }

  /// 今日收听秒数
  Future<int> todaySeconds() async {
    await _load();
    return _days[_dayKey(DateTime.now())] ?? 0;
  }

  /// 本周（本周一 0 点起）收听秒数
  Future<int> weekSeconds() async {
    await _load();
    final now = DateTime.now();
    final weekday = now.weekday; // 1=周一..7=周日
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: weekday - 1));
    var total = 0;
    for (var i = 0; i < 7; i++) {
      final d = monday.add(Duration(days: i));
      if (d.isAfter(now)) break;
      total += _days[_dayKey(d)] ?? 0;
    }
    return total;
  }

  /// 累计收听秒数
  Future<int> totalSeconds() async {
    await _load();
    return _days.values.fold<int>(0, (a, b) => a + b);
  }

  static String text(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h <= 0) return '$m 分钟';
    return '$h 小时 $m 分';
  }
}

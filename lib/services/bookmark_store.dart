import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 书签：保存收听位置（书 + 章节 + 时间点 + 可选备注）
class Bookmark {
  final String bvid;
  final String title; // 书名
  final int chapterIndex;
  final int cid;
  final String chapterTitle;
  final int positionMs;
  final String note;
  final int createdAt;

  const Bookmark({
    required this.bvid,
    required this.title,
    required this.chapterIndex,
    required this.cid,
    required this.chapterTitle,
    required this.positionMs,
    this.note = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'title': title,
        'chapterIndex': chapterIndex,
        'cid': cid,
        'chapterTitle': chapterTitle,
        'positionMs': positionMs,
        'note': note,
        'createdAt': createdAt,
      };

  factory Bookmark.fromJson(Map<String, dynamic> m) => Bookmark(
        bvid: m['bvid'] as String? ?? '',
        title: m['title'] as String? ?? '',
        chapterIndex: int.tryParse('${m['chapterIndex'] ?? 0}') ?? 0,
        cid: int.tryParse('${m['cid'] ?? 0}') ?? 0,
        chapterTitle: m['chapterTitle'] as String? ?? '',
        positionMs: int.tryParse('${m['positionMs'] ?? 0}') ?? 0,
        note: m['note'] as String? ?? '',
        createdAt: int.tryParse('${m['createdAt'] ?? 0}') ?? 0,
      );

  /// 时间点文案（h:mm:ss / mm:ss）
  String get positionText {
    final p = Duration(milliseconds: positionMs);
    final h = p.inHours;
    final m = p.inMinutes % 60;
    final s = p.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }
}

/// 书签存储（SharedPreferences，按创建时间倒序）
class BookmarkStore extends ChangeNotifier {
  BookmarkStore._();
  static final BookmarkStore instance = BookmarkStore._();

  static const _key = 'abts_bookmarks_v1';

  final List<Bookmark> _items = [];
  bool _loaded = false;

  /// 按创建时间倒序返回
  List<Bookmark> get items {
    final sorted = [..._items]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(sorted);
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      _items
        ..clear()
        ..addAll(list.map(
            (e) => Bookmark.fromJson((e as Map).cast<String, dynamic>())));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(_items.map((b) => b.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> add(Bookmark b) async {
    await load();
    _items.add(b);
    notifyListeners();
    await _save();
  }

  Future<void> remove(int createdAt) async {
    _items.removeWhere((b) => b.createdAt == createdAt);
    notifyListeners();
    await _save();
  }
}

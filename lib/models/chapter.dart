/// 章节（分P）
class Chapter {
  final int cid;
  final int page;
  final String part;
  final int duration; // 秒

  /// 本地导入书：本章节对应的音频文件绝对路径（空表示在线章节/单文件本地书）
  final String? localPath;

  Chapter({
    required this.cid,
    required this.page,
    required this.part,
    this.duration = 0,
    this.localPath,
  });

  factory Chapter.fromMap(Map<String, dynamic> m) => Chapter(
        cid: int.tryParse('${m['cid'] ?? 0}') ?? 0,
        page: int.tryParse('${m['page'] ?? 0}') ?? 0,
        part: m['part'] as String? ?? '',
        duration: int.tryParse('${m['duration'] ?? 0}') ?? 0,
        localPath: m['localPath'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'page': page,
        'part': part,
        'duration': duration,
        if (localPath != null) 'localPath': localPath,
      };

  factory Chapter.fromJson(Map<String, dynamic> m) => Chapter.fromMap(m);

  String get durationText {
    if (duration <= 0) return '';
    final h = duration ~/ 3600;
    final m = (duration % 3600) ~/ 60;
    final s = duration % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
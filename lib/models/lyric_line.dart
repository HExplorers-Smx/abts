/// 一行歌词 / 字幕（时间单位为秒）
class LyricLine {
  final double start;
  final double end;
  final String text;

  const LyricLine({
    required this.start,
    required this.end,
    required this.text,
  });

  Duration get startDuration =>
      Duration(milliseconds: (start * 1000).round());

  /// 行时长（至少 50ms，避免除以 0）
  double get duration {
    final d = end - start;
    return d > 0.05 ? d : 0.05;
  }

  factory LyricLine.fromJson(Map<String, dynamic> m) => LyricLine(
        start: (m['start'] as num?)?.toDouble() ?? 0,
        end: (m['end'] as num?)?.toDouble() ?? 0,
        text: m['text'] as String? ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'start': start, 'end': end, 'text': text};
}

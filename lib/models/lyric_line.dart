/// 词级时间（时间单位为秒）。百度音频文件转写 detailed_result.words_info
/// 提供毫秒级词时间戳；无词级数据时该列表为空，渲染层回退句内均分。
class LyricWord {
  final String word;
  final double start;
  final double end;

  const LyricWord({
    required this.word,
    required this.start,
    required this.end,
  });

  double get duration {
    final d = end - start;
    return d > 0.01 ? d : 0.01;
  }

  factory LyricWord.fromJson(Map<String, dynamic> m) => LyricWord(
        word: m['w'] as String? ?? '',
        start: (m['s'] as num?)?.toDouble() ?? 0,
        end: (m['e'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {'w': word, 's': start, 'e': end};
}

/// 一行歌词 / 字幕（时间单位为秒）
class LyricLine {
  final double start;
  final double end;
  final String text;

  /// 词级时间戳（可为空；空时渲染层按句内字数均分）
  final List<LyricWord>? words;

  const LyricLine({
    required this.start,
    required this.end,
    required this.text,
    this.words,
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
        words: (m['words'] as List?)
            ?.map((e) => LyricWord.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        if (words != null && words!.isNotEmpty)
          'words': [for (final w in words!) w.toJson()],
      };
}

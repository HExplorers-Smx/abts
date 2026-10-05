/// 单个章节的下载任务状态
enum DownloadStatus {
  queued, // 排队等待（未开始）
  downloading, // 下载中
  paused, // 已暂停（保留 .part 断点，可续传）
  completed, // 已完成（本地文件可用）
  failed, // 失败（可重试）
}

/// 章节下载任务：记录书籍/章节元数据、断点进度与本地文件路径。
///
/// 序列化到 SharedPreferences；下载中的真实进度由 DownloadManager 写入，
/// 进度通知节流后抛出，避免高频重建 UI。
class DownloadTask {
  final String bvid;
  final int cid;
  final int chapterIndex; // 在章节目录中的索引（0 起）
  final String part; // 章节标题
  final String bookTitle; // 书名（cleanTitle）
  final String pic; // 封面
  final String author; // UP 主
  final int durationSec; // 章节时长（秒）
  final int pages; // 全书分P数

  DownloadStatus status;
  int totalBytes; // 0 = 未知
  int receivedBytes;
  String? localPath; // 完成后的绝对路径
  int createdAt;
  int updatedAt;
  String? error;

  /// 瞬时下载速度（字节/秒），仅内存态，不持久化
  int speedBps = 0;

  DownloadTask({
    required this.bvid,
    required this.cid,
    required this.chapterIndex,
    required this.part,
    required this.bookTitle,
    required this.pic,
    required this.author,
    this.durationSec = 0,
    this.pages = 0,
    this.status = DownloadStatus.queued,
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.localPath,
    int? createdAt,
    int? updatedAt,
    this.error,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  String get key => '${bvid}_$cid';

  bool get completed => status == DownloadStatus.completed;
  bool get active =>
      status == DownloadStatus.queued || status == DownloadStatus.downloading;

  double get progress {
    if (totalBytes <= 0) return receivedBytes > 0 ? 0 : 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// 已下载/总大小文案（如 3.2 MB / 8.1 MB）
  String get sizeText {
    final recv = formatBytes(receivedBytes);
    if (totalBytes <= 0) return recv;
    return '$recv / ${formatBytes(totalBytes)}';
  }

  /// 瞬时速度文案（如 1.2 MB/s），未在下载返回空
  String get speedText => speedBps <= 0 ? '' : '${formatBytes(speedBps)}/s';

  static String formatBytes(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'cid': cid,
        'chapterIndex': chapterIndex,
        'part': part,
        'bookTitle': bookTitle,
        'pic': pic,
        'author': author,
        'durationSec': durationSec,
        'pages': pages,
        'status': status.name,
        'totalBytes': totalBytes,
        'receivedBytes': receivedBytes,
        'localPath': localPath,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> m) => DownloadTask(
        bvid: m['bvid'] as String? ?? '',
        cid: int.tryParse('${m['cid'] ?? 0}') ?? 0,
        chapterIndex: int.tryParse('${m['chapterIndex'] ?? 0}') ?? 0,
        part: m['part'] as String? ?? '',
        bookTitle: m['bookTitle'] as String? ?? '',
        pic: m['pic'] as String? ?? '',
        author: m['author'] as String? ?? '',
        durationSec: int.tryParse('${m['durationSec'] ?? 0}') ?? 0,
        pages: int.tryParse('${m['pages'] ?? 0}') ?? 0,
        status: DownloadStatus.values.asNameMap()[m['status']] ??
            DownloadStatus.paused,
        totalBytes: int.tryParse('${m['totalBytes'] ?? 0}') ?? 0,
        receivedBytes: int.tryParse('${m['receivedBytes'] ?? 0}') ?? 0,
        localPath: m['localPath'] as String?,
        createdAt: int.tryParse('${m['createdAt'] ?? 0}') ?? 0,
        updatedAt: int.tryParse('${m['updatedAt'] ?? 0}') ?? 0,
        error: m['error'] as String?,
      );

  /// 下载任务状态文案
  String get statusText => switch (status) {
        DownloadStatus.queued => '等待中',
        DownloadStatus.downloading => '下载中',
        DownloadStatus.paused => '已暂停',
        DownloadStatus.completed => '已下载',
        DownloadStatus.failed => '下载失败',
      };
}

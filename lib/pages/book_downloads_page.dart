import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../models/book.dart';
import '../models/download_task.dart';
import '../player/book_player.dart';
import '../services/download_manager.dart';
import '../services/download_store.dart';
import '../widgets/book_cover.dart';
import 'player_page.dart';

/// 我的下载 · 二级页：某一本书的章节下载管理（状态 / 播放 / 暂停 / 重试 / 删除）
class BookDownloadsPage extends StatelessWidget {
  final String bvid;
  const BookDownloadsPage({super.key, required this.bvid});

  @override
  Widget build(BuildContext context) {
    final mgr = context.watch<DownloadManager>();
    final store = mgr.store;
    final tasks = store.tasksForBook(bvid);

    return Scaffold(
      appBar: AppBar(title: const Text('章节下载')),
      body: tasks.isEmpty
          ? _buildEmpty(context)
          : _buildContent(context, mgr, store, tasks),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_outlined, size: 48, color: AppTheme.textHint),
          const SizedBox(height: 12),
          Text('本书下载任务已清空',
              style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, DownloadManager mgr,
      DownloadStore store, List<DownloadTask> tasks) {
    final first = tasks.first;
    final done = tasks.where((t) => t.completed).length;
    final bytes = tasks.fold<int>(
      0,
      (s, t) => s +
          (t.completed
              ? (t.totalBytes > 0 ? t.totalBytes : t.receivedBytes)
              : t.receivedBytes),
    );
    final hasActive = tasks.any((t) => t.active);
    final hasIdle = tasks.any((t) => !t.completed && !t.active);

    return Column(
      children: [
        _buildBookHeader(context, mgr, store, first, done, tasks.length, bytes,
            hasActive, hasIdle),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: tasks.length,
            itemBuilder: (context, i) => _ChapterTile(task: tasks[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildBookHeader(
      BuildContext context,
      DownloadManager mgr,
      DownloadStore store,
      DownloadTask first,
      int done,
      int total,
      int bytes,
      bool hasActive,
      bool hasIdle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      child: Row(
        children: [
          BookCover(url: first.pic, width: 56, height: 72),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  first.bookTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textMain,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '已下载 $done/$total 章 · ${DownloadTask.formatBytes(bytes)}',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ],
            ),
          ),
          if (hasActive)
            IconButton(
              tooltip: '暂停全部',
              onPressed: () => mgr.pauseBook(bvid),
              icon: Icon(Icons.pause_circle_outline_rounded,
                  size: 24, color: AppTheme.textSub),
            )
          else if (hasIdle)
            IconButton(
              tooltip: '继续下载',
              onPressed: () => mgr.resumeBook(bvid),
              icon: Icon(Icons.play_circle_outline_rounded,
                  size: 24, color: AppTheme.accent),
            ),
          IconButton(
            tooltip: '删除本书下载',
            onPressed: () => _confirmDeleteBook(context, mgr),
            icon: Icon(Icons.delete_outline_rounded,
                size: 22, color: AppTheme.textHint),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteBook(
      BuildContext context, DownloadManager mgr) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('删除本书下载',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text('将删除本书的所有已下载与进行中任务（含本地文件）',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (!context.mounted) return;
      await mgr.deleteBook(bvid);
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}

/// 单章任务行
class _ChapterTile extends StatelessWidget {
  final DownloadTask task;
  const _ChapterTile({required this.task});

  @override
  Widget build(BuildContext context) {
    final mgr = context.watch<DownloadManager>();
    return InkWell(
      onTap: task.completed ? () => _play(context) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${task.chapterIndex + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: task.completed
                      ? AppTheme.accent
                      : AppTheme.textSub,
                  fontWeight:
                      task.completed ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.part,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: task.completed
                          ? AppTheme.textMain
                          : AppTheme.textSub,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  _buildStatusLine(task),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _buildTrailing(context, mgr),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusLine(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.downloading:
        final speed = task.speedText;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(
              value: task.totalBytes > 0 ? task.progress : null,
              minHeight: 3,
              borderRadius: BorderRadius.circular(2),
              backgroundColor: AppTheme.surfaceHigh,
            ),
            const SizedBox(height: 3),
            Text(
              '${task.sizeText}${speed.isEmpty ? '' : ' · $speed'}',
              style: TextStyle(fontSize: 11, color: AppTheme.textHint),
            ),
          ],
        );
      case DownloadStatus.queued:
        return Text('等待中 · ${task.sizeText}',
            style: TextStyle(fontSize: 11, color: AppTheme.textHint));
      case DownloadStatus.paused:
        return Text('已暂停 · ${task.sizeText}',
            style: TextStyle(fontSize: 11, color: AppTheme.textHint));
      case DownloadStatus.failed:
        return Text(
          task.error ?? '下载失败',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: AppTheme.error),
        );
      case DownloadStatus.completed:
        return Text('已下载 · ${task.sizeText}',
            style: TextStyle(fontSize: 11, color: AppTheme.textHint));
    }
  }

  Widget _buildTrailing(BuildContext context, DownloadManager mgr) {
    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return IconButton(
          tooltip: '暂停',
          onPressed: () => mgr.pause(task.bvid, task.cid),
          icon: Icon(Icons.pause_circle_outline_rounded,
              size: 26, color: AppTheme.textSub),
        );
      case DownloadStatus.paused:
        return IconButton(
          tooltip: '继续下载',
          onPressed: () => mgr.resume(task.bvid, task.cid),
          icon: Icon(Icons.play_circle_outline_rounded,
              size: 26, color: AppTheme.accent),
        );
      case DownloadStatus.failed:
        return IconButton(
          tooltip: '重试',
          onPressed: () => mgr.resume(task.bvid, task.cid),
          icon: Icon(Icons.refresh_rounded,
              size: 24, color: AppTheme.accent),
        );
      case DownloadStatus.completed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '播放',
              onPressed: () => _play(context),
              icon: Icon(Icons.play_circle_fill_rounded,
                  size: 26, color: AppTheme.accent),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: () => _confirmDelete(context),
              icon: Icon(Icons.delete_outline_rounded,
                  size: 22, color: AppTheme.textHint),
            ),
          ],
        );
    }
  }

  Future<void> _play(BuildContext context) async {
    final player = context.read<BookPlayer>();
    final book = Book(
      bvid: task.bvid,
      aid: 0,
      title: task.bookTitle,
      pic: task.pic,
      author: task.author,
      pages: task.pages,
    );
    await player.playBook(book, resumeIndex: task.chapterIndex);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlayerPage()),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('删除下载',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text('删除「${task.part}」的本地文件？',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (!context.mounted) return;
      await context.read<DownloadManager>().delete(task.bvid, task.cid);
    }
  }
}

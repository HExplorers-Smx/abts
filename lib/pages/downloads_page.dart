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

/// 我的下载：按书分组的下载管理页（进度 / 暂停 / 续传 / 播放 / 删除）
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final mgr = context.watch<DownloadManager>();
    final store = mgr.store;
    final tasks = store.tasks;

    return Scaffold(
      appBar: AppBar(title: const Text('我的下载')),
      body: tasks.isEmpty
          ? _buildEmpty()
          : _buildContent(context, mgr, store),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_outlined, size: 56, color: AppTheme.textHint),
          const SizedBox(height: 14),
          Text(
            '还没有下载内容',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.textMain),
          ),
          const SizedBox(height: 6),
          Text(
            '在书籍详情页点击「下载」即可离线收听，省流量',
            style: TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
      BuildContext context, DownloadManager mgr, DownloadStore store) {
    final summaries = store.bookSummaries();
    final hasActive = store.tasks.any((t) => t.active);
    final hasIdle = store.tasks.any((t) => !t.completed && !t.active);
    return Column(
      children: [
        _buildSummaryBar(context, mgr, store, hasActive, hasIdle),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: summaries.length,
            itemBuilder: (context, i) {
              final s = summaries[i];
              return _BookGroup(
                summary: s,
                tasks: store.tasksForBook(s.bvid),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryBar(BuildContext context, DownloadManager mgr,
      DownloadStore store, bool hasActive, bool hasIdle) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Row(
          children: [
            Icon(Icons.sd_storage_outlined,
                size: 18, color: AppTheme.toneDownload),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已下载 ${store.doneCount} 章 · 占用 ${DownloadTask.formatBytes(store.totalBytes)}',
                style:
                    TextStyle(fontSize: 13, color: AppTheme.textMain),
              ),
            ),
            if (hasActive)
              TextButton(
                onPressed: mgr.pauseAll,
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSub,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('全部暂停', style: TextStyle(fontSize: 12)),
              )
            else if (hasIdle)
              TextButton(
                onPressed: mgr.resumeAll,
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('全部开始', style: TextStyle(fontSize: 12)),
              ),
            if (store.doneCount > 0)
              TextButton(
                onPressed: () => _confirmClearCompleted(context, mgr),
                style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSub,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('清空已完成', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearCompleted(
      BuildContext context, DownloadManager mgr) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('清空已完成',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text('将删除所有已下载的章节文件（保留未完成的任务）',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok == true) await mgr.deleteCompleted();
  }
}

/// 一本书的下载分组：书头（封面/书名/进度）+ 章节任务列表
class _BookGroup extends StatelessWidget {
  final DownloadBookSummary summary;
  final List<DownloadTask> tasks;

  const _BookGroup({required this.summary, required this.tasks});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              BookCover(url: summary.pic, width: 40, height: 52),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMain,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${summary.done}/${summary.total} 章 · ${DownloadTask.formatBytes(summary.bytes)}',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSub),
                    ),
                  ],
                ),
              ),
              if (summary.allDone)
                Icon(Icons.download_done_rounded,
                    size: 20, color: AppTheme.accent)
              else if (summary.downloading > 0)
                Text(
                  '${summary.downloading} 个任务',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.accent),
                ),
              IconButton(
                tooltip: '删除本书下载',
                onPressed: () => _confirmDeleteBook(context),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 20, color: AppTheme.textHint),
              ),
            ],
          ),
        ),
        ...tasks.map((t) => _TaskTile(task: t)),
      ],
    );
  }

  Future<void> _confirmDeleteBook(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('删除本书下载',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text('将删除《${summary.title}》的所有已下载与进行中的任务（含本地文件）',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textSub)),
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
      await context.read<DownloadManager>().deleteBook(summary.bvid);
    }
  }
}

/// 单章任务行
class _TaskTile extends StatelessWidget {
  final DownloadTask task;
  const _TaskTile({required this.task});

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
                  fontWeight: task.completed
                      ? FontWeight.w700
                      : FontWeight.w400,
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
            child:
                Text('取消', style: TextStyle(color: AppTheme.textSub)),
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

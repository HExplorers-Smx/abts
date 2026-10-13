import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../models/download_task.dart';
import '../services/download_manager.dart';
import '../services/download_store.dart';
import '../widgets/book_cover.dart';
import 'book_downloads_page.dart';

/// 我的下载 · 一级页：按书分组的下载列表（点书名进入该书的章节管理页）
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
        if (mgr.wifiOnly && mgr.wifiBlocked > 0)
          _buildWifiBlockedBar(context, mgr, store),
        _buildSummaryBar(context, mgr, store, hasActive, hasIdle),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: summaries.length,
            itemBuilder: (context, i) {
              final s = summaries[i];
              return _BookTile(summary: s);
            },
          ),
        ),
      ],
    );
  }

  /// 「仅 Wi-Fi」模式下被拦下的任务提示条：可一键临时放行
  Widget _buildWifiBlockedBar(
      BuildContext context, DownloadManager mgr, DownloadStore store) {
    final n = mgr.wifiBlocked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.accentSoft.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_off_rounded, size: 18, color: AppTheme.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                n > 1 ? '$n 个下载任务正等待 Wi-Fi' : '1 个下载任务正等待 Wi-Fi',
                style: TextStyle(fontSize: 12, color: AppTheme.textMain),
              ),
            ),
            TextButton(
              onPressed: () => mgr.setWifiOnly(false),
              style: TextButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('用流量继续', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
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

/// 一本书的下载入口行：点击进入该书章节管理（二级页）
class _BookTile extends StatelessWidget {
  final DownloadBookSummary summary;

  const _BookTile({required this.summary});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BookDownloadsPage(bvid: summary.bvid),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            BookCover(url: summary.pic, width: 44, height: 58),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMain,
                    ),
                  ),
                  const SizedBox(height: 4),
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
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppTheme.textHint),
          ],
        ),
      ),
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

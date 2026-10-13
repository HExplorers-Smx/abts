import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../player/book_player.dart';
import '../services/bookmark_store.dart';
import 'player_page.dart';

/// 书签列表：点击跳转收听位置，长按/滑动删除
class BookmarksPage extends StatelessWidget {
  const BookmarksPage({super.key});

  Future<void> _play(BuildContext context, Bookmark bm) async {
    final shelf = context.read<ShelfStore>();
    final messenger = ScaffoldMessenger.of(context);
    final player = context.read<BookPlayer>();
    final sb = shelf.byBvid(bm.bvid);
    if (sb == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('这本书已不在书架，无法跳转')),
      );
      return;
    }
    player.flushProgress();
    await player.playBook(
      sb.book,
      resumeIndex: bm.chapterIndex,
      resumeMs: bm.positionMs,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlayerPage()),
    );
  }

  Future<void> _remove(BuildContext context, Bookmark bm) async {
    await context.read<BookmarkStore>().remove(bm.createdAt);
  }

  String _dateText(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = d.year == now.year &&
        d.month == now.month &&
        d.day == now.day;
    if (sameDay) return '今天';
    final yesterday = now.subtract(const Duration(days: 1));
    if (d.year == yesterday.year &&
        d.month == yesterday.month &&
        d.day == yesterday.day) {
      return '昨天';
    }
    return '${d.month}月${d.day}日';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<BookmarkStore>();
    final items = store.items;
    return Scaffold(
      appBar: AppBar(title: const Text('书签')),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark_border_rounded,
                      size: 64, color: AppTheme.textHint),
                  const SizedBox(height: 14),
                  Text(
                    '还没有书签',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSub,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '播放页点「书签」保存当前位置，随时回来',
                    style: TextStyle(fontSize: 12, color: AppTheme.textHint),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, _) => Divider(
                height: 16,
                thickness: 0.5,
                color: AppTheme.divider,
              ),
              itemBuilder: (context, i) {
                final bm = items[i];
                return InkWell(
                  onTap: () => _play(context, bm),
                  onLongPress: () => _remove(context, bm),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceHigh,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.bookmark_rounded,
                              size: 20, color: AppTheme.accent),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                bm.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textMain,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                bm.note.isNotEmpty
                                    ? '${bm.chapterTitle} · ${bm.positionText} · ${bm.note}'
                                    : '${bm.chapterTitle} · ${bm.positionText}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: AppTheme.textSub),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _dateText(bm.createdAt),
                          style:
                              TextStyle(fontSize: 11, color: AppTheme.textHint),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

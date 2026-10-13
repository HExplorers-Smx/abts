import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../services/local_library.dart';
import '../widgets/book_cards.dart';
import '../widgets/shelf_common.dart';

/// 书架：收藏的书籍 + 续读进度 + 本地导入
class BookshelfPage extends StatelessWidget {
  const BookshelfPage({super.key});

  String _sizeText(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// 选择本地音频文件 → 确认 → 复制进应用目录 → 加入书架
  Future<void> _pickAndImport(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final shelf = context.read<ShelfStore>();

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: LocalLibrary.supportedExtensions,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    final files = result.files.where((f) => f.path != null).toList();
    if (files.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('未能读取所选文件')));
      return;
    }
    if (!context.mounted) return;

    var importing = false;
    var progressText = '';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> doImport() async {
            if (importing) return;
            setDialogState(() {
              importing = true;
              progressText = '正在复制 0/${files.length} …';
            });
            var done = 0;
            final failed = <String>[];
            for (final f in files) {
              try {
                final book =
                    await LocalLibrary.instance.importFile(f.path!);
                if (book == null) {
                  failed.add(f.name);
                } else {
                  await shelf.add(book);
                  done++;
                }
              } catch (e) {
                failed.add(f.name);
              }
              if (!context.mounted) return;
              setDialogState(() {
                progressText = '正在复制 $done/${files.length} …';
              });
            }
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (!context.mounted) return;
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  failed.isEmpty
                      ? '已导入 $done 本，可在书架收听'
                      : '导入 $done 本，${failed.length} 个失败：'
                          '${failed.take(3).join('、')}${failed.length > 3 ? ' 等' : ''}',
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: AppTheme.surface,
            title: Text(
              importing ? '正在导入…' : '导入本地音频',
              style: TextStyle(color: AppTheme.textMain, fontSize: 17),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: importing
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          progressText,
                          style: TextStyle(color: AppTheme.textSub),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '复制完成后可直接离线收听，无需网络',
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textHint),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '共 ${files.length} 个音频文件，将复制到应用内：',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSub),
                        ),
                        const SizedBox(height: 8),
                        Flexible(
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: files.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, i) {
                              final f = files[i];
                              return Row(
                                children: [
                                  Icon(Icons.audio_file_rounded,
                                      size: 18, color: AppTheme.textHint),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      f.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.textMain),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _sizeText(f.size),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textHint),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
            ),
            actions: importing
                ? null
                : [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: Text('取消',
                          style: TextStyle(color: AppTheme.textSub)),
                    ),
                    FilledButton(
                      onPressed: doImport,
                      child: const Text('开始导入'),
                    ),
                  ],
          );
        },
      ),
    );
  }

  /// 打开一本书：本地书直达播放页，在线书进详情页
  void _openBook(BuildContext context, ShelfBook sb) {
    openShelfBook(context, sb);
  }

  @override
  Widget build(BuildContext context) {
    final shelf = context.watch<ShelfStore>();
    final books = shelf.books;

    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          IconButton(
            tooltip: '导入本地音频',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () => _pickAndImport(context),
          ),
          if (books.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${books.length} 本',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: books.isEmpty
          ? Column(
              children: [
                const Expanded(
                  child: EmptyShelfView(
                    title: '书架还是空的',
                    subtitle: '去「发现」搜索在线有声书，或导入本地音频文件',
                    icon: Icons.library_books_outlined,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: FilledButton.tonalIcon(
                    onPressed: () => _pickAndImport(context),
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: const Text('导入本地音频'),
                  ),
                ),
              ],
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 0.52,
              ),
              itemCount: books.length,
              itemBuilder: (context, i) {
                final sb = books[i];
                return BookGridItem(
                  book: sb.book,
                  isLocal: sb.book.localPath != null,
                  badge: sb.positionMs > 0
                      ? ShelfProgressBadge(percent: sb.percent)
                      : null,
                  onTap: () => _openBook(context, sb),
                  onLongPress: () => confirmRemoveFromShelf(context, sb),
                );
              },
            ),
    );
  }
}

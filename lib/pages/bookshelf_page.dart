import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../services/local_library.dart';
import '../widgets/book_cards.dart';
import '../widgets/shelf_common.dart';
import 'local_book_detail_page.dart';

/// 书架：收藏的书籍 + 续读进度 + 本地导入
/// - 末尾「＋」新建本地书：弹窗设置书名/封面/作者 → 导入音频章节；
/// - 长按一本书进入多选模式，可批量删除（本地书连带删除应用内文件）。
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  /// 多选（批量删除）模式
  bool _selectMode = false;
  final Set<String> _selected = {};

  /// 书架筛选：0 全部 / 1 收听中 / 2 本地
  int _filter = 0;

  void _toggleSelect(String bvid) {
    setState(() {
      _selectMode = true;
      if (!_selected.add(bvid)) _selected.remove(bvid);
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  /// 新建本地书：元数据弹窗（书名/封面/作者/简介）→ 选择音频 → 复制入库
  Future<void> _createLocalBook(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final shelf = context.read<ShelfStore>();

    // ---------- 第一步：设置书名 / 封面 / 作者 / 简介 ----------
    final titleCtrl = TextEditingController();
    final authorCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String? coverPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> pickCover() async {
            final r = await FilePicker.platform.pickFiles(
              type: FileType.image,
              allowMultiple: false,
            );
            final p = (r != null && r.files.isNotEmpty)
                ? r.files.first.path
                : null;
            if (p != null) setDialogState(() => coverPath = p);
          }

          return AlertDialog(
            backgroundColor: AppTheme.surface,
            title: Text(
              '新建本地书',
              style: TextStyle(color: AppTheme.textMain, fontSize: 17),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    onTap: pickCover,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: coverPath == null
                          ? Container(
                              height: 132,
                              color: AppTheme.surfaceHigh,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      size: 30, color: AppTheme.textHint),
                                  const SizedBox(height: 6),
                                  Text(
                                    '选择封面图片（可选）',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textHint),
                                  ),
                                ],
                              ),
                            )
                          : Image.file(
                              File(coverPath!),
                              height: 132,
                              width: double.infinity,
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: titleCtrl,
                    autofocus: true,
                    style: TextStyle(color: AppTheme.textMain),
                    decoration: InputDecoration(
                      labelText: '书名（必填）',
                      hintText: '例如：三体 · 广播剧',
                      labelStyle:
                          TextStyle(fontSize: 13, color: AppTheme.textSub),
                      hintStyle:
                          TextStyle(fontSize: 13, color: AppTheme.textHint),
                      enabledBorder: UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppTheme.divider, width: 1),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppTheme.accent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: authorCtrl,
                    style: TextStyle(color: AppTheme.textMain),
                    decoration: InputDecoration(
                      labelText: '作者（可选）',
                      labelStyle:
                          TextStyle(fontSize: 13, color: AppTheme.textSub),
                      enabledBorder: UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppTheme.divider, width: 1),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppTheme.accent, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descCtrl,
                    style: TextStyle(color: AppTheme.textMain),
                    decoration: InputDecoration(
                      labelText: '简介（可选）',
                      labelStyle:
                          TextStyle(fontSize: 13, color: AppTheme.textSub),
                      enabledBorder: UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppTheme.divider, width: 1),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide:
                            BorderSide(color: AppTheme.accent, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('确认'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || titleCtrl.text.trim().isEmpty) {
      if (ok == true) {
        messenger.showSnackBar(const SnackBar(content: Text('请填写书名')));
      }
      titleCtrl.dispose();
      authorCtrl.dispose();
      descCtrl.dispose();
      return;
    }
    final title = titleCtrl.text.trim();
    final author = authorCtrl.text.trim();
    final desc = descCtrl.text.trim();
    titleCtrl.dispose();
    authorCtrl.dispose();
    descCtrl.dispose();
    if (!context.mounted) return;

    // ---------- 第二步：创建本地书，进入二级界面导入音频 ----------
    final created = await LocalLibrary.instance.createBook(
      title: title,
      author: author,
      desc: desc,
      coverPath: coverPath,
    );
    await shelf.add(created);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocalBookDetailPage(book: created),
      ),
    );
    messenger.showSnackBar(
      SnackBar(content: Text('《$title》已创建，去导入音频吧')),
    );
  }

  /// 批量删除选中书籍（本地书连带删除应用内文件）
  Future<void> _deleteSelected(BuildContext context) async {
    final shelf = context.read<ShelfStore>();
    final messenger = ScaffoldMessenger.of(context);
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title:
            Text('删除 $n 本', style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text(
          '确定删除选中的 $n 本书吗？\n本地导入的书其文件也会一并删除。',
          style: TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final bvid in _selected.toList()) {
      final sb = shelf.byBvid(bvid);
      if (sb != null) {
        await LocalLibrary.instance.deleteLocalBook(sb.book);
        await shelf.remove(bvid);
      }
    }
    _exitSelect();
    messenger.showSnackBar(SnackBar(content: Text('已删除 $n 本')));
  }

  @override
  Widget build(BuildContext context) {
    final shelf = context.watch<ShelfStore>();
    final all = shelf.books;
    final books = switch (_filter) {
      1 => all.where((b) => b.positionMs > 0).toList(),
      2 => all
          .where((b) =>
              b.book.localPath != null || b.book.localDir != null)
          .toList(),
      _ => all,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '已选 ${_selected.length} 本' : '书架'),
        actions: _selectMode
            ? [
                TextButton(
                  onPressed:
                      _selected.isEmpty ? null : () => _deleteSelected(context),
                  child: Text(
                    '删除',
                    style: TextStyle(
                      fontSize: 14,
                      color: _selected.isEmpty
                          ? AppTheme.textHint
                          : AppTheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _exitSelect,
                  child: Text('取消',
                      style:
                          TextStyle(fontSize: 14, color: AppTheme.textSub)),
                ),
              ]
            : [
                if (books.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      child: Text(
                        '${books.length} 本',
                        style:
                            TextStyle(color: AppTheme.textSub, fontSize: 13),
                      ),
                    ),
                  ),
              ],
      ),
      body: Column(
        children: [
          if (all.isNotEmpty) _buildFilterBar(),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 0.52,
              ),
              // 空书架时 i==books.length==0，「+」自然落在第一个位置；
              // 有书时「+」跟在最后一本书后面
              itemCount: books.length + 1,
              itemBuilder: (context, i) {
                if (i == books.length) {
                  return _AddBookTile(
                    onTap: _selectMode
                        ? _exitSelect
                        : () => _createLocalBook(context),
                  );
                }
                final sb = books[i];
                final selected = _selected.contains(sb.book.bvid);
                final tile = BookGridItem(
                  book: sb.book,
                  isLocal:
                      sb.book.localPath != null || sb.book.localDir != null,
                  badge: sb.positionMs > 0
                      ? ShelfProgressBadge(percent: sb.percent)
                      : null,
                  onTap: () {
                    if (_selectMode) {
                      _toggleSelect(sb.book.bvid);
                    } else {
                      openShelfBook(context, sb);
                    }
                  },
                  onLongPress: () => _toggleSelect(sb.book.bvid),
                );
                if (!_selectMode) return tile;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? AppTheme.accent : AppTheme.divider,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      tile,
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color:
                              selected ? AppTheme.accent : AppTheme.textHint,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 书架筛选栏：全部 / 收听中 / 本地
  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        children: [
          for (final (label, v) in const [
            ('全部', 0),
            ('收听中', 1),
            ('本地', 2),
          ]) ...[
            ChoiceChip(
              label: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: v == _filter ? AppTheme.accent : AppTheme.textSub,
                  fontWeight:
                      v == _filter ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              selected: _filter == v,
              selectedColor: AppTheme.accent.withValues(alpha: 0.12),
              showCheckmark: false,
              backgroundColor: AppTheme.surfaceHigh,
              side: BorderSide(
                color: v == _filter ? AppTheme.accent : AppTheme.divider,
              ),
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() => _filter = v),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// 书架末尾「＋」卡片：新建本地书
class _AddBookTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddBookTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.divider, width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, size: 42, color: AppTheme.accent),
            const SizedBox(height: 10),
            Text(
              '新建本地书',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textMain),
            ),
            const SizedBox(height: 4),
            Text(
              '书名 / 封面 / 音频',
              style: TextStyle(fontSize: 11, color: AppTheme.textHint),
            ),
          ],
        ),
      ),
    );
  }
}

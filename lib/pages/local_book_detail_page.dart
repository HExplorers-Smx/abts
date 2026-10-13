import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../models/book.dart';
import '../player/book_player.dart';
import '../services/local_library.dart';
import '../widgets/book_cover.dart';
import 'player_page.dart';

/// 本地书二级界面：像文件夹一样管理一本书。
/// - 头部展示封面/书名/作者/简介，可编辑元信息；
/// - 「导入音频」往书里追加章节（可多选、可反复导入）；
/// - 章节列表点击播放、长按删除该章。
class LocalBookDetailPage extends StatefulWidget {
  final Book book;
  const LocalBookDetailPage({super.key, required this.book});

  @override
  State<LocalBookDetailPage> createState() => _LocalBookDetailPageState();
}

class _LocalBookDetailPageState extends State<LocalBookDetailPage> {
  late Book _book = widget.book;
  final List<TextEditingController> _metaCtrls = [];

  @override
  void dispose() {
    for (final c in _metaCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _persist() async {
    await context.read<ShelfStore>().add(_book);
  }

  /// 追加音频章节
  Future<void> _addAudio() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: LocalLibrary.supportedExtensions,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    final paths = result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('未能读取所选音频')));
      return;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '正在导入 ${paths.length} 个音频…',
              style: TextStyle(color: AppTheme.textSub, fontSize: 13),
            ),
          ],
        ),
      ),
    );
    final updated = await LocalLibrary.instance.addAudioFiles(_book, paths);
    if (mounted) {
      setState(() => _book = updated);
      await _persist();
      if (mounted) Navigator.of(context).pop(); // 关闭进度
      messenger.showSnackBar(
        SnackBar(
          content: Text('已导入 ${updated.chapters!.length - widget.book.chapters!.length} 个音频'),
        ),
      );
    }
  }

  /// 编辑元信息（书名/封面/作者/简介），预填当前值
  Future<void> _editMeta() async {
    final titleCtrl = TextEditingController(text: _book.title);
    final authorCtrl = TextEditingController(text: _book.author);
    final descCtrl = TextEditingController(text: _book.desc);
    _metaCtrls
      ..clear()
      ..addAll([titleCtrl, authorCtrl, descCtrl]);
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
              '编辑本地书',
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
                      child: coverPath != null
                          ? Image.file(
                              File(coverPath!),
                              height: 132,
                              width: double.infinity,
                              fit: BoxFit.cover,
                            )
                          : Container(
                              height: 132,
                              color: AppTheme.surfaceHigh,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      size: 30, color: AppTheme.textHint),
                                  const SizedBox(height: 6),
                                  Text(
                                    '更换封面图片（可选）',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textHint),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _metaField(titleCtrl, '书名（必填）'),
                  const SizedBox(height: 12),
                  _metaField(authorCtrl, '作者（可选）'),
                  const SizedBox(height: 12),
                  _metaField(descCtrl, '简介（可选）'),
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
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final updated = await LocalLibrary.instance.updateBookMeta(
      _book,
      title: titleCtrl.text,
      author: authorCtrl.text,
      desc: descCtrl.text,
      coverPath: coverPath,
    );
    if (!mounted) return;
    setState(() => _book = updated);
    await _persist();
  }

  Widget _metaField(TextEditingController c, String label) {
    return TextField(
      controller: c,
      style: TextStyle(color: AppTheme.textMain),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 13, color: AppTheme.textSub),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: AppTheme.divider, width: 1),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: AppTheme.accent, width: 1.5),
        ),
      ),
    );
  }

  /// 播放指定章节
  Future<void> _play(int index) async {
    final player = context.read<BookPlayer>();
    player.flushProgress();
    await player.playBook(_book, resumeIndex: index);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlayerPage()),
    );
  }

  /// 删除一章（含文件）
  Future<void> _removeChapter(int index) async {
    final ch = _book.chapters![index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('删除该章',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text(
          '确定删除《${ch.part}》吗？\n本地音频文件也会一并删除。',
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
    final updated = await LocalLibrary.instance.removeChapter(_book, index);
    if (!mounted) return;
    setState(() => _book = updated);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _book.chapters ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: Text(_book.cleanTitle),
        actions: [
          IconButton(
            tooltip: '编辑信息',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _editMeta(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ---------- 头部 ----------
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BookCover(
                url: _book.pic,
                width: 110,
                height: 150,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _book.cleanTitle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMain,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.person_outline,
                            size: 14, color: AppTheme.textSub),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.textSub),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.library_music_outlined,
                            size: 14, color: AppTheme.textSub),
                        const SizedBox(width: 4),
                        Text(
                          '${chapters.length} 个音频',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSub),
                        ),
                      ],
                    ),
                    if (_book.desc.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _book.desc,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textHint,
                            height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: chapters.isEmpty ? null : () => _play(0),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: Text(chapters.isEmpty ? '还没有音频' : '播放'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addAudio,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('导入音频'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text(
                '章节',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMain,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '长按章节可删除',
                style: TextStyle(fontSize: 11, color: AppTheme.textHint),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (chapters.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 28),
              alignment: Alignment.center,
              child: Column(
                children: [
                  Icon(Icons.queue_music_rounded,
                      size: 44, color: AppTheme.textHint),
                  const SizedBox(height: 10),
                  Text(
                    '还没有音频，点「导入音频」添加',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSub),
                  ),
                ],
              ),
            )
          else
            ...List.generate(chapters.length, (i) {
              final ch = chapters[i];
              return InkWell(
                onTap: () => _play(i),
                onLongPress: () => _removeChapter(i),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSub,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          ch.part,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.textMain,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.play_circle_outline,
                          size: 20, color: AppTheme.textHint),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

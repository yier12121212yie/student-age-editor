import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// Steam 创意工坊一键发布对话框
class WorkshopPublishDialog extends StatefulWidget {
  const WorkshopPublishDialog({
    super.key,
    required this.modName,
    required this.initialTitle,
    required this.initialDesc,
  });

  final String modName;
  final String initialTitle;
  final String initialDesc;

  static Future<void> show(
    BuildContext context, {
    required String modName,
    required String initialTitle,
    required String initialDesc,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => WorkshopPublishDialog(
        modName: modName,
        initialTitle: initialTitle,
        initialDesc: initialDesc,
      ),
    );
  }

  @override
  State<WorkshopPublishDialog> createState() => _WorkshopPublishDialogState();
}

class _WorkshopPublishDialogState extends State<WorkshopPublishDialog> {
  late TextEditingController _titleCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _changeNoteCtrl;

  String _visibility = 'public';
  final Set<String> _selectedTags = {'剧情'};
  String? _publishedFileId;

  bool _loadingStatus = true;
  bool _ready = false;

  bool _publishing = false;
  int _progress = 0;
  String _stage = 'idle';
  String _stageLabel = '';
  String? _error;
  String? _itemUrl;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle.isNotEmpty ? widget.initialTitle : widget.modName);
    _descCtrl = TextEditingController(text: widget.initialDesc);
    _changeNoteCtrl = TextEditingController(text: 'Initial release');
    _checkStatus();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _changeNoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    try {
      final res = await ApiClient.instance.get('/api/workshop/status');
      if (mounted) {
        setState(() {
          _ready = res['ready'] == true;
          _loadingStatus = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _ready = true;
          _loadingStatus = false;
        });
      }
    }
  }

  Future<void> _startPublish() async {
    if (!_ready) {
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => const fluent.InfoBar(
          title: Text('提示'),
          content: Text('Steam 创意工坊未就绪，暂时无法发布'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }
    if (_titleCtrl.text.trim().isEmpty) {
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => const fluent.InfoBar(
          title: Text('提示'),
          content: Text('请输入模组标题'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }

    setState(() {
      _publishing = true;
      _progress = 0;
      _stage = 'starting';
      _stageLabel = '准备启动发布...';
      _error = null;
      _itemUrl = null;
    });

    try {
      await ApiClient.instance.post('/api/workshop/publish', body: {
        'mod_name': widget.modName,
        'title': _titleCtrl.text.trim(),
        'desc': _descCtrl.text.trim(),
        'visibility': _visibility,
        'tags': _selectedTags.toList(),
        'change_note': _changeNoteCtrl.text.trim(),
        if (_publishedFileId != null) 'publishedfileid': _publishedFileId,
      });

      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) => _pollProgress());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pollProgress() async {
    try {
      final res = await ApiClient.instance.get('/api/workshop/publish-progress');
      if (!mounted) return;

      final progress = res['progress'] as int? ?? 0;
      final stage = res['stage'] as String? ?? '';
      final label = res['stage_label'] as String? ?? '';
      final err = res['error'] as String?;
      final pubId = res['publishedfileid'] as String?;
      final url = res['url'] as String?;

      setState(() {
        _progress = progress;
        _stage = stage;
        _stageLabel = label;
        if (err != null && err.isNotEmpty) _error = err;
        if (pubId != null && pubId.isNotEmpty) _publishedFileId = pubId;
        if (url != null && url.isNotEmpty) _itemUrl = url;
      });

      if (stage == 'completed' || stage == 'failed' || (err != null && err.isNotEmpty)) {
        _pollTimer?.cancel();
        setState(() => _publishing = false);
      }
    } catch (_) {}
  }

  Future<void> _cancelPublish() async {
    try {
      await ApiClient.instance.post('/api/workshop/publish-cancel');
    } catch (_) {}
    _pollTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _publishing = false;
      _stageLabel = '已取消';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 580,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部标题
            Row(
              children: [
                Icon(FluentIcons.cloud_sync_24_regular, color: accentColor, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '发布到 Steam 创意工坊',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        '模组：${widget.modName}',
                        style: TextStyle(fontSize: 12, color: palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (!_publishing)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(color: palette.border, height: 1),
            const SizedBox(height: 16),

            if (_loadingStatus)
              const Center(child: CircularProgressIndicator())
            else if (_stage == 'completed') ...[
              // 发布成功视图
              Center(
                child: Column(
                  children: [
                    const Icon(Icons.check_circle_outline, color: Colors.green, size: 56),
                    const SizedBox(height: 12),
                    Text(
                      '发布成功！',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '创意工坊物品 ID: $_publishedFileId',
                      style: TextStyle(fontSize: 13, color: palette.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    if (_itemUrl != null) ...[
                      SelectableText(
                        _itemUrl!,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.blue),
                      ),
                      const SizedBox(height: 8),
                      fluent.FilledButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _itemUrl!));
                          fluent.displayInfoBar(
                            context,
                            builder: (ctx, close) => const fluent.InfoBar(
                              title: Text('复制成功'),
                              content: Text('已复制工坊页面链接'),
                              severity: fluent.InfoBarSeverity.success,
                            ),
                          );
                        },
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.copy_24_regular, size: 16),
                            SizedBox(width: 8),
                            Text('复制 Steam 创意工坊链接'),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    fluent.Button(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('完成并关闭'),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // 发布表单与进度展示
              if (_publishing) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: palette.bg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _stageLabel.isNotEmpty ? _stageLabel : '正在发布中...',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: palette.textPrimary,
                            ),
                          ),
                          Text(
                            '$_progress%',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: _progress / 100.0,
                        backgroundColor: palette.border,
                        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          fluent.Button(
                            onPressed: _cancelPublish,
                            child: const Text('取消发布'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(fontSize: 12, color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 输入项
              Text('模组标题', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _titleCtrl,
                enabled: !_publishing,
                decoration: InputDecoration(
                  hintText: '输入工坊中展示的标题',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
              const SizedBox(height: 12),

              Text('简介与说明', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: _descCtrl,
                maxLines: 3,
                enabled: !_publishing,
                decoration: InputDecoration(
                  hintText: '介绍该模组的故事背景、玩法与作者信息...',
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
              const SizedBox(height: 12),

              // 可见性与更新日志
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('可见性', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          value: _visibility,
                          isDense: true,
                          isExpanded: true,
                          decoration: InputDecoration(
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'public', child: Text('公开 (Public)')),
                            DropdownMenuItem(value: 'friends', child: Text('仅好友 (Friends Only)')),
                            DropdownMenuItem(value: 'private', child: Text('私密 (Private)')),
                          ],
                          onChanged: _publishing ? null : (v) => setState(() => _visibility = v ?? 'public'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('更新日志 (Change Note)', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _changeNoteCtrl,
                          enabled: !_publishing,
                          decoration: InputDecoration(
                            hintText: '本次更新说明',
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 工坊标签
              Row(
                children: [
                  Text('标签：', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
                  const SizedBox(width: 8),
                  Wrap(
                    spacing: 8,
                    children: ['剧情', '其他'].map((tag) {
                      final isSel = _selectedTags.contains(tag);
                      return ChoiceChip(
                        label: Text(tag),
                        selected: isSel,
                        onSelected: _publishing ? null : (sel) {
                          setState(() {
                            if (sel) {
                              _selectedTags.add(tag);
                            } else {
                              if (_selectedTags.length > 1) _selectedTags.remove(tag);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              // 工坊未就绪（Steam 客户端缺失/未登录）时给出前置提示，
              // 并禁用发布按钮，避免点了没反应的死路。
              if (!_ready) ...[
                Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Steam 创意工坊未就绪（未检测到 Steam 客户端或未登录），暂时无法发布。',
                        style: TextStyle(fontSize: 11, color: palette.textSecondary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              // 底部操作
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  fluent.Button(
                    onPressed: _publishing ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  fluent.FilledButton(
                    onPressed: (_publishing || !_ready) ? null : _startPublish,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.arrow_upload_24_regular, size: 16),
                        SizedBox(width: 6),
                        Text('一键同步发布'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

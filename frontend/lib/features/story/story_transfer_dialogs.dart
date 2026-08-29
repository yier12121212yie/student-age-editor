import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/app_theme.dart';

/// 弹窗内容安全尺寸：宽度不超屏，高度留出标题/操作按钮的空间。
BoxConstraints _dialogBodyConstraints(BuildContext context, double w, double h) {
  final size = MediaQuery.sizeOf(context);
  return BoxConstraints(
    maxWidth: math.min(w, size.width - 48),
    maxHeight: math.min(h, size.height * 0.78),
  );
}

/// 故事导入对话框：剧本文本 → TalkCfg（复用后端 ScriptParser）。
Future<void> showStoryImportDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => fluent.ContentDialog(
      title: const Text('📥 导入剧情剧本（文本 → TalkCfg）'),
      content: const _StoryImportBody(),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _StoryImportBody extends StatefulWidget {
  const _StoryImportBody();
  @override
  State<_StoryImportBody> createState() => _StoryImportBodyState();
}

class _StoryImportBodyState extends State<_StoryImportBody> {
  final TextEditingController _startId = TextEditingController(text: '10001');
  final TextEditingController _script = TextEditingController();
  String? _info;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _startId.dispose();
    _script.dispose();
    super.dispose();
  }

  Future<void> _run(bool write) async {
    setState(() {
      _busy = true;
      _info = null;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.post(
        '/api/story/import',
        body: {
          'start_id': _startId.text.trim(),
          'text': _script.text,
          'write': write,
        },
      );
      if (!mounted) return;
      final count = (r as Map)['count'] as int? ?? 0;
      final preview = (r['preview'] as List? ?? [])
          .take(8)
          .map((e) {
            final pair = e as List;
            final rec = pair[1] as Map;
            return '${pair[0]}  roleIds=${rec['roleIds']}  ${rec['content']}';
          })
          .join('\n');
      setState(() {
        _info = write ? '✅ 已写入 $count 条对白' : '解析出 $count 条对白（预览）：\n$preview';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: _dialogBodyConstraints(context, 620, 620),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '事件 ID（纯数字，对话 ID 自动从 <事件ID>001 开始）',
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
            const SizedBox(height: 6),
            fluent.TextBox(controller: _startId),
            const SizedBox(height: 12),
            Text(
              '剧本文本（格式：角色名：台词，支持（表情）[动作] 等标注）',
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 220,
              child: fluent.TextBox(
                controller: _script,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                placeholder: '李华：今天天气真好（开心）\n小明：是啊！我们去打球吧。',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                fluent.Button(
                  onPressed: _busy ? null : () => _run(false),
                  child: const Text('解析预览'),
                ),
                const SizedBox(width: 8),
                fluent.FilledButton(
                  onPressed: _busy ? null : () => _run(true),
                  child: Text(_busy ? '处理中…' : '写入 Mod'),
                ),
              ],
            ),
            if (_info != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _info!,
                  style: TextStyle(fontSize: 12, color: palette.statusOk),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: palette.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 故事导出对话框：选中事件 → 剧本文本（可复制）。
Future<void> showStoryExportDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => fluent.ContentDialog(
      title: const Text('📤 导出剧情文案脚本'),
      content: const _StoryExportBody(),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _StoryExportBody extends StatefulWidget {
  const _StoryExportBody();
  @override
  State<_StoryExportBody> createState() => _StoryExportBodyState();
}

class _StoryExportBodyState extends State<_StoryExportBody> {
  List<Map<String, dynamic>> _events = [];
  String? _loadError;
  final Set<String> _selected = {};
  final TextEditingController _query = TextEditingController();
  final Map<String, bool> _opts = {
    'pure': false,
    'show_id': true,
    'show_type': true,
    'show_cond': true,
    'show_expr': true,
    'show_action': true,
    'show_bg': true,
    'show_audio': true,
    'show_minigame': true,
    'show_effect': true,
  };
  String? _result;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadEvents() async {
    try {
      final r = await ApiClient.instance.get('/api/cfg/EvtCfg');
      final data = (r as Map)['data'] as Map? ?? {};
      final list = <Map<String, dynamic>>[];
      data.forEach((id, v) {
        if (v is Map) {
          list.add({'id': id, 'title': v['title'] ?? '未命名'});
        }
      });
      list.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      if (!mounted) return;
      setState(() => _events = list);
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  Future<void> _doExport() async {
    if (_selected.isEmpty) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final r = await ApiClient.instance.post(
        '/api/story/export',
        body: {'evt_ids': _selected.toList(), 'opts': _opts},
      );
      if (!mounted) return;
      setState(() => _result = (r as Map)['text'] as String? ?? '');
    } catch (e) {
      if (mounted) setState(() => _result = '导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _events
        .where((e) => (e['title'] as String).contains(_query.text.trim()))
        .toList();
    return ConstrainedBox(
      constraints: _dialogBodyConstraints(context, 720, 700),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadError != null) ...[
              Text(
                _loadError!,
                style: TextStyle(fontSize: 12, color: palette.danger),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              runSpacing: 6,
              children: [
                Text(
                  '选项：',
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
                const SizedBox(width: 8),
                _optChip('纯剧情', 'pure'),
                _optChip('ID', 'show_id'),
                _optChip('类型', 'show_type'),
                _optChip('条件', 'show_cond'),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              runSpacing: 6,
              children: [
                const SizedBox(width: 40),
                _optChip('表情', 'show_expr'),
                _optChip('动作', 'show_action'),
                _optChip('背景', 'show_bg'),
                _optChip('音效', 'show_audio'),
                _optChip('小游戏', 'show_minigame'),
                _optChip('效果', 'show_effect'),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '输入事件 ID 或标题关键词，过滤下方可选事件列表',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ),
            const SizedBox(height: 4),
            fluent.TextBox(
              controller: _query,
              placeholder: '筛选事件…',
              onChanged: (_) => setState(() {}),
              suffix: const Icon(FluentIcons.search_24_regular, size: 14),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 180,
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (ctx, i) {
                  final evt = visible[i];
                  final id = evt['id'] as String;
                  final checked = _selected.contains(id);
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => setState(() {
                        if (!checked) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      }),
                      child: Row(
                        children: [
                          Icon(
                            checked
                                ? FluentIcons.checkbox_checked_24_filled
                                : FluentIcons.checkbox_unchecked_24_regular,
                            size: 16,
                            color: checked
                                ? const Color(0xFF6C5CE7)
                                : palette.textHint,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '[$id] ${evt['title']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                fluent.FilledButton(
                  onPressed: _busy ? null : _doExport,
                  child: Text(_busy ? '导出中…' : '导出剧本（${_selected.length}）'),
                ),
                const Spacer(),
                if (_result != null)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _result ?? ''),
                        );
                        if (context.mounted) {
                          fluent.displayInfoBar(
                            context,
                            builder: (c, close) => const fluent.InfoBar(
                              title: Text('已复制'),
                              content: Text('剧本文本已复制到剪贴板'),
                              severity: fluent.InfoBarSeverity.success,
                            ),
                          );
                        }
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            FluentIcons.copy_24_regular,
                            size: 13,
                            color: Color(0xFF6C5CE7),
                          ),
                          SizedBox(width: 4),
                          Text(
                            '复制全文',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF6C5CE7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (_result != null) ...[
              const SizedBox(height: 8),
              Container(
                height: 220,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _result!,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textBody,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _optChip(String label, String key) {
    final checked = _opts[key] ?? false;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() {
          if (key == 'pure' && !checked) {
            // 纯剧情模式下关闭所有内容选项
            for (final k in [
              'show_expr',
              'show_action',
              'show_bg',
              'show_audio',
              'show_minigame',
              'show_effect',
            ]) {
              _opts[k] = false;
            }
          }
          _opts[key] = !checked;
        }),
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: checked ? palette.tintAccent : palette.card,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: checked
                  ? const Color(0xFF6C5CE7)
                  : palette.borderHover,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: checked
                  ? palette.accentPale
                  : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

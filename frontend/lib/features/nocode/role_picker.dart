/// 无代码模式的人物浏览面板：立绘卡片网格 + 搜索 + 单/多选。
///
/// 数据走 GET /api/roles（game_dicts.roles 合并工作区 PersonCfg，含立绘
/// key）；缩略图复用资源画廊的 TexBytesCache（/api/aa/preview 解码字节，
/// 进程级缓存）。确认的选择按 kind=role 上报使用度。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../resources/image_asset_picker.dart';
import 'effect_slot_form.dart' show reportUsage;

class RoleEntry {
  const RoleEntry({
    required this.id,
    required this.name,
    this.gender,
    this.portrait = '',
  });
  final String id;
  final String name;
  final int? gender;
  final String portrait;

  factory RoleEntry.fromJson(Map j) => RoleEntry(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        gender: (j['gender'] as num?)?.toInt(),
        portrait: j['portrait']?.toString() ?? '',
      );
}

/// 拉取人物目录（q 为空返回全量）。后端不可达时返回空表。
Future<List<RoleEntry>> loadRoles(String q) async {
  try {
    final resp = await ApiClient.instance.get('/api/roles',
        query: q.trim().isEmpty ? null : {'q': q.trim()});
    final list = (resp['roles'] as List? ?? const []).cast<Map>();
    return list.map(RoleEntry.fromJson).toList();
  } catch (_) {
    return const [];
  }
}

/// 打开人物浏览面板；确认返回所选 id（按点选顺序），取消返回 null。
/// [multi]=true 多选（累加高亮），false 单击即选中并返回。
Future<List<String>?> showRolePickerDialog(
  BuildContext context, {
  bool multi = true,
  String title = '选择人物',
  Set<String> exclude = const {},
}) {
  return showDialog<List<String>>(
    context: context,
    barrierColor: palette.scrim,
    builder: (ctx) => _RolePickerDialog(multi: multi, title: title, exclude: exclude),
  );
}

class _RolePickerDialog extends StatefulWidget {
  const _RolePickerDialog({required this.multi, required this.title, required this.exclude});
  final bool multi;
  final String title;
  final Set<String> exclude;

  @override
  State<_RolePickerDialog> createState() => _RolePickerDialogState();
}

class _RolePickerDialogState extends State<_RolePickerDialog> {
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  List<RoleEntry> _items = const [];
  bool _loading = true;
  final List<String> _picked = [];

  @override
  void initState() {
    super.initState();
    _fetch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _fetch(String q) async {
    final items = await loadRoles(q);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _fetch(v));
  }

  void _tap(RoleEntry r) {
    if (widget.multi) {
      setState(() {
        if (_picked.contains(r.id)) {
          _picked.remove(r.id);
        } else {
          _picked.add(r.id);
        }
      });
    } else {
      if (r.id.isNotEmpty) reportUsage('role', r.id);
      Navigator.pop(context, [r.id]);
    }
  }

  void _confirm() {
    for (final id in _picked) {
      reportUsage('role', id);
    }
    Navigator.pop(context, List.of(_picked));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.title}${widget.multi ? '（多选）' : ''}',
          style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            fluent.TextBox(
              controller: _q,
              placeholder: '搜索人物（中文名或 ID）…',
              style: const TextStyle(fontSize: 12),
              onChanged: _onQuery,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: fluent.ProgressRing())
                  : _items.isEmpty
                      ? Center(
                          child: Text('没有匹配的人物',
                              style: TextStyle(fontSize: 12, color: palette.textMuted)))
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 110,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 0.72,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (c, i) {
                            final r = _items[i];
                            final selected = _picked.contains(r.id);
                            final disabled = widget.exclude.contains(r.id);
                            return Opacity(
                              opacity: disabled ? 0.35 : 1,
                              child: MouseRegion(
                                cursor: disabled
                                    ? SystemMouseCursors.forbidden
                                    : SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: disabled ? null : () => _tap(r),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: palette.card,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: selected
                                            ? accentColor
                                            : palette.border,
                                        width: selected ? 2 : 1,
                                      ),
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    child: Column(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(4),
                                            child: r.portrait.isEmpty
                                                ? Center(
                                                    child: Icon(
                                                        Icons.person_outline,
                                                        size: 28,
                                                        color: palette.textHint))
                                                : TexThumb(
                                                    keyName: r.portrait,
                                                    fit: BoxFit.contain),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          r.name.isEmpty ? r.id : r.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        Text(
                                          'ID ${r.id}',
                                          maxLines: 1,
                                          style: TextStyle(
                                              fontSize: 9.5, color: palette.textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        Text(_picked.isEmpty ? '' : '已选 ${_picked.length} 项',
            style: TextStyle(fontSize: 11, color: palette.textMuted)),
        fluent.Button(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (widget.multi)
          fluent.FilledButton(
            onPressed: _picked.isEmpty ? null : _confirm,
            child: const Text('确定'),
          ),
      ],
    );
  }
}

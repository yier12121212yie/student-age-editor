import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/error_text.dart';
import '../blocks/block_library.dart';
import '../editor/field_meta.dart';
import '../editor/field_utils.dart';
import 'effect_block_editor.dart';

/// 简易模式下的效果/条件/指令字段：**内联积木编辑器**，默认零文本输入。
///
/// 三个编辑面（经典 schema 编辑器、剧情图内联卡片、剧情图 Inspector）共用
/// 本组件，保证"开启简易模式后没有地方能手输代码"的目标在任一入口都成立。
///
/// 数据安全边界：
/// - 文本能拆成积木 → 行卡片编辑，行变更即时写回（防抖在积木编辑器内）；
/// - 文本拆不动（后端不可达 / 非码内容）→ 只读展示原文，绝不覆写；
/// - **字段级逃生口（D7）**：仅当「拆不动」时才露出的「仅此字段文本编辑」，
///   默认折叠；展开后带 `/api/effect_validate` 实时校验，点「应用」才写回。
///   这是唯一的手输通道，且按 Q5 决策**只覆盖拆不动的字段**，不作为常规路径。
/// - 其余情况仍靠"切换到高级编辑"（整界面退出简易模式）。
class NoCodeEffectField extends StatefulWidget {
  const NoCodeEffectField({
    super.key,
    required this.value,
    required this.type,
    required this.cfg,
    required this.fieldKey,
    required this.onChanged,
    this.mode,
    this.gameDicts = const {},
    this.onDisableNoCode,
    this.dense = false,
  });

  /// 字段当前值（1D/2D Array 的 JSON 值）。
  final dynamic value;

  /// schema 类型：1D Array / 2D Array。
  final String type;

  /// 所属配置表（决定积木 mode 的 cfg 限定分支）。
  final String cfg;

  /// 字段 key（用于 ValueKey 与 mode 推断）。
  final String fieldKey;

  final ValueChanged<dynamic> onChanged;

  /// 显式指定补全目录 mode；缺省按 [effectSuggestMode] 推断，仍为空时按 effect。
  final String? mode;

  final Map<String, dynamic> gameDicts;

  /// 逃生口：切换到高级编辑以便手动编辑（null = 不显示该入口，如内联卡片）。
  final VoidCallback? onDisableNoCode;

  /// 紧凑形态（剧情图内联卡片约 200px 宽）：隐藏脚注、逃生口与字段级文本编辑。
  final bool dense;

  @override
  State<NoCodeEffectField> createState() => _NoCodeEffectFieldState();
}

class _NoCodeEffectFieldState extends State<NoCodeEffectField> {
  /// 积木编辑器当前是否「拆不动」（D7 的字段级逃生口开关）。
  bool _unparsed = false;

  /// 字段级文本编辑通道是否展开（默认折叠）。
  bool _rawOpen = false;

  late final TextEditingController _rawCtrl;
  Timer? _validateDebounce;
  String? _validateText;
  Color? _validateColor;
  String? _applyHint;

  String get _mode {
    final m = widget.mode;
    if (m != null && m.isNotEmpty) return m;
    return effectSuggestMode(widget.cfg, widget.fieldKey) ?? 'effect';
  }

  /// 1D 码字段（screenEffect）：一句话只能一个屏幕效果。
  bool get _singleRow => singleRowForType(widget.type);

  @override
  void initState() {
    super.initState();
    _rawCtrl = TextEditingController(text: ValueCodec.encode(widget.value));
  }

  @override
  void didUpdateWidget(covariant NoCodeEffectField old) {
    super.didUpdateWidget(old);
    // 外部改值（撤销回滚、切字段、宿主重载）时同步文本；用户正在编辑时不打断。
    final t = ValueCodec.encode(widget.value);
    if (t != ValueCodec.encode(old.value) && t != _rawCtrl.text) {
      _rawCtrl.text = t;
      _applyHint = null;
      _validateText = null;
    }
  }

  @override
  void dispose() {
    _validateDebounce?.cancel();
    _rawCtrl.dispose();
    super.dispose();
  }

  /// 用完整积木库（分类目录 + 多行搭建）替换字段内容。
  Future<void> _openLibrary(BuildContext context, String text) async {
    final out = await showBlockLibrary(
      context,
      initialText: text,
      initialMode: _mode,
      gameDicts: widget.gameDicts,
      singleRow: _singleRow,
    );
    if (out == null) return;
    widget.onChanged(ValueCodec.decode(out, widget.type));
  }

  /// 子编辑器解析状态回调：回调可能在 build 期间同步到达（子组件的 initState /
  /// didUpdateWidget 路径），因此推迟到帧末再 setState，避免「build 期间置脏」。
  void _onUnparsedChanged(bool v) {
    if (v == _unparsed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || v == _unparsed) return;
      setState(() {
        _unparsed = v;
        if (!v) {
          _rawOpen = false;
          _validateText = null;
          _applyHint = null;
        }
      });
    });
  }

  void _toggleRaw() {
    setState(() {
      _rawOpen = !_rawOpen;
      if (_rawOpen) _scheduleValidate();
    });
  }

  /// `/api/effect_validate` 实时校验（防抖 350ms，与高级编辑一致）。
  void _scheduleValidate() {
    _validateDebounce?.cancel();
    _validateDebounce = Timer(const Duration(milliseconds: 350), () async {
      final t = _rawCtrl.text.trim();
      if (!mounted) return;
      if (t.isEmpty) {
        setState(() {
          _validateText = '空内容：将清空该字段';
          _validateColor = palette.textMuted;
        });
        return;
      }
      try {
        final resp = await ApiClient.instance
            .post('/api/effect_validate', body: {'text': t, 'mode': _mode});
        if (!mounted) return;
        final valid = resp['valid'] == true;
        final errors = (resp['errors'] as List? ?? const []).cast<dynamic>();
        final translations =
            (resp['translations'] as List? ?? const []).cast<dynamic>();
        setState(() {
          if (errors.isNotEmpty) {
            _validateText = '❌ ${errors.join('；')}';
            _validateColor = palette.statusDanger;
          } else if (valid) {
            final tr = translations.map((e) => e.toString()).join('、');
            _validateText = tr.isEmpty ? '✅ 格式正确' : '✅ 校验通过：$tr';
            _validateColor = palette.statusOk;
          } else {
            _validateText = resp['message']?.toString() ?? '格式错误';
            _validateColor = palette.statusWarn;
          }
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _validateText = '校验失败：${humanizeErrorMessage(e)}';
          _validateColor = palette.textSecondary;
        });
      }
    });
  }

  /// 「应用」：把文本写回字段（用户显式动作 —— 这是唯一允许覆写的通道）。
  void _applyRaw() {
    try {
      widget.onChanged(ValueCodec.decode(_rawCtrl.text, widget.type));
      setState(() => _applyHint = '已写入，可继续在积木里调整');
    } catch (e) {
      setState(() => _applyHint = '写入失败：${humanizeErrorMessage(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = ValueCodec.encode(widget.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.dense)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Text('积木编辑',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textMuted)),
                const Spacer(),
                fluent.Button(
                  onPressed: () => _openLibrary(context, text),
                  child: const Text('打开积木库', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
        EffectBlockEditor(
          key: ValueKey('nocode-blocks-${widget.cfg}-${widget.fieldKey}-${widget.type}'),
          initialText: text,
          mode: _mode,
          gameDicts: widget.gameDicts,
          singleRow: _singleRow,
          embedded: true,
          onUnparsedChanged: _onUnparsedChanged,
          onResult: (out) {
            if (out == null) return;
            widget.onChanged(ValueCodec.decode(out, widget.type));
          },
        ),
        // D7：只对「拆不动」的字段露出手输通道，默认折叠；dense 内联卡片不显示。
        if (!widget.dense && _unparsed) _escapeHatch(),
        if (!widget.dense && widget.onDisableNoCode != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: fluent.Button(
                onPressed: widget.onDisableNoCode,
                child: const Text('切换到高级编辑',
                    style: TextStyle(fontSize: 10)),
              ),
            ),
          ),
      ],
    );
  }

  /// 字段级逃生口：折叠头 + （展开后）文本框 + 实时校验 + 应用。
  Widget _escapeHatch() {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.xxs),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('field-raw-toggle'),
            onTap: _toggleRaw,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(_rawOpen ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: palette.statusWarn),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('仅此字段文本编辑',
                        style: TextStyle(fontSize: 10.5, color: palette.statusWarn)),
                  ),
                  if (!_rawOpen)
                    Text('这段拆不成积木',
                        style: TextStyle(fontSize: 9.5, color: palette.textHint)),
                ],
              ),
            ),
          ),
          if (_rawOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fluent.TextBox(
                    key: const ValueKey('field-raw-input'),
                    controller: _rawCtrl,
                    maxLines: 4,
                    minLines: 2,
                    placeholder: '[1, 1, 3, 5]; [7, 1, 101, 50]',
                    style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                    onChanged: (_) => _scheduleValidate(),
                  ),
                  if (_validateText != null) ...[
                    const SizedBox(height: 5),
                    Text(_validateText!,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: _validateColor ?? palette.textMuted,
                            height: 1.3)),
                  ],
                  if (_applyHint != null) ...[
                    const SizedBox(height: 3),
                    Text(_applyHint!,
                        style: TextStyle(fontSize: 10, color: palette.textHint)),
                  ],
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: fluent.FilledButton(
                      key: const ValueKey('field-raw-apply'),
                      onPressed: _applyRaw,
                      child: const Text('应用', style: TextStyle(fontSize: 10.5)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

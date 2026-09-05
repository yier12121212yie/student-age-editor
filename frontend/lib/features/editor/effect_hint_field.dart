import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import 'field_utils.dart';
import '../../core/app_theme.dart';
import 'suggestion_text_field.dart';

/// 全角标点 → 半角映射（官方指南仅允许英文符号；顿号按逗号处理）。
const _fullWidthToHalf = <String, String>{
  '，': ',',
  '；': ';',
  '、': ',',
  '：': ':',
  '．': '.',
};

/// 把常见全角标点替换为半角（逐字符等长替换，替换后光标位置保持不变）。
String _normalizeFullWidth(String text) {
  if (!text.contains(RegExp(r'[，；、：．]'))) return text;
  return text.replaceAllMapped(RegExp(r'[，；、：．]'), (m) {
    final ch = m[0];
    return ch == null ? '' : _fullWidthToHalf[ch] ?? ch;
  });
}

/// 检测指南不建议的字符（空格 / 未自动转换的全角符号），仅提示不阻断输入。
/// 紧跟分隔符（逗号/分号/括号/换行）的空格属于编辑器自身的展示分隔，忽略。
String? _illegalCharHint(String text) {
  final found = <String>{};
  if (RegExp(r'(?<![;,\[\n])[ \t　]').hasMatch(text)) {
    found.add('空格');
  }
  for (final m in RegExp(r'[\uFF01-\uFF5E\u3001-\u303F]').allMatches(text)) {
    found.add('全角符号「${m[0]}」');
    if (found.length >= 3) break;
  }
  if (found.isEmpty) return null;
  return '检测到指南不建议的字符：${found.take(3).join('、')}；常见全角标点已自动转换，建议手动清理';
}

/// 光标位置钳制（保持范围内）。
int _clampCursor(int v, int max) => v < 0 ? 0 : (v > max ? max : v);

/// 对标友商 SmartTemplateEditor 的效果/条件/消耗提示输入框
/// - 输入关键字或代码片段时弹出候选（desc -> code）
/// - 底部状态栏实时翻译/校验，中文可读
///
/// 输入框本体、候选浮层与 Tab/↑↓/Enter/Esc 键盘接管都由 [SuggestionTextField]
/// 提供（与剧情图共用同一套补全机器）；这里只保留本字段特有的三件事：
/// 全角标点归一、/api/effect_validate 状态栏、以及 fieldKey → mode 的推断。
class EffectHintField extends StatefulWidget {
  const EffectHintField({
    super.key,
    required this.value,
    required this.type,
    required this.fieldKey,
    required this.onChanged,
    this.mode,
  });

  final dynamic value;
  final String type; // 2D Array / 1D Array
  final String fieldKey; // effect / condition / cost / roles / screenEffect ...
  final ValueChanged<dynamic> onChanged;

  /// 显式指定提示模式（action/screen/cost/condition/effect）；
  /// 为空时按 fieldKey 推断（roles→action、screenEffect→screen、其余沿用原规则）。
  final String? mode;

  @override
  State<EffectHintField> createState() => _EffectHintFieldState();
}

class _EffectHintFieldState extends State<EffectHintField> {
  /// 控制器与焦点由本 State 持有后注入补全框：撤销回滚、外部改值都要能回写文本。
  late final TextEditingController _ctrl;
  late final FocusNode _focusNode;
  final GlobalKey<SuggestionTextFieldState> _fieldKey =
      GlobalKey<SuggestionTextFieldState>();

  /// 候选源要跨帧同标识：补全框按 identical 比较 source，换对象就当作换了数据源。
  late final SuggestionSource _source = _suggest;
  Timer? _debounceValidate;

  /// 候选条数：候选列表归 [SuggestionTextField] 持有，这里只留提示行要用的计数。
  int _candidateCount = 0;

  // 校验状态
  String _statusText = '准备就绪';
  Color _statusColor = palette.textMuted;
  bool _statusIsError = false;
  // 非法字符提示（空格/全角符号），仅提示不阻断输入
  String? _illegalHint;

  /// 1D Array（TalkCfg.screenEffect）：单行扁平代码文本，如 `4001,0.5`。
  bool get _is1D => widget.type == '1D Array';

  String get _mode {
    // 调用方显式指定优先
    final m = widget.mode;
    if (m != null && m.isNotEmpty) return m;
    final k = widget.fieldKey;
    if (k == 'roles') return 'action'; // TalkCfg.roles：2D 指令行 [Npc,cmd,args...]
    if (k == 'screenEffect') return 'screen'; // TalkCfg.screenEffect：1D 扁平代码
    if (k == 'cost') return 'cost';
    if (k == 'condition' || k == 'cond' || k == 'precondition' || k == 'check') return 'condition';
    // 所有 effect 变体
    if (k.toLowerCase().contains('effect')) return 'effect';
    // 其他 2D Array 默认按 effect 处理，保证至少有提示
    return 'effect';
  }

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ValueCodec.encode(widget.value));
    _illegalHint = _illegalCharHint(_ctrl.text);
    _focusNode = FocusNode();
    // 文本一变就收起候选提示：外部改值（撤销回滚、资产拖放）后旧候选已失效，
    // 浮层由补全框自己清，这里同步的是它下面那行提示。
    _ctrl.addListener(_onControllerChanged);
    // 初始校验
    _triggerValidate();
  }

  @override
  void didUpdateWidget(covariant EffectHintField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      final enc = ValueCodec.encode(widget.value);
      if (_ctrl.text != enc) {
        _ctrl.text = enc;
        setState(() => _illegalHint = _illegalCharHint(enc));
        _triggerValidate();
      }
    }
  }

  @override
  void dispose() {
    _debounceValidate?.cancel();
    _ctrl.removeListener(_onControllerChanged);
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_candidateCount == 0) return;
    setState(() => _candidateCount = 0);
  }

  /// 候选源：/api/effect_suggest，把后端 items 映射成 [Suggestion]。
  /// 失败按空候选处理（补全框此时退化成普通输入框）。
  Future<List<Suggestion>> _suggest(SuggestionQuery query) async {
    List<Suggestion> found;
    try {
      final resp = await ApiClient.instance.get(
        '/api/effect_suggest',
        query: {'q': query.token, 'mode': _mode},
      );
      final items = (resp['items'] as List? ?? []).cast<Map<String, dynamic>>();
      found = [
        for (final e in items)
          Suggestion(
            e['code']?.toString() ?? '',
            e['desc']?.toString() ?? '',
          ),
      ];
    } catch (_) {
      found = const [];
    }
    if (mounted && found.length != _candidateCount) {
      setState(() => _candidateCount = found.length);
    }
    // 补全框可能判定这批候选已过期而丢弃，一帧后按它的真实状态校准提示行。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCandidateCount());
    return found;
  }

  void _syncCandidateCount() {
    if (!mounted) return;
    final n = _fieldKey.currentState?.candidateCount ?? 0;
    if (n != _candidateCount) setState(() => _candidateCount = n);
  }

  void _onTextChanged(String v) {
    // 指南仅支持英文符号：自动把常见全角标点转为半角（等长替换，光标位置保持）
    final normalized = _normalizeFullWidth(v);
    if (normalized != v) {
      final sel = _ctrl.selection;
      _ctrl.value = TextEditingValue(
        text: normalized,
        selection: sel.copyWith(
          baseOffset: _clampCursor(sel.baseOffset, normalized.length),
          extentOffset: _clampCursor(sel.extentOffset, normalized.length),
        ),
      );
      v = normalized;
    }
    setState(() => _illegalHint = _illegalCharHint(v));
    try {
      widget.onChanged(ValueCodec.decode(v, widget.type));
    } catch (_) {}
    _triggerValidate();
  }

  void _triggerValidate() {
    _debounceValidate?.cancel();
    _debounceValidate = Timer(const Duration(milliseconds: 350), () async {
      final t = _ctrl.text.trim();
      if (t.isEmpty) {
        if (!mounted) return;
        setState(() {
          _statusText = '✅ 无附加条件/效果';
          _statusColor = palette.statusOk;
          _statusIsError = false;
        });
        return;
      }
      try {
        final resp = await ApiClient.instance.post('/api/effect_validate', body: {'text': t, 'mode': _mode});
        if (!mounted) return;
        final valid = resp['valid'] == true;
        final translations = (resp['translations'] as List? ?? []).cast<dynamic>();
        final errors = (resp['errors'] as List? ?? []).cast<dynamic>();
        if (errors.isNotEmpty) {
          setState(() {
            _statusText = '❌ ${errors.join('\n')}';
            _statusColor = palette.statusDanger;
            _statusIsError = true;
          });
        } else if (valid) {
          final trans = translations.map((e) => e.toString()).join('、\n');
          setState(() {
            _statusText = trans.isEmpty ? '✅ 格式正确' : '✅ 逻辑校验通过：\n$trans';
            _statusColor = palette.statusOk;
            _statusIsError = false;
          });
        } else {
          setState(() {
            _statusText = resp['message']?.toString() ?? '格式错误';
            _statusColor = palette.statusWarn;
            _statusIsError = true;
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _statusText = '校验失败：$e';
          _statusColor = palette.textSecondary;
          _statusIsError = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 浮层是否展开由补全框自己决定，父级重建时按它的实时状态出提示文案。
    final overlayOpen = _fieldKey.currentState?.overlayOpen ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SuggestionTextField(
          key: _fieldKey,
          controller: _ctrl,
          focusNode: _focusNode,
          maxLines: _is1D ? 1 : 4,
          placeholder: _is1D
              ? '输入屏幕效果代码（如 4001,0.5），支持关键字检索候选…'
              : '输入关键字或指令代码进行检索（支持拼音、大小写、数学符号如 > >= ≤ 等）…',
          source: _source,
          multivalued: true,
          onChanged: _onTextChanged,
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _statusIsError ? palette.tintDanger : palette.tintOk,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _statusIsError ? palette.tintDanger : palette.tintOk),
          ),
          child: Text(
            _statusText,
            style: TextStyle(fontSize: 11.5, color: _statusColor, height: 1.45, fontWeight: _statusIsError ? FontWeight.w600 : FontWeight.w400),
          ),
        ),
        if (_illegalHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _illegalHint!,
              style: TextStyle(
                fontSize: 11,
                color: palette.warning,
                height: 1.4,
              ),
            ),
          ),
        if (_candidateCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              overlayOpen
                  ? '候选 $_candidateCount 项 · Tab/Enter 补全 · ↑↓ 切换 · 点击插入'
                  : '候选 $_candidateCount 项 · Tab 补全 · 点击插入',
              style: TextStyle(fontSize: 10.5, color: palette.textHint),
            ),
          ),
      ],
    );
  }
}

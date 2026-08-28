import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import 'field_utils.dart';

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
  late final TextEditingController _ctrl;
  late final FocusNode _focusNode;
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();
  final ScrollController _listCtrl = ScrollController();
  OverlayEntry? _overlayEntry;
  List<Map<String, String>> _suggestions = [];
  int _selectedIndex = 0;
  String _currentKeyword = '';
  Timer? _debounceSuggest;
  Timer? _debounceValidate;
  bool _overlayVisible = false;

  // 校验状态
  String _statusText = '准备就绪';
  Color _statusColor = const Color(0xFF8B8B93);
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

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // 兼容长按产生的 KeyRepeatEvent
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (_suggestions.isNotEmpty) {
        _tryAcceptTab();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_suggestions.isNotEmpty) {
        if (!_overlayVisible) {
          _showOverlay();
        } else {
          _moveSelection(1);
        }
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_suggestions.isNotEmpty) {
        if (!_overlayVisible) {
          _showOverlay();
        } else {
          _moveSelection(-1);
        }
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_suggestions.isNotEmpty && _overlayVisible) {
        _tryAcceptTab();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_overlayVisible || _suggestions.isNotEmpty) {
        _clearSuggestions();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ValueCodec.encode(widget.value));
    _illegalHint = _illegalCharHint(_ctrl.text);
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _hideOverlay();
      }
    });
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
    _debounceSuggest?.cancel();
    _debounceValidate?.cancel();
    _hideOverlay();
    _listCtrl.dispose();
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _hideOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
      _overlayVisible = false;
    }
  }

  void _clearSuggestions() {
    if (_suggestions.isEmpty && !_overlayVisible) return;
    setState(() {
      _suggestions = [];
      _selectedIndex = 0;
    });
    _hideOverlay();
  }

  bool _tryAcceptTab() {
    if (_suggestions.isEmpty) return false;
    final idx = _selectedIndex.clamp(0, _suggestions.length - 1);
    _onItemClicked(_suggestions[idx]);
    return true;
  }

  void _moveSelection(int delta) {
    if (_suggestions.isEmpty) return;
    final next = (_selectedIndex + delta).clamp(0, _suggestions.length - 1);
    if (next == _selectedIndex) return;
    setState(() => _selectedIndex = next);
    _overlayEntry?.markNeedsBuild();
    // 滚动到可视区，延后一帧等待 overlay 重建
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listCtrl.hasClients) return;
      const itemExtent = 42.0;
      final offset = next * itemExtent;
      final viewport = _listCtrl.position.viewportDimension;
      final cur = _listCtrl.offset;
      if (offset < cur) {
        _listCtrl.jumpTo(offset.clamp(0.0, _listCtrl.position.maxScrollExtent));
      } else if (offset + itemExtent > cur + viewport) {
        _listCtrl.jumpTo((offset + itemExtent - viewport).clamp(0.0, _listCtrl.position.maxScrollExtent));
      }
    });
  }

  void _showOverlay() {
    if (_overlayVisible) {
      _overlayEntry?.markNeedsBuild();
      return;
    }
    if (_suggestions.isEmpty) return;
    // 紧凑弹窗：更小尺寸、更少遮挡，紧贴输入框底部
    const double gap = 4;
    const double overlayMaxH = 168;
    const double itemExtent = 42;
    double targetHeight = 32;
    double targetWidth = 360;
    final targetCtx = _targetKey.currentContext;
    if (targetCtx != null) {
      final box = targetCtx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        targetHeight = box.size.height;
        targetWidth = box.size.width;
      }
    }
    final media = MediaQuery.of(context);
    final viewH = media.size.height;
    double offsetY = targetHeight + gap;
    bool showAbove = false;
    if (targetCtx != null) {
      final box = targetCtx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final global = box.localToGlobal(Offset.zero);
        final spaceBelow = viewH - (global.dy + targetHeight + gap);
        if (spaceBelow < 96 && global.dy > spaceBelow) {
          showAbove = true;
          offsetY = -overlayMaxH - gap;
        }
      }
    }
    final overlay = Overlay.of(context);
    // 宽度跟随输入框但上限收紧，避免霸占整行
    final width = targetWidth.clamp(260.0, 380.0);
    _overlayEntry = OverlayEntry(builder: (ctx) {
      return CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: Offset(0, offsetY),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: width,
            constraints: const BoxConstraints(maxHeight: overlayMaxH),
            decoration: BoxDecoration(
              color: const Color(0xFF26262E),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF3A3A44)),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 3))],
            ),
            child: ListView.separated(
              controller: _listCtrl,
              padding: const EdgeInsets.symmetric(vertical: 2),
              shrinkWrap: true,
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF2E2E38)),
              itemBuilder: (c, i) {
                final it = _suggestions[i];
                final isSelected = i == _selectedIndex;
                return InkWell(
                  onTap: () {
                    _selectedIndex = i;
                    _onItemClicked(it);
                  },
                  child: Container(
                    color: isSelected ? const Color(0xFF2A3B52) : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it['desc'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Color(0xFFE8E8EE), height: 1.3)),
                        const SizedBox(height: 1),
                        Text(it['code'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Color(0xFF9B9BA3), fontFamily: 'Consolas')),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    });
    overlay.insert(_overlayEntry!);
    _overlayVisible = true;
    if (showAbove) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_listCtrl.hasClients) {
          final o = (_selectedIndex * itemExtent).clamp(0.0, _listCtrl.position.maxScrollExtent);
          _listCtrl.jumpTo(o);
        }
      });
    }
  }

  void _onItemClicked(Map<String, String> item) {
    final code = item['code'] ?? '';
    if (code.isEmpty) return;
    final text = _ctrl.text;
    final cursorPos = _ctrl.selection.baseOffset < 0 ? text.length : _ctrl.selection.baseOffset;
    int startIdx = -1;
    if (_currentKeyword.isNotEmpty) {
      startIdx = text.lastIndexOf(_currentKeyword, cursorPos - 1);
      // 若未找到，尝试在光标前的搜索区里定位
      if (startIdx < 0) {
        // 回退：按关键词在光标前的最后出现
        final before = text.substring(0, cursorPos);
        startIdx = before.lastIndexOf(_currentKeyword);
      }
    }
    String newText;
    int newPos;
    if (startIdx >= 0) {
      final prefix = text.substring(0, startIdx);
      final suffix = text.substring(cursorPos);
      String sep = '';
      if (prefix.isNotEmpty && !prefix.endsWith(',') && !prefix.endsWith(', ') && !prefix.endsWith(' ') && !prefix.endsWith(';') && !prefix.endsWith('; ')) {
        sep = ', ';
      }
      newText = prefix + sep + code + suffix;
      newPos = prefix.length + sep.length + code.length;
    } else {
      // 未定位到关键词，直接追加
      final suffix = text.substring(cursorPos);
      final prefix = text.substring(0, cursorPos);
      final needsSep = prefix.trim().isNotEmpty && !prefix.trim().endsWith(',') && !prefix.trim().endsWith(';');
      newText = prefix + (needsSep ? ', ' : '') + code + suffix;
      newPos = prefix.length + (needsSep ? 2 : 0) + code.length;
    }
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(offset: newPos.clamp(0, newText.length));
    _hideOverlay();
    _onTextChanged(newText);
    // 保持焦点
    FocusScope.of(context).requestFocus(_focusNode);
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
    _triggerSuggest(v);
    _triggerValidate();
  }

  void _triggerSuggest(String text) {
    _debounceSuggest?.cancel();
    _debounceSuggest = Timer(const Duration(milliseconds: 220), () async {
      final sel = _ctrl.selection.baseOffset;
      final cursorPos = sel < 0 ? text.length : sel;
      final textBefore = cursorPos <= text.length ? text.substring(0, cursorPos) : text;
      final lastOpen = textBefore.lastIndexOf('[');
      final lastClose = textBefore.lastIndexOf(']');
      if (lastOpen > lastClose) {
        // 光标在方括号内，不提示（与友商一致）
        if (mounted) {
          setState(() {
            _suggestions = [];
            _selectedIndex = 0;
          });
          _hideOverlay();
        }
        return;
      }
      final searchArea = lastClose != -1 ? textBefore.substring(lastClose + 1) : textBefore;
      final keyword = searchArea.trim().replaceAll(RegExp(r'^[,\s，；;]+'), '').replaceAll(RegExp(r'[,\s，；;]+$'), '').trim();
      // 进一步清理首尾逗号分号空格
      final kw = keyword.trim().replaceAll(RegExp(r'^[,\s;，、]+'), '').replaceAll(RegExp(r'[,\s;，、]+$'), '');
      if (kw.isEmpty) {
        if (mounted) {
          setState(() {
            _suggestions = [];
            _selectedIndex = 0;
          });
          _hideOverlay();
        }
        return;
      }
      _currentKeyword = kw;
      try {
        final resp = await ApiClient.instance.get('/api/effect_suggest', query: {'q': kw, 'mode': _mode});
        final items = (resp['items'] as List? ?? []).cast<Map<String, dynamic>>();
        if (!mounted) return;
        final mapped = items.map((e) => {'desc': e['desc']?.toString() ?? '', 'code': e['code']?.toString() ?? ''}).toList();
        setState(() {
          _suggestions = mapped;
          _selectedIndex = 0;
        });
        if (mapped.isEmpty) {
          _hideOverlay();
        } else {
          _showOverlay();
          // 触发重建
          _overlayEntry?.markNeedsBuild();
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _suggestions = [];
            _selectedIndex = 0;
          });
          _hideOverlay();
        }
      }
    });
  }

  void _triggerValidate() {
    _debounceValidate?.cancel();
    _debounceValidate = Timer(const Duration(milliseconds: 350), () async {
      final t = _ctrl.text.trim();
      if (t.isEmpty) {
        if (!mounted) return;
        setState(() {
          _statusText = '✅ 无附加条件/效果';
          _statusColor = const Color(0xFF4CAF82);
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
            _statusText = '❌ ' + errors.join('\n');
            _statusColor = const Color(0xFFE05A5A);
            _statusIsError = true;
          });
        } else if (valid) {
          final trans = translations.map((e) => e.toString()).join('、\n');
          setState(() {
            _statusText = trans.isEmpty ? '✅ 格式正确' : '✅ 逻辑校验通过：\n$trans';
            _statusColor = const Color(0xFF4CAF82);
            _statusIsError = false;
          });
        } else {
          setState(() {
            _statusText = resp['message']?.toString() ?? '格式错误';
            _statusColor = const Color(0xFFFFA726);
            _statusIsError = true;
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _statusText = '校验失败：$e';
          _statusColor = const Color(0xFF9B9BA3);
          _statusIsError = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompositedTransformTarget(
          key: _targetKey,
          link: _layerLink,
          child: fluent.TextBox(
            controller: _ctrl,
            focusNode: _focusNode,
            maxLines: _is1D ? 1 : 4,
            placeholder: _is1D
                ? '输入屏幕效果代码（如 4001,0.5），支持关键字检索候选…'
                : '输入关键字或指令代码进行检索（支持拼音、大小写、数学符号如 > >= ≤ 等）…',
            onChanged: _onTextChanged,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _statusIsError ? const Color(0xFF2A1B1E) : const Color(0xFF1E2420),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _statusIsError ? const Color(0xFF4A2A2E) : const Color(0xFF263028)),
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
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFFE08A3C),
                height: 1.4,
              ),
            ),
          ),
        if (_suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _overlayVisible
                  ? '候选 ${_suggestions.length} 项 · Tab/Enter 补全 · ↑↓ 切换 · 点击插入'
                  : '候选 ${_suggestions.length} 项 · Tab 补全 · 点击插入',
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF6E6E76)),
            ),
          ),
      ],
    );
  }
}

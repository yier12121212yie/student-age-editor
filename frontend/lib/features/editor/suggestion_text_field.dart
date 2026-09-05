/// 通用「输入即补全」文本框：OverlayEntry 候选 + Tab/↑↓/Enter/Esc 键盘接管。
///
/// 与 EffectHintField 的区别只在契约：controller 与 focusNode 由外部注入，
/// 数据源通过 [SuggestionSource] 传入。剧情图必须复用 workspace 里那一份字段
/// 控制器，否则内联卡片与 Inspector 各自持有文本，双向同步就得手写胶水。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/app_theme.dart';

/// 一条候选：[code] 是插入的文本，[desc] 是给人看的说明。
class Suggestion {
  const Suggestion(this.code, this.desc);
  final String code;
  final String desc;
}

/// 一次候选查询：光标前解析出的 [token] 及完整上下文。
class SuggestionQuery {
  const SuggestionQuery({
    required this.token,
    required this.cursor,
    required this.text,
  });
  final String token;
  final int cursor;
  final String text;
}

typedef SuggestionSource = Future<List<Suggestion>> Function(SuggestionQuery);

/// 默认可信 token 字符：除分隔符与括号外的任意字符（含中文，候选按名称匹配）。
final RegExp kDefaultTokenPattern = RegExp(r'[^,;，、；\[\]()\s"]');

class SuggestionTextField extends StatefulWidget {
  const SuggestionTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.source,
    this.onChanged,
    this.onTabWithoutCandidates,
    this.maxLines = 1,
    this.multivalued = false,
    this.replaceWholeOnAccept = false,
    this.tokenPattern,
    this.placeholder,
    this.style,
    this.padding,
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// 候选来源；null 或返回空列表时本框退化为普通输入框。
  final SuggestionSource? source;
  final ValueChanged<String>? onChanged;

  /// 无候选时按 Tab：由宿主决定跳下一字段；null 则交回系统树序。
  final VoidCallback? onTabWithoutCandidates;

  final int maxLines;
  final bool multivalued;

  /// 接受候选时整串替换（如 screenEffect：一句话只能填一个屏幕效果）。
  final bool replaceWholeOnAccept;
  final RegExp? tokenPattern;
  final String? placeholder;
  final TextStyle? style;

  /// null = 沿用 fluent 默认内边距。
  final EdgeInsetsGeometry? padding;

  /// false 时不查候选（只读展示或字段暂不可编辑）。
  final bool enabled;

  @override
  State<SuggestionTextField> createState() => SuggestionTextFieldState();
}

class SuggestionTextFieldState extends State<SuggestionTextField> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _targetKey = GlobalKey();
  final ScrollController _listCtrl = ScrollController();
  OverlayEntry? _overlayEntry;
  List<Suggestion> _suggestions = const [];
  int _selectedIndex = 0;
  bool _overlayVisible = false;
  Timer? _debounceSuggest;

  /// 本框自己发起的文本变更：外部（撤销回滚、资产拖放）改文本要收起候选，
  /// 否则旧候选会被误接受成脏数据。
  bool _localEdit = false;

  /// 宿主可能自己挂过按键处理，接管后要还原。
  FocusOnKeyEventCallback? _priorOnKeyEvent;
  FocusNode? _handledNode;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onControllerChanged);
    _takeOverKeyHandler();
  }

  /// fluent.TextBox 不暴露 onKeyEvent，只能把处理函数挂到它使用的 FocusNode 上
  /// （FocusNode.onKeyEvent 是公开可写字段，且按键分发先走节点再走 Actions）。
  void _takeOverKeyHandler() {
    final node = widget.focusNode;
    if (identical(_handledNode, node) && node.onKeyEvent == handleKeyEvent) {
      return;
    }
    _restoreKeyHandler();
    _priorOnKeyEvent = node.onKeyEvent;
    _handledNode = node;
    node.onKeyEvent = handleKeyEvent;
  }

  void _restoreKeyHandler() {
    final node = _handledNode;
    if (node == null) return;
    if (node.onKeyEvent == handleKeyEvent) node.onKeyEvent = _priorOnKeyEvent;
    _handledNode = null;
    _priorOnKeyEvent = null;
  }

  @override
  void didUpdateWidget(covariant SuggestionTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
      _restoreKeyHandler();
      _takeOverKeyHandler();
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (oldWidget.enabled != widget.enabled ||
        !identical(oldWidget.source, widget.source)) {
      clearCandidates();
    }
  }

  @override
  void dispose() {
    _debounceSuggest?.cancel();
    _hideOverlay();
    _listCtrl.dispose();
    widget.focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onControllerChanged);
    _restoreKeyHandler();
    super.dispose();
  }

  void _onFocusChanged() {
    // 失焦 = 放弃这次补全：只藏 overlay 会留下看不见的候选，
    // 再按 Tab 仍会把它们插进去。
    if (!widget.focusNode.hasFocus) clearCandidates();
  }

  void _onControllerChanged() {
    if (_localEdit) return;
    if (_overlayVisible || _suggestions.isNotEmpty) clearCandidates();
  }

  // ---------- 键盘 ----------

  KeyEventResult handleKeyEvent(FocusNode node, KeyEvent event) {
    // 只认 KeyDownEvent：按住 Tab 连发会一次吃掉多个字段（或连吃多条候选）。
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.tab) return _onTab();
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        return _onArrow(1);
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        return _onArrow(-1);
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (_suggestions.isNotEmpty && _overlayVisible) {
          acceptSelected();
          return KeyEventResult.handled;
        }
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_overlayVisible || _suggestions.isNotEmpty) {
        clearCandidates();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onTab() {
    if (_suggestions.isEmpty) {
      final fwd = widget.onTabWithoutCandidates;
      if (fwd == null) return KeyEventResult.ignored;
      fwd();
      return KeyEventResult.handled;
    }
    acceptSelected();
    return KeyEventResult.handled;
  }

  KeyEventResult _onArrow(int delta) {
    if (_suggestions.isEmpty) return KeyEventResult.ignored;
    if (!_overlayVisible) {
      _showOverlay();
    } else {
      _moveSelection(delta);
    }
    return KeyEventResult.handled;
  }

  // ---------- 候选 ----------

  void clearCandidates() {
    if (_suggestions.isEmpty && !_overlayVisible) return;
    setState(() {
      _suggestions = const [];
      _selectedIndex = 0;
    });
    _hideOverlay();
  }

  bool acceptSelected() {
    if (_suggestions.isEmpty) return false;
    final idx = _selectedIndex.clamp(0, _suggestions.length - 1);
    _insert(_suggestions[idx]);
    return true;
  }

  void _moveSelection(int delta) {
    if (_suggestions.isEmpty) return;
    final next = (_selectedIndex + delta).clamp(0, _suggestions.length - 1);
    if (next == _selectedIndex) return;
    setState(() => _selectedIndex = next);
    _overlayEntry?.markNeedsBuild();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listCtrl.hasClients) return;
      const itemExtent = 42.0;
      final offset = next * itemExtent;
      final viewport = _listCtrl.position.viewportDimension;
      final cur = _listCtrl.offset;
      if (offset < cur) {
        _listCtrl.jumpTo(offset.clamp(0.0, _listCtrl.position.maxScrollExtent));
      } else if (offset + itemExtent > cur + viewport) {
        _listCtrl.jumpTo(
          (offset + itemExtent - viewport).clamp(
            0.0,
            _listCtrl.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  void _showOverlay() {
    if (_overlayVisible) {
      _overlayEntry?.markNeedsBuild();
      return;
    }
    if (_suggestions.isEmpty) return;
    const double gap = 4;
    const double overlayMaxH = 168;
    const double itemExtent = 42;
    double targetHeight = 32;
    double targetWidth = 360;
    final targetCtx = _targetKey.currentContext;
    final box = targetCtx?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      targetHeight = box.size.height;
      targetWidth = box.size.width;
    }
    final viewH = MediaQuery.of(context).size.height;
    double offsetY = targetHeight + gap;
    bool showAbove = false;
    if (box != null && box.hasSize) {
      final global = box.localToGlobal(Offset.zero);
      final spaceBelow = viewH - (global.dy + targetHeight + gap);
      if (spaceBelow < 96 && global.dy > spaceBelow) {
        showAbove = true;
        offsetY = -overlayMaxH - gap;
      }
    }
    final overlay = Overlay.of(context);
    // 宽度跟随输入框但上限收紧：候选画在屏幕空间、不吃画布 scale，
    // 无限宽会在缩小的画布上糊满半屏。
    final width = targetWidth.clamp(260.0, 380.0);
    _overlayEntry = OverlayEntry(
      builder: (ctx) => CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: Offset(0, offsetY),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: width,
            constraints: const BoxConstraints(maxHeight: overlayMaxH),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: palette.borderHover),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: ListView.separated(
              controller: _listCtrl,
              padding: const EdgeInsets.symmetric(vertical: 2),
              shrinkWrap: true,
              itemCount: _suggestions.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: palette.surface),
              itemBuilder: (c, i) {
                final it = _suggestions[i];
                final isSelected = i == _selectedIndex;
                return InkWell(
                  onTap: () {
                    _selectedIndex = i;
                    _insert(it);
                  },
                  child: Container(
                    color: isSelected ? palette.tintInfo : Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.desc,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: palette.textBody,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          it.code,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: palette.textSecondary,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
    _overlayVisible = true;
    if (showAbove) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_listCtrl.hasClients) return;
        _listCtrl.jumpTo(
          (_selectedIndex * itemExtent).clamp(
            0.0,
            _listCtrl.position.maxScrollExtent,
          ),
        );
      });
    }
  }

  void _hideOverlay() {
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
      _overlayVisible = false;
    }
  }

  // ---------- 插入 ----------

  /// 从光标向左扫到 token 边界，定位要替换的区间。
  ///
  /// 旧实现用 `text.lastIndexOf(_currentKeyword, cursor-1)` 找关键词，光标不
  /// 在关键词末尾时会错位；按字符扫边界与光标位置无关。
  int _tokenStart(String text, int cursor) {
    if (widget.replaceWholeOnAccept) return 0;
    final pattern = widget.tokenPattern ?? kDefaultTokenPattern;
    var i = cursor.clamp(0, text.length);
    while (i > 0 && pattern.hasMatch(text[i - 1])) {
      i--;
    }
    return i;
  }

  /// 该补的分隔符：2D 字段沿用上一种分隔符（分号=换行），其余多值补逗号。
  String _separatorFor(String prefix) {
    if (!widget.multivalued) return '';
    if (prefix.isEmpty) return '';
    // 分隔符已经在文本里（token 就紧跟在「, 」/「; 」后面），再补会拼出 ";; "
    if (prefix.endsWith(', ') || prefix.endsWith('; ')) return '';
    if (prefix.endsWith(',') || prefix.endsWith(';')) return ' ';
    // 2D 数组沿用上一种分隔符：上一行用分号开的，这行也用分号
    if (prefix.lastIndexOf(';') > prefix.lastIndexOf(',')) return '; ';
    return ', ';
  }

  void _insert(Suggestion item) {
    if (item.code.isEmpty) return;
    final text = widget.controller.text;
    final raw = widget.controller.selection.baseOffset;
    final cursor = raw < 0 ? text.length : raw.clamp(0, text.length);
    final start = _tokenStart(text, cursor);
    final prefix = text.substring(0, start);
    final suffix = text.substring(cursor);
    final String newText;
    final int newPos;
    if (widget.replaceWholeOnAccept) {
      newText = item.code;
      newPos = item.code.length;
    } else {
      final body = '${_separatorFor(prefix)}${item.code}';
      newText = '$prefix$body$suffix';
      newPos = prefix.length + body.length;
    }
    _applyText(newText, newPos.clamp(0, newText.length));
  }

  void _applyText(String newText, int caret) {
    _localEdit = true;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
    );
    _localEdit = false;
    clearCandidates();
    widget.onChanged?.call(newText);
    if (mounted) FocusScope.of(context).requestFocus(widget.focusNode);
  }

  // ---------- 文本变化 ----------

  void _onTextChanged(String v) {
    widget.onChanged?.call(v);
    _triggerSuggest(v);
  }

  void _triggerSuggest(String text) {
    _debounceSuggest?.cancel();
    final source = widget.source;
    if (!widget.enabled || source == null) {
      clearCandidates();
      return;
    }
    final raw = widget.controller.selection.baseOffset;
    final cursor = raw < 0 ? text.length : raw.clamp(0, text.length);
    // 光标在方括号内说明在填参数而不是选指令，不提示（与 EffectHintField 一致）。
    final before = text.substring(0, cursor);
    if (before.lastIndexOf('[') > before.lastIndexOf(']')) {
      clearCandidates();
      return;
    }
    final start = _tokenStart(text, cursor);
    final token = text.substring(start, cursor).trim();
    if (token.isEmpty) {
      clearCandidates();
      return;
    }
    _debounceSuggest = Timer(const Duration(milliseconds: 220), () async {
      final query = SuggestionQuery(token: token, cursor: cursor, text: text);
      List<Suggestion> found;
      try {
        found = await source(query);
      } catch (_) {
        found = const [];
      }
      if (!mounted) return;
      // 请求期间用户又改了输入：丢弃这批过期候选。
      final nowToken = _currentTokenAt(widget.controller.text);
      if (nowToken != token) return;
      setState(() {
        _suggestions = found;
        _selectedIndex = 0;
      });
      if (found.isEmpty) {
        _hideOverlay();
      } else {
        _showOverlay();
        _overlayEntry?.markNeedsBuild();
      }
    });
  }

  String _currentTokenAt(String text) {
    final raw = widget.controller.selection.baseOffset;
    final cursor = raw < 0 ? text.length : raw.clamp(0, text.length);
    return text.substring(_tokenStart(text, cursor), cursor).trim();
  }

  int get candidateCount => _suggestions.length;

  bool get overlayOpen => _overlayVisible;

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      key: _targetKey,
      link: _layerLink,
      child: fluent.TextBox(
        controller: widget.controller,
        focusNode: widget.focusNode,
        maxLines: widget.maxLines,
        minLines: 1,
        placeholder: widget.placeholder,
        style: widget.style,
        padding: widget.padding ?? fluent.kTextBoxPadding,
        onChanged: _onTextChanged,
      ),
    );
  }
}

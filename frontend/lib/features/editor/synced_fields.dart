/// 公共「同步字段」控件(A3):文本 / 数字 / 数字列表三种受控输入的单一实现。
///
/// 12 个工作台原本各自复制一份 `_SyncedText` / `_NumBox` / `_ListNumField`,
/// 共 20 / 16 / 2 份。行为一致但极易漂移(有的带 `_fmt`,有的只认 int,有的漏
/// 了 `didUpdateWidget` 回填),新增一处修正要改 12 遍。
///
/// 三个控件遵守同一条同步契约:
/// - 外部 `value` 变化时,**仅在控件未聚焦**的情况下回填到输入框 —— 用户正在
///   打字时不能被外部重建打断光标;
/// - `onChanged` 每次按键即时上报,由调用方决定写回时机(工作台统一在内存里
///   改 `_rows`,保存时整体 PUT)。
///
/// 差异点(按工作台实际需要保留为参数,不偷偷求同):
/// - [SyncedTextField]:`maxLines` / `hint`。
/// - [NumBox]:`intOnly`(目标/社交等表只认整数)与 [NumBox.format] 回填时
///   是否把 `3.0` 显示成 `3`(外部对话/小游戏/仓库需要,避免用户看到 `.0`)。
/// - [ListNumField]:`,` 与全角 `，` 都可作分隔;任一段非法则**整次不写回**,
///   避免半截输入把列表截断。
library;

import 'package:fluent_ui/fluent_ui.dart';

/// 受控单/多行文本框:聚焦中不打断,失焦后跟随外部值。
class SyncedTextField extends StatefulWidget {
  const SyncedTextField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.maxLines = 1,
    this.enabled = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final int maxLines;
  final bool enabled;

  @override
  State<SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<SyncedTextField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant SyncedTextField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _c.text) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      controller: _c,
      focusNode: _focus,
      maxLines: widget.maxLines,
      placeholder: widget.hint,
      enabled: widget.enabled,
      onChanged: widget.onChanged,
    );
  }
}

/// 受控数字框:空串 → `null`;[intOnly] 时只认整数;`format == true` 回填时
/// 把整数值的 `double` 显示成整数写法。
class NumBox extends StatefulWidget {
  const NumBox({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.intOnly = false,
    this.format = false,
    this.enabled = true,
  });

  final num? value;
  final ValueChanged<num?> onChanged;
  final String? hint;

  /// 只接受整数(`int.tryParse`),非法/小数输入上报 `null`。
  final bool intOnly;

  /// 回填时把 `3.0` 显示为 `3`;一般与「表里存的是整数」搭配使用。
  final bool format;
  final bool enabled;

  String _fmt(num? v) {
    if (v == null) return '';
    if (format && v is double && v == v.roundToDouble()) {
      return v.toInt().toString();
    }
    return v.toString();
  }

  @override
  State<NumBox> createState() => _NumBoxState();
}

class _NumBoxState extends State<NumBox> {
  late final TextEditingController _c =
      TextEditingController(text: widget._fmt(widget.value));
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant NumBox old) {
    super.didUpdateWidget(old);
    final cur = widget._fmt(widget.value);
    if (!_focus.hasFocus && cur != _c.text) _c.text = cur;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _emit(String v) {
    final t = v.trim();
    if (t.isEmpty) {
      widget.onChanged(null);
      return;
    }
    widget.onChanged(widget.intOnly ? int.tryParse(t) : num.tryParse(t));
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      controller: _c,
      focusNode: _focus,
      placeholder: widget.hint,
      enabled: widget.enabled,
      onChanged: _emit,
    );
  }
}

/// 受控整数列表框:`,` / `，` 分隔。任一段解析失败则**不写回**(保留用户正在
/// 输入的半截内容),全部合法才上报新列表。
class ListNumField extends StatefulWidget {
  const ListNumField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint,
    this.enabled = true,
  });

  final List<int> value;
  final ValueChanged<List<int>> onChanged;
  final String? hint;
  final bool enabled;

  @override
  State<ListNumField> createState() => _ListNumFieldState();
}

class _ListNumFieldState extends State<ListNumField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value.join(', '));
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant ListNumField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value.join(', ') != _c.text) {
      _c.text = widget.value.join(', ');
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      controller: _c,
      focusNode: _focus,
      placeholder: widget.hint,
      enabled: widget.enabled,
      onChanged: (v) {
        final text = v.replaceAll('，', ',');
        final parts = text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        final nums = <int>[];
        for (final p in parts) {
          final n = int.tryParse(p);
          if (n == null) return; // 有非法项时暂不写回
          nums.add(n);
        }
        widget.onChanged(nums);
      },
    );
  }
}

/// 供 `TextInputFormatter`-style 场景复用:把全角逗号规整为半角。
String normalizeListSeparators(String input) => input.replaceAll('，', ',');

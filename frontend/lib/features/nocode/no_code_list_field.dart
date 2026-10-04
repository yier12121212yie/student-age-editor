import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/app_theme.dart';
import '../editor/field_utils.dart';

/// 无代码模式下的普通数据数组（非效果码 / 无引用规则）：**行级列表编辑器**。
///
/// 与 [NoCodeEffectField] 的区别：这里的值是生日、立绘排版参数一类的普通
/// 数据，展示效果码候选既帮不上忙也不符合游戏实际语义。本编辑器只做「增删
/// 每一行 + 编辑行内数值/文本」，不提供任何效果/条件目录。
///
/// 数据形态：
/// * `1D Array`：每一行是一个值（数字或文本）；
/// * `2D Array`：每一行是一组值，行内用逗号分隔（与 [ValueCodec] 一致），
///   如 `0, 0, 1`。
///
/// 写回一律走 [ValueCodec] 的规范化（数值/字符串自动识别），与普通模式下的
/// 文本编辑语义完全等价。
class NoCodeListField extends StatefulWidget {
  const NoCodeListField({
    super.key,
    required this.value,
    required this.type,
    required this.onChanged,
    this.onDisableNoCode,
    this.dense = false,
  });

  /// 字段当前值（1D/2D Array 的 JSON 值）。
  final dynamic value;

  /// schema 类型：`1D Array` / `2D Array`。
  final String type;

  final ValueChanged<dynamic> onChanged;

  /// 逃生口：关闭无代码模式以便手动编辑（null = 不显示）。
  final VoidCallback? onDisableNoCode;

  /// 紧凑形态（剧情图内联卡片约 200px 宽）：缩小字号与行距。
  final bool dense;

  @override
  State<NoCodeListField> createState() => _NoCodeListFieldState();
}

class _NoCodeListFieldState extends State<NoCodeListField> {
  bool get _is2d => widget.type == '2D Array';

  final List<TextEditingController> _rows = [];

  /// 最近一次写回后、经 [ValueCodec] 规范化后的编码文本；用于判断外部值是否
  /// 真的变了（本组件本地编辑产生的回环不应触发重建、保住半截输入）。
  String _lastEmitted = '';

  @override
  void initState() {
    super.initState();
    _rebuildFromValue(widget.value);
  }

  @override
  void didUpdateWidget(covariant NoCodeListField old) {
    super.didUpdateWidget(old);
    final encoded = ValueCodec.encode(widget.value);
    if (encoded != _lastEmitted) _rebuildFromValue(widget.value);
  }

  @override
  void dispose() {
    for (final c in _rows) {
      c.dispose();
    }
    super.dispose();
  }

  void _rebuildFromValue(dynamic value) {
    for (final c in _rows) {
      c.dispose();
    }
    _rows.clear();
    if (value is List) {
      if (_is2d) {
        for (final row in value) {
          _rows.add(TextEditingController(
            text: row is List ? row.map(_fmt).join(', ') : _fmt(row),
          ));
        }
      } else {
        for (final e in value) {
          _rows.add(TextEditingController(text: _fmt(e)));
        }
      }
    }
    _lastEmitted = ValueCodec.encode(widget.value);
  }

  static String _fmt(dynamic v) => v == null ? '' : v.toString();

  /// 组装当前编辑态为字段值（2D 行内以逗号分隔，交给 ValueCodec 解析）。
  dynamic _assemble() {
    final texts = [for (final c in _rows) c.text];
    if (_is2d) {
      return [for (final t in texts) ValueCodec.decode(t, '1D Array')];
    }
    return [for (final t in texts) _parseScalar(t)];
  }

  static dynamic _parseScalar(String text) {
    final t = text.trim();
    if (t.isEmpty) return '';
    return num.tryParse(t) ?? t;
  }

  void _emit() {
    final value = _assemble();
    // 以规范化后的编码为基准：父级回写会做同样的规范化，避免空行被误判成
    // 「外部值变了」而反复重建丢焦点。
    final normalized = ValueCodec.decode(
      ValueCodec.encode(value),
      widget.type,
    );
    _lastEmitted = ValueCodec.encode(normalized);
    widget.onChanged(normalized);
  }

  void _addRow() {
    setState(() {
      _rows.add(TextEditingController(text: ''));
    });
    _emit();
  }

  void _removeRow(int i) {
    setState(() {
      _rows.removeAt(i).dispose();
    });
    _emit();
  }

  void _moveRow(int from, int to) {
    if (to < 0 || to >= _rows.length) return;
    setState(() {
      final c = _rows.removeAt(from);
      _rows.insert(to, c);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final fs = widget.dense ? 10.0 : 12.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              widget.dense ? '暂无内容' : '还没有条目，点击下方按钮添加第一行。',
              style: TextStyle(fontSize: fs - 1, color: palette.textHint),
            ),
          )
        else
          for (var i = 0; i < _rows.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: widget.dense ? 3 : 5),
              child: _row(i, fs),
            ),
        Align(
          alignment: Alignment.centerLeft,
          child: fluent.Button(
            onPressed: _addRow,
            child: Text(
              _is2d ? '＋ 添加一行' : '＋ 添加一项',
              style: TextStyle(fontSize: fs - 1),
            ),
          ),
        ),
        if (!widget.dense && widget.onDisableNoCode != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: fluent.Button(
                onPressed: widget.onDisableNoCode,
                child: const Text(
                  '关闭无代码模式以手动编辑',
                  style: TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(int i, double fs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: fluent.TextBox(
            controller: _rows[i],
            placeholder: _is2d ? '多个值用逗号分隔，如 0, 0, 1' : '填写数值或文本',
            style: TextStyle(fontSize: fs),
            padding: EdgeInsets.symmetric(
              horizontal: 8,
              vertical: widget.dense ? 2 : 4,
            ),
            onChanged: (_) => _emit(),
          ),
        ),
        _rowBtn('↑', i > 0, () => _moveRow(i, i - 1), fs),
        _rowBtn('↓', i < _rows.length - 1, () => _moveRow(i, i + 1), fs),
        _rowBtn('✕', true, () => _removeRow(i), fs),
      ],
    );
  }

  Widget _rowBtn(
    String label,
    bool enabled,
    VoidCallback onTap,
    double fs,
  ) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              fontSize: fs + 1,
              color: enabled ? palette.textSecondary : palette.iconDisabled,
            ),
          ),
        ),
      ),
    );
  }
}

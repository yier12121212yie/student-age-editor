#!/usr/bin/env python3
"""A3 控制器迁移（_TableBuf 家族）：external / warehouse。

这些工作台原用本地 `_TableBuf`（= name/data/snap/mtime/dirty）+ `Map<String,_TableBuf> _tables`。
改为公共 `WorkbenchController`，并把 `_tables` 变成转发 map（`data`/`dirty`/`mtime` 同名成员，
调用点 `_tableData`/`_tableDirty` 无需改动）。
"""
import re
from pathlib import Path

SPECS = {
    'external/external_dialogues_workbench.dart': {
        'cfgs': "const [_giftCfg, _miniCfg, _interactCfg, _talkCfg]",
        'ref_reads': [
            "ApiClient.instance.get('/api/cfg/PersonGrowCfg')",
            "ApiClient.instance.get('/api/cfg/ItemCfg')",
            "ApiClient.instance.get('/api/cfg/BookCfg')",
            "ApiClient.instance.get('/api/cfg/MinigameCfg')",
            "ApiClient.instance.get('/api/cfg/RelationCfg')",
        ],
        'ref_assign': [
            '_grow = _dataOf(res[1]);',
            '_items = _dataOf(res[2]);',
            '_books = _dataOf(res[3]);',
            '_minigames = _dataOf(res[4]);',
            '_relations = _dataOf(res[5]);',
        ],
        'load_tail': "      _ensureSelection();\n      _loadRoles();",
        'save_ok': "      if (mounted) {\n        AppFeedback.success(context, '外部对话已保存');\n      }",
    },
    'warehouse/warehouse_workbench.dart': {
        'cfgs': "const [_itemCfg, _bookCfg, _shopCfg]",
        'ref_reads': [
            "ApiClient.instance.get('/api/cfg/ItemTypeCfg')",
            "ApiClient.instance.get('/api/cfg/ItemTagCfg')",
            "ApiClient.instance.get('/api/cfg/BookThemeCfg')",
        ],
        'ref_assign': [
            '_types = _dataOf(res[1]);',
            '_tags = _dataOf(res[2]);',
            '_bookThemes = _dataOf(res[3]);',
        ],
        'load_tail': "      _ensureSelection();",
        'save_ok': "      if (mounted) AppFeedback.success(context, '物品仓库已保存');",
    },
}


def find_block_end(s, start):
    k = s.find('{', start)
    depth = 0
    while k < len(s):
        if s[k] == '{':
            depth += 1
        elif s[k] == '}':
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    raise RuntimeError('unbalanced')


def migrate(rel, spec):
    p = Path('lib/features') / rel
    s = p.read_text(encoding='utf-8')

    # 1) 删除 class _TableBuf 定义
    i = s.find('class _TableBuf {')
    if i >= 0:
        e = find_block_end(s, i)
        # 吞掉前后空行
        st = i
        while st > 0 and s[st-1] == '\n' and (st < 2 or s[st-2] == '\n'):
            st -= 1
        en = e
        while en < len(s) and s[en] == '\n':
            en += 1
        s = s[:st] + s[en:]

    # 2) 替换 _tables 字段为控制器 + 转发 getter
    s = s.replace(
        'final Map<String, _TableBuf> _tables = {};',
        '/// A3：可写主表由公共控制器管理；`_tables` 为转发 map。\n'
        '  late final WorkbenchController _ctl = WorkbenchController(\n'
        f'    cfgs: {spec["cfgs"]},\n'
        '    onConflict: _onConflict,\n'
        '    onError: (e) {\n'
        '      if (mounted) {\n'
        "        AppFeedback.error(context, '保存失败：${humanizeErrorMessage(e)}',\n"
        '            detail: e.toString());\n'
        '      }\n'
        '    },\n'
        '    onSaved: (_) {},\n'
        '  );\n\n'
        '  Map<String, WorkbenchTable> get _tables =>\n'
        '      {for (final t in _ctl.tables) t.cfg: t};',
        1)

    # 3) 替换 _loadAll（用 ref_reads 的长度决定索引偏移）
    n_ref = len(spec['ref_reads'])
    reads = ",\n        ".join(spec['ref_reads'])
    assign = "\n      ".join(spec['ref_assign'])
    new_load = (
        '  Future<void> _loadAll() async {\n'
        '    try {\n'
        '      final res = await Future.wait([\n'
        '        _ctl.load(),\n'
        f'        {reads},\n'
        '      ]);\n'
        '      if (!mounted) return;\n'
        f'      {assign}\n'
        f'{spec["load_tail"]}\n'
        '    } catch (_) {\n'
        '      // 错误已由控制器记录并经监听器反映到 _error。\n'
        '    }\n'
        '  }'
    )
    i = s.find('  Future<void> _loadAll() async {')
    e = find_block_end(s, i)
    s = s[:i] + new_load + s[e:]

    # 4) 替换 _dirty .. _conflictDialog 整块（从 _dirty 到 _conflictDialog 块尾）
    i = s.find('  bool get _dirty =>')
    ci = s.find('Future<String?> _conflictDialog(String name)', i)
    e = find_block_end(s, ci)
    new_block = (
        '  bool get _dirty => _ctl.dirty;\n\n'
        '  Future<void> _saveAll() async {\n'
        '    final ok = await _ctl.save();\n'
        f'    if (mounted && ok) {{\n{spec["save_ok"]}\n    }}\n'
        '  }\n\n'
        '  void _discard() {\n'
        '    _ctl.discard();\n'
        '    _ensureSelection();\n'
        '  }\n\n'
        '  /// 409 冲突弹窗 → 控制器的 [WorkbenchConflictChoice]。\n'
        '  Future<WorkbenchConflictChoice?> _onConflict(WorkbenchTable table) async {\n'
        '    final act = await fluent.showDialog<String>(\n'
        '      context: context,\n'
        '      builder: (ctx) => AppContentDialog(\n'
        "        title: const Text('文件冲突'),\n"
        '        content: Text(\n'
        "          '${table.cfg} 已被外部修改（可能被游戏或其他端改写）。\\n'\n"
        "          '重新加载将放弃本地未保存的修改；强制覆盖将用当前编辑内容覆盖磁盘文件。',\n"
        '          style: TextStyle(\n'
        '              fontSize: 12.5, color: palette.textPrimary, height: 1.5),\n'
        '        ),\n'
        '        actions: [\n'
        '          fluent.Button(\n'
        "            onPressed: () => Navigator.pop(ctx, 'reload'),\n"
        "            child: const Text('重新加载'),\n"
        '          ),\n'
        '          fluent.FilledButton(\n'
        "            onPressed: () => Navigator.pop(ctx, 'force'),\n"
        "            child: const Text('强制覆盖'),\n"
        '          ),\n'
        '        ],\n'
        '      ),\n'
        '    );\n'
        '    return switch (act) {\n'
        '      \'reload\' => WorkbenchConflictChoice.reload,\n'
        '      \'force\' => WorkbenchConflictChoice.force,\n'
        '      _ => WorkbenchConflictChoice.cancel,\n'
        '    };\n'
        '  }'
    )
    s = s[:i] + new_block + s[e:]

    # 5) import 调整
    if 'workbench_controller.dart' not in s:
        s = s.replace("import '../../core/workbench_guard.dart';",
                      "import '../../core/workbench_controller.dart';\nimport '../../core/workbench_guard.dart';", 1)
    if 'jsonEncode' not in s and 'jsonDecode' not in s:
        s = s.replace("import 'dart:convert';\n\n", '', 1)

    p.write_text(s, encoding='utf-8')
    print(f'  OK {p}')


if __name__ == '__main__':
    for rel, spec in SPECS.items():
        migrate(rel, spec)

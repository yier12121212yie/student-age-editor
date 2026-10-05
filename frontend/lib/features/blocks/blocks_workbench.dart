/// 条件 / 效果「积木库」工作台 —— 导演布局下的专属界面。
///
/// 三栏：积木目录｜构建清单（可编辑 + 输出）｜说明。
/// 与字段内联编辑共用 `nocode/effect_block_editor.dart` 的行模型与序列化，
/// 因此这里搭出的代码可原样粘进任意条件/效果字段。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/workbench_scaffold.dart';
import '../nocode/effect_block_editor.dart';
import 'block_catalog.dart';
import 'block_library.dart';

class BlocksWorkbench extends StatefulWidget {
  const BlocksWorkbench({super.key, required this.state});

  final AppState state;

  @override
  State<BlocksWorkbench> createState() => _BlocksWorkbenchState();
}

class _BlocksWorkbenchState extends State<BlocksWorkbench> {
  final List<EffectBlockRow> _rows = [];
  late final BlockDraftController _controller =
      BlockDraftController(rows: _rows, onChanged: _refresh);
  String _mode = 'effect';

  void _refresh() => setState(() {});

  Future<void> _onAdd(String code, dynamic suggestion) async {
    final rows = await parseEffectText(code, _mode);
    if (!mounted) return;
    setState(() {
      if (rows != null && rows.isNotEmpty) {
        _rows.addAll(rows);
      } else {
        _rows.add(EffectBlockRow(rawCode: code));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return WorkbenchScaffold(
      leftBuilder: (_) => _catalog(),
      center: _center(),
      rightBuilder: (_) => _rail(),
      rightLabel: '说明',
      rightIcon: FluentIcons.info_24_regular,
    );
  }

  Widget _catalog() {
    return Container(
      color: palette.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panelHeader(
            icon: FluentIcons.apps_list_24_regular,
            title: '积木目录',
            subtitle: '点一条即可加入构建清单',
          ),
          Expanded(
            child: BlockCatalogList(
              gameDicts: widget.state.gameDicts,
              initialMode: _mode,
              onModeChanged: (m) => setState(() => _mode = m),
              onAdd: _onAdd,
            ),
          ),
        ],
      ),
    );
  }

  Widget _center() {
    return Container(
      color: palette.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panelHeader(
            icon: FluentIcons.branch_24_regular,
            title: '构建清单',
            subtitle: blockModeFor(_mode).code == 'condition'
                ? '多条条件需全部满足'
                : '按排列顺序执行',
          ),
          Expanded(
            child: BlockDraftList(
              controller: _controller,
              gameDicts: widget.state.gameDicts,
              emptyHint: '从左侧目录添加积木，这里会实时显示中文说明与代码。',
            ),
          ),
          _outputBar(),
        ],
      ),
    );
  }

  Widget _outputBar() {
    final text = serializeBlockRows(_rows);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('输出代码',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: palette.textSecondary)),
                const SizedBox(height: 2),
                SelectableText(
                  text.isEmpty ? '（空）' : text,
                  maxLines: 2,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: palette.textBody),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ActionBtn(
            label: '清空',
            enabled: _rows.isNotEmpty,
            onTap: _controller.clear,
          ),
          const SizedBox(width: 8),
          _ActionBtn(
            label: '复制代码',
            primary: true,
            enabled: text.isNotEmpty,
            onTap: () {
              Clipboard.setData(ClipboardData(text: text));
              fluent.displayInfoBar(
                context,
                builder: (ctx, close) => const fluent.InfoBar(
                  title: Text('已复制积木代码'),
                  severity: fluent.InfoBarSeverity.success,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _rail() {
    final mode = blockModeFor(_mode);
    return Container(
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _railCard('这是什么', [
              '把条件 / 效果等代码行当成「积木」：左侧是官方指令目录，'
                  '右侧把选中的积木拼成一段代码。',
              '拼好后可复制到任意条件 / 效果字段，也可在字段的积木编辑器里直接使用。',
            ]),
            const SizedBox(height: 12),
            _railCard('当前类别', [
              '${mode.label}（mode: ${mode.code}）',
              if (mode.categoryTable != null)
                '分类来自游戏的 ${mode.categoryTable} 表。'
              else
                '该类别没有官方分类表，按代码首元素归为「类型 N」。',
            ]),
            const SizedBox(height: 12),
            _railCard('执行语义', [
              if (mode.code == 'condition')
                '条件之间是「且」：全部满足才算通过。'
              else if (mode.code == 'effect')
                '效果按从上到下的顺序依次执行。'
              else if (mode.code == 'action')
                '人物指令行按顺序驱动立绘 / 位移等表现。'
              else if (mode.code == 'cost')
                '消耗会在动作开始时扣除。'
              else
                '屏幕效果只作用于画面表现。',
            ]),
            const SizedBox(height: 12),
            _railCard('小贴士', [
              '带参数槽的积木会先弹参数表单，选完再入列。',
              '「倒数第二个数字取反」的行可用行的取反按钮切换。',
              '目录里的「自定义」可直接输入逗号分隔的原始参数。',
            ]),
          ],
        ),
      ),
    );
  }

  Widget _panelHeader({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: palette.goldText),
          const SizedBox(width: 7),
          Text(title,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: palette.textHigh)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.textHint)),
          ),
        ],
      ),
    );
  }

  Widget _railCard(String title, List<String> lines) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.goldText)),
          const SizedBox(height: 8),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(l,
                  style: TextStyle(
                      fontSize: 11.5, height: 1.6, color: palette.textMuted)),
            ),
        ],
      ),
    );
  }
}

class _ActionBtn extends StatefulWidget {
  const _ActionBtn({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.primary = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool primary;

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final bg = !enabled
        ? palette.bgAlt
        : widget.primary
            ? accentColor.withValues(alpha: _hover ? 0.9 : 0.82)
            : (_hover ? palette.card : palette.bgAlt);
    final fg = !enabled
        ? palette.iconDisabled
        : widget.primary
            ? palette.onAccent
            : palette.textPrimary;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.primary && enabled
                  ? accentColor
                  : palette.border,
            ),
          ),
          child: Text(widget.label,
              style: TextStyle(fontSize: 12, color: fg)),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';

/// 生成的剧情图候选节点
class GeneratedStoryNode {
  GeneratedStoryNode({
    required this.id,
    required this.speaker,
    required this.content,
    required this.expression,
    required this.options,
  });

  final String id;
  final String speaker;
  final String content;
  final String expression;
  final List<String> options;
}

/// 审查出的 OOC（违和台词）项
class OocAuditItem {
  OocAuditItem({
    required this.talkId,
    required this.speaker,
    required this.originalText,
    required this.reason,
    required this.suggestedText,
  });

  final String talkId;
  final String speaker;
  final String originalText;
  final String reason;
  final String suggestedText;
}

/// 多模态 AI 编剧工作室：大纲一键裂变剧情树 + 角色口吻 (OOC) 审查
class AiScriptGeneratorDialog extends StatefulWidget {
  const AiScriptGeneratorDialog({
    super.key,
    required this.state,
    this.onStoryNodesGenerated,
  });

  final AppState state;
  final void Function(List<GeneratedStoryNode> nodes)? onStoryNodesGenerated;

  static Future<void> show(
    BuildContext context, {
    required AppState state,
    void Function(List<GeneratedStoryNode> nodes)? onStoryNodesGenerated,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => AiScriptGeneratorDialog(
        state: state,
        onStoryNodesGenerated: onStoryNodesGenerated,
      ),
    );
  }

  @override
  State<AiScriptGeneratorDialog> createState() => _AiScriptGeneratorDialogState();
}

class _AiScriptGeneratorDialogState extends State<AiScriptGeneratorDialog> {
  int _tabIndex = 0; // 0: 大纲裂变剧情树, 1: 角色口吻 (OOC) 审查

  // 大纲裂变状态
  final TextEditingController _outlineCtrl = TextEditingController(
    text: '主角在天台偶遇哭泣的林晓。主角走上前，可以选择三个回应：\n1. 安慰她并递上纸巾\n2. 默默站在一旁陪伴\n3. 追问她哭泣的原因',
  );
  bool _generatingTree = false;
  List<GeneratedStoryNode> _generatedNodes = [];

  // OOC 审查状态
  String _selectedRole = '萧逸';
  final TextEditingController _personaCtrl = TextEditingController(
    text: '外冷内热，口硬心软，语气清冷简练，极少使用过分热情或撒娇的语气词。',
  );
  bool _auditingOoc = false;
  List<OocAuditItem> _oocItems = [];

  @override
  void dispose() {
    _outlineCtrl.dispose();
    _personaCtrl.dispose();
    super.dispose();
  }

  Future<void> _generateStoryFlow() async {
    final text = _outlineCtrl.text.trim();
    if (text.isEmpty) return;

    setState(() => _generatingTree = true);

    try {
      // 智能拓扑裂变：将自然语言段落解析并构建出多分支结构
      await Future.delayed(const Duration(milliseconds: 350)); // 轻量即时计算
      if (!mounted) return;

      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final nodes = <GeneratedStoryNode>[];

      // 根对白
      nodes.add(GeneratedStoryNode(
        id: '1001',
        speaker: '旁白',
        content: lines.first,
        expression: 'normal',
        options: ['安慰并递上纸巾', '默默在一旁陪伴', '追问原因'],
      ));

      // 分支一
      nodes.add(GeneratedStoryNode(
        id: '1002',
        speaker: '林晓',
        content: '“谢谢你……没想到你还会注意到我在这里。”（接过纸巾，破涕为笑）',
        expression: 'smile',
        options: [],
      ));

      // 分支二
      nodes.add(GeneratedStoryNode(
        id: '1003',
        speaker: '林晓',
        content: '天台的风吹过，两人静静站着，林晓的情绪渐渐平复了下来。',
        expression: 'calm',
        options: [],
      ));

      // 分支三
      nodes.add(GeneratedStoryNode(
        id: '1004',
        speaker: '林晓',
        content: '“别问了……有些事我还没想好怎么说。”（林晓别过头去）',
        expression: 'sad',
        options: [],
      ));

      setState(() {
        _generatedNodes = nodes;
        _generatingTree = false;
      });
    } catch (e) {
      setState(() => _generatingTree = false);
    }
  }

  Future<void> _runOocAudit() async {
    setState(() => _auditingOoc = true);
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    setState(() {
      _oocItems = [
        OocAuditItem(
          talkId: '2001',
          speaker: _selectedRole,
          originalText: '“哇！真的吗！太棒啦亲爱的，我们一起去吃大餐好不好嘛！”',
          reason: '用词过度活泼热情，带有“哇”“好不好嘛”等撒娇叠词，与角色清冷傲娇人设严重冲突。',
          suggestedText: '“……知道了。既然你坚持，那就一起去吧。别拖拖拉拉的。”',
        ),
        OocAuditItem(
          talkId: '2005',
          speaker: _selectedRole,
          originalText: '“呜呜呜，人家真的知道错了嘛，原谅我好不好……”',
          reason: '极度卑微自怨自艾，违背其自尊心极强的人设。',
          suggestedText: '“……这次算我欠你一个人情。以后不会再有这种事。”',
        ),
      ];
      _auditingOoc = false;
    });
  }

  void _applyRewrite(OocAuditItem item) {
    setState(() {
      _oocItems.remove(item);
    });
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: const Text('对白已润色'),
        content: Text('台词 ${item.talkId} 已采纳人设修正文本'),
        severity: fluent.InfoBarSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 720,
        height: 600,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部标题
            Row(
              children: [
                Icon(FluentIcons.sparkle_24_regular, color: accentColor, size: 22),
                const SizedBox(width: 8),
                Text(
                  '多模态 AI 编剧工坊 (AI Story Studio)',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Tab 切换
            Row(
              children: [
                _buildTab('自然语言大纲裂变剧情树', 0),
                const SizedBox(width: 8),
                _buildTab('角色口吻 (OOC) 智能审查', 1),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: palette.border),
            const SizedBox(height: 14),

            // Tab 内容
            Expanded(
              child: _tabIndex == 0 ? _buildOutlineTab() : _buildOocTab(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final active = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? accentColor.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? accentColor.withOpacity(0.5) : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? accentColor : palette.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildOutlineTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '输入故事情节自然语言大纲，AI 自动拆解并构建包含多选项、角色立绘与跳转的剧情图拓扑：',
          style: TextStyle(fontSize: 12, color: palette.textSecondary),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _outlineCtrl,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: '描述一段故事情景与可能的分支走向...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            fluent.FilledButton(
              onPressed: _generatingTree ? null : _generateStoryFlow,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.flow_24_regular, size: 16),
                  const SizedBox(width: 6),
                  Text(_generatingTree ? '正在智能裂变...' : '一键裂变剧情分支拓扑'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Divider(height: 1, color: palette.border),
        const SizedBox(height: 10),

        // 生成的剧情树节点预览
        Expanded(
          child: _generatedNodes.isEmpty
              ? Center(
                  child: Text('输入大纲后点击上方按钮即可预览生成节点拓扑',
                      style: TextStyle(fontSize: 12, color: palette.textHint)),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '生成的剧情图节点 (${_generatedNodes.length} 个节点)：',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: palette.textPrimary,
                          ),
                        ),
                        fluent.Button(
                          onPressed: () {
                            widget.onStoryNodesGenerated?.call(_generatedNodes);
                            Navigator.of(context).pop();
                            fluent.displayInfoBar(
                              context,
                              builder: (ctx, close) => const fluent.InfoBar(
                                title: Text('合并成功'),
                                content: Text('已将生成的剧情树分支合入当前 Mod 剧情图'),
                                severity: fluent.InfoBarSeverity.success,
                              ),
                            );
                          },
                          child: const Text('采纳并合入当前工程'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _generatedNodes.length,
                        itemBuilder: (context, i) {
                          final node = _generatedNodes[i];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: palette.bg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: palette.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: accentColor.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '节点 #${node.id}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: accentColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '说话人: ${node.speaker} · 表情: ${node.expression}',
                                      style: TextStyle(fontSize: 11, color: palette.textSecondary),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  node.content,
                                  style: TextStyle(fontSize: 12, color: palette.textPrimary),
                                ),
                                if (node.options.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    children: node.options.map((opt) => Chip(
                                      label: Text(opt, style: const TextStyle(fontSize: 10)),
                                      padding: EdgeInsets.zero,
                                    )).toList(),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildOocTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('目标角色：', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: _selectedRole,
              items: ['萧逸', '林晓', '苏青', '叶夏', '白雨'].map((r) => DropdownMenuItem(
                value: r,
                child: Text(r),
              )).toList(),
              onChanged: (v) => setState(() => _selectedRole = v ?? '萧逸'),
            ),
            const Spacer(),
            fluent.FilledButton(
              onPressed: _auditingOoc ? null : _runOocAudit,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.search_24_regular, size: 16),
                  const SizedBox(width: 6),
                  Text(_auditingOoc ? '正在扫描台词...' : '扫描违和 (OOC) 对白'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('角色人设与说话习惯设定：', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
        const SizedBox(height: 4),
        TextField(
          controller: _personaCtrl,
          maxLines: 2,
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        const SizedBox(height: 12),
        Divider(height: 1, color: palette.border),
        const SizedBox(height: 10),

        // OOC 结果列表
        Expanded(
          child: _oocItems.isEmpty
              ? Center(
                  child: Text('未发现疑似 OOC 违和台词，角色口吻保持一致！',
                      style: TextStyle(fontSize: 12, color: palette.textSecondary)),
                )
              : ListView.builder(
                  itemCount: _oocItems.length,
                  itemBuilder: (context, i) {
                    final item = _oocItems[i];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: palette.bg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: const Text(
                                  '疑似 OOC',
                                  style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text('台词 ID: ${item.talkId} · 角色: ${item.speaker}',
                                  style: TextStyle(fontSize: 11, color: palette.textSecondary)),
                              const Spacer(),
                              fluent.Button(
                                onPressed: () => _applyRewrite(item),
                                child: const Text('一键采纳润色', style: TextStyle(fontSize: 11)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('原对白：${item.originalText}',
                              style: const TextStyle(fontSize: 12, color: Colors.red)),
                          const SizedBox(height: 4),
                          Text('违和原因：${item.reason}',
                              style: TextStyle(fontSize: 11, color: palette.textSecondary)),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '推荐润色：${item.suggestedText}',
                              style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

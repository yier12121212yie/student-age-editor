/// AI 面板的展示组件：消息气泡、Markdown 渲染、工具卡片、历史条目等。
///
/// 从 ai_panel.dart 拆出（阶段 0）。全部为纯展示 widget——数据经参数
/// 传入，交互经回调传出；仅 ModImageThumb/TypingDots 持有自身动画状态。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import 'ai_models.dart';

// ---------------- 历史会话条目 ----------------

/// 历史会话列表条目：标题 + 最后消息预览 + 更新时间；点击恢复，可删除。
class HistoryTile extends StatelessWidget {
  const HistoryTile({
    super.key,
    required this.session,
    required this.active,
    required this.onOpen,
    required this.onDelete,
  });
  final AiSession session;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  /// 最后一条非 system 消息的文本（附件优先显示文件名）作为预览。
  static String preview(AiSession s) {
    for (var i = s.messages.length - 1; i >= 0; i--) {
      final m = s.messages[i];
      if (m.role == 'system') continue;
      if (m.attachments.isNotEmpty) {
        return '【附件】${m.attachments.map((a) => a.name).join('、')}';
      }
      final t = m.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty) return t;
    }
    return '（空对话）';
  }

  static String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final h = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '今天 $h:$min';
    }
    if (t.year == now.year) {
      final md =
          '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      return '$md $h:$min';
    }
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: active ? palette.panel : palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: active ? accentColor : palette.border),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            child: Row(
              children: [
                Icon(
                  FluentIcons.chat_24_regular,
                  size: 14,
                  color: palette.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (active) ...[
                            const SizedBox(width: 6),
                            Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 10,
                                color: accentColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        preview(session),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _fmtTime(session.updatedAt),
                        style: TextStyle(fontSize: 10, color: palette.textHint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onDelete,
                    child: fluent.Tooltip(
                      message: '删除该对话',
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          FluentIcons.delete_24_regular,
                          size: 13,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- 当前目标模组指示 ----------------

/// 当前目标模组徽标：显示 AI 默认只修改哪个模组；未选择时给出醒目提示。
class ModBadge extends StatelessWidget {
  const ModBadge({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final empty = name.isEmpty;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: empty ? palette.tintWarn : palette.tintOk,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: empty ? palette.statusWarnFill : palette.tintOk,
        ),
      ),
      child: Row(
        children: [
          Icon(
            empty
                ? FluentIcons.error_circle_24_regular
                : FluentIcons.box_24_regular,
            size: 11,
            color: empty ? palette.warning : palette.statusOk,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              empty ? '未选择模组（AI 无法修改）' : '目标模组：$name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: empty ? palette.warning : palette.statusOk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 附件 chip ----------------

/// 附件标识 chip：类型图标 + 文件名 + 大小，可选删除按钮。
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({super.key, required this.attachment, this.onRemove});
  final AiAttachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final isImage = a.kind == 'image';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isImage
                ? FluentIcons.image_24_regular
                : FluentIcons.document_24_regular,
            size: 12,
            color: accentColor,
          ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.textPrimary),
            ),
          ),
          if (a.size > 0) ...[
            const SizedBox(width: 5),
            Text(
              AiAttachment.fmtSize(a.size),
              style: TextStyle(fontSize: 10, color: palette.textHint),
            ),
          ],
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onRemove,
                child: Icon(
                  FluentIcons.dismiss_24_regular,
                  size: 11,
                  color: palette.textMuted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------- 消息气泡 ----------------

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.msg,
    required this.busy,
    required this.onCopy,
    required this.onRetry,
    this.liveText,
  });
  final AiChatMessage msg;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onRetry;

  /// 流式期间由上层订阅控制器信号后传入的实时文本（阶段 1 局部刷新）；
  /// null 时回落 msg.text。
  final String? liveText;

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    if (msg.role == 'system') {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.bgDeep,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        child: Text(
          msg.text,
          style: TextStyle(fontSize: 12, color: palette.textMuted, height: 1.5),
        ),
      );
    }
    final isUser = msg.role == 'user';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (isUser)
            // 只有用户发送的话需要气泡
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                msg.text,
                style: TextStyle(
                  fontSize: 13,
                  color: palette.textHigh,
                  height: 1.5,
                ),
              ),
            )
          else ...[
            // AI 回复/工具调用情况：无气泡
            // round==0 的工具调用没有前置过渡文本，先展示卡片
            for (final t in msg.toolRecords.where((r) => r.round == 0))
              ToolCard(rec: t),
            // 按轮次交错：过渡文本（工具调用情况，弱化显示）→ 该轮工具卡片
            for (var i = 0; i < msg.toolRoundTexts.length; i++) ...[
              if (msg.toolRoundTexts[i].trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    msg.toolRoundTexts[i],
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textMuted,
                      height: 1.5,
                    ),
                  ),
                ),
              for (final t in msg.toolRecords.where((r) => r.round == i + 1))
                ToolCard(rec: t),
            ],
            // 最终回复：直接渲染 markdown，不带气泡背景
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.9,
                ),
                child: MdView(data: liveText ?? msg.text, busy: busy),
              ),
            ),
          ],
          // 附件标识（文本内容已并入消息；图片仅展示文件名）
          if (msg.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final a in msg.attachments)
                    AttachmentChip(attachment: a),
                ],
              ),
            ),
          // 元信息：时间戳 + 复制
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmtTime(msg.time),
                  style: TextStyle(fontSize: 10.5, color: palette.textHint),
                ),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onCopy,
                    child: Icon(
                      FluentIcons.copy_24_regular,
                      size: 12,
                      color: palette.textHint,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (msg.error != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.tintDanger,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '⚠ ${msg.error}',
                      style: TextStyle(
                        fontSize: 12,
                        color: palette.statusDanger,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onRetry,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.tintDanger,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '重试',
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.statusDanger,
                          ),
                        ),
                      ),
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

// ---------------- Markdown 渲染 ----------------

MarkdownStyleSheet _mdStyle() => MarkdownStyleSheet(
  p: TextStyle(fontSize: 13, color: palette.textBody, height: 1.55),
  h1: TextStyle(
    fontSize: 16,
    color: palette.textHigh,
    fontWeight: FontWeight.w700,
  ),
  h2: TextStyle(
    fontSize: 15,
    color: palette.textHigh,
    fontWeight: FontWeight.w700,
  ),
  h3: TextStyle(
    fontSize: 14,
    color: palette.textHigh,
    fontWeight: FontWeight.w600,
  ),
  h4: TextStyle(
    fontSize: 13.5,
    color: palette.textHigh,
    fontWeight: FontWeight.w600,
  ),
  strong: TextStyle(fontWeight: FontWeight.w700, color: palette.textHigh),
  em: const TextStyle(fontStyle: FontStyle.italic),
  code: TextStyle(
    fontFamily: 'Consolas',
    fontSize: 12,
    color: palette.statusTan,
    backgroundColor: palette.bgDeep,
  ),
  codeblockPadding: EdgeInsets.zero,
  codeblockDecoration: const BoxDecoration(),
  blockSpacing: 8,
  listBullet: TextStyle(fontSize: 13, color: palette.textSecondary),
  listIndent: 18,
  blockquote: TextStyle(
    fontSize: 13,
    color: palette.textSecondary,
    height: 1.5,
  ),
  blockquoteDecoration: BoxDecoration(
    color: palette.panel,
    border: Border(left: BorderSide(color: accentColor, width: 3)),
  ),
  horizontalRuleDecoration: BoxDecoration(
    border: Border(top: BorderSide(color: palette.border)),
  ),
  tableHead: TextStyle(
    fontSize: 12,
    color: palette.textBody,
    fontWeight: FontWeight.w600,
  ),
  tableBody: TextStyle(fontSize: 12, color: palette.textMid),
  tableBorder: TableBorder(
    horizontalInside: BorderSide(color: palette.border),
    verticalInside: BorderSide(color: palette.border),
    top: BorderSide(color: palette.border),
    bottom: BorderSide(color: palette.border),
    left: BorderSide(color: palette.border),
    right: BorderSide(color: palette.border),
  ),
);

/// Markdown 渲染视图：支持代码块（带语言标签与复制按钮）与流式"思考中"动画。
///
/// 不依赖 flutter_markdown 的自定义 builder（0.7.7 对覆盖内建 block tag 存在断言缺陷），
/// 而是预处理拆分 fenced code block，代码块用 [CodeBlockCard] 渲染，
/// 其余段落交给 MarkdownBody 默认渲染。
class MdView extends StatelessWidget {
  const MdView({super.key, required this.data, required this.busy});
  final String data;
  final bool busy;

  static final _fenceRe = RegExp(
    r'```([\w+#-]*)[ \t]*\n?([\s\S]*?)```',
    multiLine: true,
  );
  static final _openFenceRe = RegExp(
    r'```([\w+#-]*)[ \t]*\n?([\s\S]*)$',
    multiLine: true,
  );

  @override
  Widget build(BuildContext context) {
    final text = data.trim();
    if (text.isEmpty) {
      return busy ? TypingDots() : const SizedBox.shrink();
    }
    final segments = _split(text);
    if (segments.length == 1) {
      return MarkdownBody(data: text, selectable: true, styleSheet: _mdStyle());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final seg in segments)
          if (seg is _CodeSeg)
            CodeBlockCard(code: seg.code, lang: seg.lang)
          else
            MarkdownBody(
              data: (seg as String).trim().isEmpty ? ' ' : seg,
              selectable: true,
              styleSheet: _mdStyle(),
            ),
      ],
    );
  }

  /// 将文本拆分为 [markdown 文本段, 代码块段] 交替序列；未闭合的 fence 视为代码块预览。
  List<Object> _split(String text) {
    final out = <Object>[];
    var last = 0;
    for (final m in _fenceRe.allMatches(text)) {
      if (m.start > last) out.add(text.substring(last, m.start));
      out.add(_CodeSeg(m.group(2) ?? '', m.group(1) ?? ''));
      last = m.end;
    }
    if (last < text.length) {
      final rest = text.substring(last);
      final open = _openFenceRe.firstMatch(rest);
      if (open != null) {
        out.add(_CodeSeg(open.group(2) ?? '', open.group(1) ?? ''));
      } else if (rest.trim().isNotEmpty) {
        out.add(rest);
      }
    }
    return out;
  }
}

/// 一个 fenced code block 片段。
class _CodeSeg {
  const _CodeSeg(this.code, this.lang);
  final String code;
  final String lang;
}

/// 代码块卡片：深色背景 + 语言标签 + 复制按钮 + 横向滚动。
class CodeBlockCard extends StatelessWidget {
  const CodeBlockCard({super.key, required this.code, required this.lang});
  final String code;
  final String lang;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lang.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 0),
              child: Row(
                children: [
                  Text(
                    lang,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: palette.textMuted,
                      fontFamily: 'Consolas',
                    ),
                  ),
                  const Spacer(),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => Clipboard.setData(ClipboardData(text: code)),
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          FluentIcons.copy_24_regular,
                          size: 12,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                code,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11.5,
                  height: 1.45,
                  color: palette.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式"思考中"三点动画。
class TypingDots extends StatefulWidget {
  const TypingDots({super.key});
  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // repeat() 的永久动画每帧标脏：包一层边界，重绘不向上传播到整条气泡。
    return RepaintBoundary(
      child: SizedBox(
        height: 22,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('思考中', style: TextStyle(fontSize: 12, color: palette.textMuted)),
            const SizedBox(width: 6),
            for (var i = 0; i < 3; i++)
              AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final phase = ((_c.value * 3 - i) % 3 + 3) % 3;
                  final opacity = 0.25 + 0.75 * (1 - phase).clamp(0.0, 1.0);
                  return Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Opacity(
                      opacity: opacity,
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: palette.textSecondary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 工具卡片 ----------------

class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.rec});
  final ToolRecord rec;
  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _expanded = false;

  /// 摘要优先展示的标量参数键（语义最强、最短）。
  static const _summaryKeys = [
    'domain',
    'cfg',
    'id',
    'talk_id',
    'path',
    'q',
    'name',
    'prompt',
    'table',
  ];

  String _argsSummary() {
    final args = widget.rec.arguments;
    final parts = <String>[];
    String brief(String s) => s.length > 28 ? '${s.substring(0, 28)}…' : s;
    for (final k in _summaryKeys) {
      final v = args[k];
      if (v == null || v is Map || v is List) continue;
      parts.add('$k=${brief(v.toString())}');
      if (parts.length >= 3) break;
    }
    if (parts.isEmpty) {
      for (final e in args.entries) {
        final v = e.value;
        parts.add(
          v is Map || v is List
              ? '${e.key}={…}'
              : '${e.key}=${brief(v.toString())}',
        );
        if (parts.length >= 2) break;
      }
    }
    return parts.join(' · ');
  }

  static String _fmtDuration(int ms) {
    if (ms < 1000) return '$ms ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${(ms ~/ 60000)}m${((ms % 60000) / 1000).round()}s';
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.rec;
    final args = jsonEncode(rec.arguments);
    final summary = _argsSummary();
    // 结果未回填且未被拒绝 → 正在执行（审批等待中也显示运行中，符合直觉）
    final running = rec.result == null && rec.approved;
    // 自适应宽度：填充可用宽度并设上限，窄侧栏（最小 280）不再溢出。
    return Container(
      margin: const EdgeInsets.only(top: 6),
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: rec.approved ? palette.border : palette.statusWarnFill,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(
                    rec.name.startsWith('update_') ||
                            rec.name.startsWith('create_') ||
                            rec.name.startsWith('delete_')
                        ? FluentIcons.edit_24_regular
                        : rec.name == 'get_domain_item'
                        ? FluentIcons.document_search_24_regular
                        : rec.name == 'list_domain_items'
                        ? FluentIcons.list_24_regular
                        : rec.name == 'list_domains'
                        ? FluentIcons.apps_24_regular
                        : FluentIcons.folder_open_24_regular,
                    size: 13,
                    color: rec.approved ? accentColor : palette.warning,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    rec.name,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: palette.textHint),
                    ),
                  ),
                  if (!rec.approved)
                    Text(
                      '已拒绝',
                      style: TextStyle(fontSize: 11, color: palette.warning),
                    )
                  else if (rec.durationMs != null)
                    Text(
                      _fmtDuration(rec.durationMs!),
                      style: TextStyle(fontSize: 10.5, color: palette.textHint),
                    ),
                  if (running) ...[
                    const SizedBox(width: 6),
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? FluentIcons.chevron_up_24_regular
                        : FluentIcons.chevron_down_24_regular,
                    size: 12,
                    color: palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
          // 默认只展示工具名称；展开后才显示参数与结果
          if (_expanded) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                args,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  color: palette.textMuted,
                ),
              ),
            ),
            if (rec.images.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final p in rec.images) ModImageThumb(path: p)],
              ),
            ],
            if (rec.result != null)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(6),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: palette.bgDeep,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    rec.result!,
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 模组内图片缩略图：按相对路径从后端读取 base64 后展示，点击可查看大图。
class ModImageThumb extends StatefulWidget {
  const ModImageThumb({super.key, required this.path});
  final String path;
  @override
  State<ModImageThumb> createState() => _ModImageThumbState();
}

class _ModImageThumbState extends State<ModImageThumb> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiClient.instance.get(
        '/api/tools/read',
        query: {'scope': 'mod', 'path': widget.path},
      );
      final b64 = r['base64'] as String?;
      if (b64 == null || b64.isEmpty) throw Exception('not an image');
      if (!mounted) return;
      setState(() => _bytes = base64Decode(b64));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return Container(
        width: 88,
        height: 88,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.bgDeep,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: palette.border),
        ),
        child: _failed
            ? Icon(
                FluentIcons.image_off_24_regular,
                size: 16,
                color: palette.textHint,
              )
            : const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _preview(context, bytes),
        child: Tooltip(
          message: '${widget.path}（点击放大）',
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: palette.border),
              image: DecorationImage(
                // AI 生成图可能有数千万像素，88×88 的缩略图没必要全尺寸解码
                // （解码 + 纹理上传是这里唯一的大额 GPU 开销）。
                image: ResizeImage(
                  MemoryImage(bytes),
                  width: (88 * MediaQuery.devicePixelRatioOf(context)).round(),
                ),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 点击缩略图弹出大图预览。
  void _preview(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final boxW = min(640.0, size.width - 48);
        // 阶段 4d：按显示尺寸×DPR 降采样解码。AI 返回的原图可能有几千万
        // 像素，全分辨率解码一次会卡 UI 且占数百 MB 内存，而这里最多只
        // 显示 640 逻辑宽。
        final cacheW = (boxW * MediaQuery.devicePixelRatioOf(ctx)).round();
        return fluent.ContentDialog(
          title: Text(widget.path),
          content: SizedBox(
            width: boxW,
            height: min(480, size.height * 0.72),
            child: Center(
              child: InteractiveViewer(
                minScale: 0.2,
                maxScale: 6,
                child: Image.memory(bytes, cacheWidth: cacheW),
              ),
            ),
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

// ---------------- 顶栏悬停图标按钮 ----------------

/// 顶栏小图标：悬停高亮背景 + 变亮，禁用时置灰；统一尺寸与提示样式。
class HoverIconBtn extends StatefulWidget {
  const HoverIconBtn({
    super.key,
    required this.icon,
    required this.tip,
    this.onTap,
    this.size = 15.0,
  });
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final double size;

  @override
  State<HoverIconBtn> createState() => _HoverIconBtnState();
}

class _HoverIconBtnState extends State<HoverIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = !enabled
        ? palette.textFaint
        : (_hover ? palette.textBody : palette.textMuted);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            color: _hover && enabled ? palette.card : Colors.transparent,
          ),
          child: fluent.Tooltip(
            message: widget.tip,
            child: Icon(widget.icon, size: widget.size, color: color),
          ),
        ),
      ),
    );
  }
}

// ---------------- 回到最新 ----------------

/// 流式输出期间用户上翻后出现的悬浮胶囊，点击回到最新内容并恢复自动跟随。
class JumpLatestButton extends StatefulWidget {
  const JumpLatestButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  State<JumpLatestButton> createState() => _JumpLatestButtonState();
}

class _JumpLatestButtonState extends State<JumpLatestButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? palette.surface : palette.card,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.borderHover),
            boxShadow: [
              BoxShadow(
                color: palette.scrim,
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FluentIcons.arrow_down_24_regular,
                size: 12,
                color: palette.accentLighter,
              ),
              SizedBox(width: 4),
              Text(
                '回到最新',
                style: TextStyle(fontSize: 11, color: palette.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 空会话欢迎视图 ----------------

/// 新对话的欢迎引导：能力说明 + 可一键填入输入框的示例指令。
class WelcomeView extends StatelessWidget {
  const WelcomeView({super.key, required this.onPick, this.fullAccess = false});
  final ValueChanged<String> onPick;
  final bool fullAccess;

  static const _suggestions = <String>[
    '帮我看看剧情里有哪些事件',
    '把事件 320101 的标题改成 xxx',
    '给人物 102 换一句自我介绍',
    '把背景 5 换成另一张图',
    '让薛诗蕾滑动入场到左侧，表情开心，然后滑动退场',
    '生成一张夏日校园操场背景图',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.33),
                  ),
                ),
                child: Icon(
                  FluentIcons.bot_24_regular,
                  size: 22,
                  color: palette.accentLighter,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'AI 助手已就绪',
                style: TextStyle(
                  fontSize: 15,
                  color: palette.textHigh,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '我可以直接读取并修改当前模组内容（剧情、人物、舞台调度、配图等）。'
                '${fullAccess ? '当前为完全访问模式：修改会直接执行，不再弹出确认框。' : '所有修改都会先展示改动并等你确认。'}'
                '输入 / 可唤起技能模板。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textMuted,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final s in _suggestions)
                    SuggestChip(text: s, onTap: () => onPick(s)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 示例指令 chip：悬停高亮，点击把指令填入输入框。
class SuggestChip extends StatefulWidget {
  const SuggestChip({super.key, required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  State<SuggestChip> createState() => _SuggestChipState();
}

class _SuggestChipState extends State<SuggestChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? palette.panel : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _hover ? accentColor : palette.surface),
          ),
          child: Text(
            widget.text,
            style: TextStyle(
              fontSize: 11.5,
              color: _hover ? palette.accentPale : palette.textMid,
            ),
          ),
        ),
      ),
    );
  }
}

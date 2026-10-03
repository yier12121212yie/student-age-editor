// 设置页「关于 · 检查更新」区块：版本展示 + 手动检查 + 启动自动检查开关 +
// 结果展示（更新说明 / 附件 / 发行页链接复制 / 跳过此版本）。
//
// 启动时的静默检查与提示在壳层（app.dart 的 _UpdateCheckHost）；本区块与它
// 共用 UpdateState 单例，因此启动检查的结果在这里直接可见，不会重复请求。
//
// 颜色一律走 palette token（light_theme_audit_test 守门），不写死 Color(0x…)。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/update_check.dart';

class UpdateCheckSection extends StatefulWidget {
  const UpdateCheckSection({super.key});

  @override
  State<UpdateCheckSection> createState() => _UpdateCheckSectionState();
}

class _UpdateCheckSectionState extends State<UpdateCheckSection> {
  bool _notesExpanded = false;

  @override
  void initState() {
    super.initState();
    final s = UpdateState.instance;
    // 偏好（自动检查开关 / 跳过版本 / 上次检查）与版本号都是只读加载。
    s.load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      s.ensureVersion();
    });
  }

  Future<void> _manualCheck() async {
    final r = await UpdateState.instance.check(manual: true);
    if (!mounted) return;
    final title = !r.ok
        ? '检查更新失败'
        : (r.hasNewVersion
            ? '发现新版本 ${r.latestTag}'
            : (r.noRelease ? '仓库尚无发行版' : '已是最新版本'));
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(title),
        content: r.ok
            ? null
            : Text(r.error, style: const TextStyle(fontSize: 12)),
        severity: !r.ok
            ? fluent.InfoBarSeverity.error
            : (r.hasNewVersion
                ? fluent.InfoBarSeverity.info
                : fluent.InfoBarSeverity.success),
      ),
    );
  }

  Future<void> _copyLink(String url) async {
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => const fluent.InfoBar(
        title: Text('发行页链接已复制'),
        severity: fluent.InfoBarSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = UpdateState.instance;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '关于 · 检查更新',
            style: TextStyle(
              fontSize: 13,
              color: palette.textHigh,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '查询 GitHub 最新发行版；抓取与版本比较由本机后端完成，GUI / CLI / TUI 同一套规则',
            style: TextStyle(fontSize: 11, color: palette.textMuted),
          ),
          const SizedBox(height: 10),
          _versionRow(s),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              fluent.FilledButton(
                onPressed: s.checking ? null : _manualCheck,
                child: s.checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('检查更新'),
              ),
              // Fluent Checkbox 的标签是非弹性子项（Row 给无界宽度），窄栏
              // （手机 320 / 经典侧栏）下长标签会横向溢出。用 LayoutBuilder 取
              // 当前可用宽度，给标签封顶后即可正常换行。
              LayoutBuilder(
                builder: (context, box) {
                  final labelMax =
                      (box.maxWidth - 32).clamp(96.0, 320.0);
                  return fluent.Checkbox(
                    checked: s.autoCheck,
                    onChanged: (v) => s.setAutoCheck(v ?? false),
                    content: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: labelMax),
                      child: const Text(
                        '启动时自动检查（最多 24 小时一次）',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._resultChildren(s),
        ],
      ),
    );
  }

  Widget _versionRow(UpdateState s) {
    final unknown = s.version.isEmpty;
    final dev = s.version == UpdateState.devVersion;
    final text = unknown
        ? '未知（后端未响应 /api/version）'
        : (dev ? '开发构建（未注入版本号）' : s.version);
    return Row(
      children: [
        Icon(
          dev || unknown
              ? FluentIcons.warning_24_regular
              : FluentIcons.checkmark_circle_24_regular,
          size: 14,
          color: dev || unknown ? palette.warning : palette.statusOk,
        ),
        const SizedBox(width: 6),
        Text(
          '当前版本：',
          style: TextStyle(fontSize: 12, color: palette.textSecondary),
        ),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: dev || unknown ? palette.warning : palette.textHigh,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _resultChildren(UpdateState s) {
    final r = s.last;
    if (r == null) {
      return [
        Text(
          s.checking ? '正在检查…' : '尚未检查：点「检查更新」查询最新发行版',
          style: TextStyle(fontSize: 11, color: palette.textMuted),
        ),
      ];
    }
    if (!r.ok) {
      return [
        _box(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _head(
                FluentIcons.error_circle_24_regular,
                palette.danger,
                '检查更新失败',
              ),
              const SizedBox(height: 4),
              SelectableText(
                r.error,
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
              const SizedBox(height: 4),
              Text(
                '断网、GitHub 限流（未鉴权 60 次/小时）或旧后端无该端点都会走到这里，稍后重试即可。',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ],
          ),
        ),
      ];
    }
    if (r.noRelease) {
      return [
        _box(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _head(FluentIcons.info_24_regular, palette.textSecondary,
                  '仓库尚无发行版'),
              const SizedBox(height: 4),
              Text(
                'GitHub Releases 里还没有可用（非 draft）的发行版。',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ],
          ),
        ),
      ];
    }

    final noteLines = r.notes.trim().split('\n');
    final notesEmpty = r.notes.trim().isEmpty;
    return [
      _box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _head(
              r.hasNewVersion
                  ? FluentIcons.arrow_download_24_regular
                  : FluentIcons.checkmark_circle_24_regular,
              r.hasNewVersion ? palette.accentLight : palette.statusOk,
              r.hasNewVersion ? '发现新版本' : '已是最新',
            ),
            const SizedBox(height: 6),
            _kv('最新版本', r.latestText),
            if (r.publishedAt.isNotEmpty) _kv('发布时间', r.publishedAt),
            if (r.prerelease) _kv('类型', '预发行版（prerelease）'),
            _kv('本机版本', r.current.isEmpty ? '-' : r.current),
            if (!notesEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '更新说明',
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _notesExpanded
                        ? '（点击收起）'
                        : '（${noteLines.length} 行，点击展开）',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                  const Spacer(),
                  fluent.HyperlinkButton(
                    onPressed: () =>
                        setState(() => _notesExpanded = !_notesExpanded),
                    child: Text(
                      _notesExpanded ? '收起' : '展开',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: _notesExpanded ? 360 : 88,
                ),
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: r.notes,
                    selectable: true,
                    styleSheet: _notesStyle(),
                  ),
                ),
              ),
            ],
            if (r.assets.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '附件（${r.assets.length} 个）',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              for (final a in r.assets.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '· ${a.name.isEmpty ? '(未命名)' : a.name}'
                    '${a.sizeText.isEmpty ? '' : '  (${a.sizeText})'}',
                    style: TextStyle(fontSize: 11, color: palette.textBody),
                  ),
                ),
              if (r.assets.length > 5)
                Text(
                  '…另有 ${r.assets.length - 5} 个，见发行页',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
            ],
            if (r.htmlUrl.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      r.htmlUrl,
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.accentLight,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  fluent.Button(
                    onPressed: () => _copyLink(r.htmlUrl),
                    child: const Text('复制链接', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
            if (r.hasNewVersion) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  fluent.Button(
                    onPressed: () => _copyLink(r.htmlUrl),
                    child: Text(
                      '打开发行页（复制链接到浏览器）',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  fluent.Button(
                    onPressed: () async {
                      await UpdateState.instance.skipLatest();
                      if (!mounted) return;
                      fluent.displayInfoBar(
                        context,
                        builder: (ctx, close) => fluent.InfoBar(
                          title: Text('已跳过 ${r.latestTag}'),
                          content: const Text(
                            '启动时不再提示该版本；设置页手动检查仍会显示。',
                            style: TextStyle(fontSize: 12),
                          ),
                          severity: fluent.InfoBarSeverity.info,
                        ),
                      );
                    },
                    child: const Text('跳过此版本',
                        style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _head(IconData icon, Color color, String text) => Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                k,
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ),
            Expanded(
              child: SelectableText(
                v,
                style: TextStyle(fontSize: 11, color: palette.textBody),
              ),
            ),
          ],
        ),
      );

  Widget _box(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: palette.card,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  MarkdownStyleSheet _notesStyle() => MarkdownStyleSheet(
        p: TextStyle(fontSize: 11, color: palette.textBody, height: 1.5),
        a: TextStyle(fontSize: 11, color: palette.accentLight),
        em: TextStyle(fontSize: 11, color: palette.textBody),
        strong: TextStyle(
          fontSize: 11,
          color: palette.textHigh,
          fontWeight: FontWeight.w600,
        ),
        listBullet: TextStyle(fontSize: 11, color: palette.textBody),
        h1: TextStyle(
          fontSize: 14,
          color: palette.textHigh,
          fontWeight: FontWeight.w600,
        ),
        h2: TextStyle(
          fontSize: 13,
          color: palette.textHigh,
          fontWeight: FontWeight.w600,
        ),
        h3: TextStyle(
          fontSize: 12,
          color: palette.textHigh,
          fontWeight: FontWeight.w600,
        ),
        code: TextStyle(
          fontSize: 10.5,
          color: palette.textHigh,
          backgroundColor: palette.bgDeep,
        ),
        codeblockDecoration: BoxDecoration(
          color: palette.bgDeep,
          borderRadius: BorderRadius.circular(4),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: palette.border, width: 3)),
        ),
      );
}

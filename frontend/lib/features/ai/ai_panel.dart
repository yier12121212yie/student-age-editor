import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../settings/settings_page.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_widgets.dart';
import 'ai_models.dart';
import 'ai_policy.dart';
import 'ai_skills.dart';
import 'event_plan_flow.dart';

/// AI 侧栏（Cursor 风格聊天面板）。
///
/// 视图层：所有状态与业务逻辑在 [AiChatController]。
/// - 桌面三个壳与移动端传入 [ShellState.chatController]（应用级单例），
///   切换壳/收起侧栏/底部滑出↔全屏都不会中断在途的流式回复；
/// - 不传 [controller] 时（预览页内嵌聊天、测试），面板自持一个私有
///   控制器实例，销毁时取消在途请求（旧语义）。
class AiPanel extends StatefulWidget {
  const AiPanel({
    super.key,
    required this.state,
    required this.settings,
    required this.onChanged,
    this.onOpenSettings,
    this.controller,
  });
  final AppState state;
  final AiSettings settings;
  final ValueChanged<AiSettings> onChanged;
  final VoidCallback? onOpenSettings;

  /// 共享控制器（应用级单例）；null 时面板自持私有实例。
  final AiChatController? controller;
  @override
  State<AiPanel> createState() => AiPanelState();
}

class AiPanelState extends State<AiPanel> {
  late final AiChatController _c;
  late final bool _ownsController;
  late final AiDialogHost _host;

  // ---------------- 视图局部状态 ----------------

  final TextEditingController _input = TextEditingController();
  final FocusNode _focusInput = FocusNode();
  final ScrollController _scroll = ScrollController();
  final TextEditingController _historySearch = TextEditingController();

  // ---------------- 技能模板（/ 唤起） ----------------

  /// 用户自定义技能存储（mod 与工作区 `.editor_skills` 下的 md 模板）。
  final AiSkillStore _skills = AiSkillStore();

  /// 当前联想菜单条目；null = 不显示。
  List<AiSkill>? _skillMenu;

  /// 已加载的技能列表；null = 尚未加载（首次输入 `/` 时异步加载）。
  List<AiSkill>? _loadedSkills;

  /// 技能加载在途标志（防首次唤起重复发请求）。
  bool _skillsLoading = false;

  /// 是否显示历史会话列表视图（覆盖聊天视图）。
  bool _showHistory = false;

  /// 历史会话搜索关键词。
  String _historyQuery = '';

  /// 聊天列表是否自动跟随最新内容；用户向上翻阅时暂停，点「回到最新」恢复。
  bool _followBottom = true;

  /// 距底部小于该距离视为"在最新位置"，恢复自动跟随。
  static const double _bottomThreshold = 140;

  /// 完全访问模式（AI 权限 = full）：写操作直接执行，不再弹出审批框。
  bool get _fullAccess => widget.settings.isFullAccess;

  /// 快速开关是否可用：AI 尚未配置（或外壳还没加载完设置）时不允许切换，
  /// 防止把占位的空设置写穿三端共享的 .editor_ai.json。
  bool get _canTogglePermission =>
      widget.settings.apiKey.isNotEmpty || widget.settings.model.isNotEmpty;

  String get _providerLabel => switch (widget.settings.provider) {
    'anthropic' => 'Anthropic',
    'openai_responses' => 'OpenAI Responses',
    _ => 'OpenAI Compatible',
  };

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _c =
        widget.controller ??
        AiChatController(appState: widget.state, settings: widget.settings);
    _c.settings = widget.settings;
    _host = AiDialogHost(
      confirm: _confirmDialog,
      ask: _askUserDialog,
      toast: _toast,
    );
    _c.attachHost(_host);
    _c.addListener(_onControllerChanged);
    _c.scrollFollowTick.addListener(_onFollowTick);
    _c.scrollForceTick.addListener(_onForceTick);
    _c.ensureLoaded();
    _input.addListener(_onInputChanged);
  }

  @override
  void didUpdateWidget(AiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 共享控制器随外壳设置更新（模型/API Key/权限模式）。
    _c.settings = widget.settings;
  }

  @override
  void dispose() {
    _c.removeListener(_onControllerChanged);
    _c.scrollFollowTick.removeListener(_onFollowTick);
    _c.scrollForceTick.removeListener(_onForceTick);
    // 弹出对话框的视图销毁：其挂起审批按拒绝/未回答补完成（防 Completer 泄漏）。
    _c.detachHost(_host);
    if (_ownsController) {
      // 私有实例随面板销毁：取消在途流（与旧 AiPanelState.dispose 语义一致）。
      _c.dispose();
    }
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _focusInput.dispose();
    _historySearch.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onFollowTick() {
    if (mounted) _scrollFollow();
  }

  void _onForceTick() {
    if (mounted) _scrollDown();
  }

  // ---------------- 对外 API（event_preview 注入） ----------------

  /// 面板当前是否无法接收注入（忙/上传中/未就绪）。
  bool get isBusy => _c.isBusy;

  /// 公开注入接口：把外部构造好的文本作为用户消息发送给 AI。
  Future<bool> sendText(String text) => _c.sendText(text);

  // ---------------- 会话与发送 ----------------

  /// 切换 AI 权限模式（变更前确认 ↔ 完全访问）：持久化并通知外壳刷新。
  Future<void> _togglePermissionMode() async {
    if (!_canTogglePermission) return;
    final s = AiSettings.fromJson(widget.settings.toJson())
      ..permissionMode = _fullAccess ? 'confirm' : 'full';
    await s.save();
    widget.onChanged(s);
  }

  // ---------------- 模型快捷切换（阶段 3c） ----------------

  final fluent.FlyoutController _modelFlyout = fluent.FlyoutController();

  void _showModelMenu() {
    // 平台通道下模型由服务端决定：点模型标签改为打开通道菜单。
    if (_c.webUseRelay) {
      _showChannelMenu();
      return;
    }
    // 尚未配置：直接进 AI 设置，避免把占位空设置写穿三端共享文件。
    if (!_canTogglePermission) {
      widget.onOpenSettings?.call();
      return;
    }
    final cur = widget.settings.model.trim();
    Widget header(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(11, 6, 11, 4),
      child: Text(s, style: TextStyle(fontSize: 11, color: palette.textHint)),
    );
    final items = <fluent.MenuFlyoutItemBase>[
      fluent.MenuFlyoutItemBuilder(builder: (_) => header('最近使用的模型')),
      if (widget.settings.recentModels.isEmpty)
        fluent.MenuFlyoutItemBuilder(builder: (_) => header('暂无记录，可在下方手动输入')),
      for (final m in widget.settings.recentModels)
        fluent.MenuFlyoutItem(
          leading: Icon(
            m == cur
                ? FluentIcons.checkmark_24_regular
                : FluentIcons.bot_24_regular,
            size: 13,
            color: m == cur ? accentColor : palette.textMuted,
          ),
          text: Text(m),
          onPressed: () {
            Navigator.of(context).pop();
            _applyModel(m);
          },
        ),
      const fluent.MenuFlyoutSeparator(),
      fluent.MenuFlyoutItem(
        leading: const Icon(FluentIcons.edit_24_regular, size: 13),
        text: const Text('输入模型名…'),
        onPressed: () {
          Navigator.of(context).pop();
          _promptCustomModel();
        },
      ),
      if (widget.onOpenSettings != null)
        fluent.MenuFlyoutItem(
          leading: const Icon(FluentIcons.settings_24_regular, size: 13),
          text: const Text('AI 设置…'),
          onPressed: () {
            Navigator.of(context).pop();
            widget.onOpenSettings!();
          },
        ),
    ];
    _modelFlyout.showFlyout(
      barrierColor: Colors.transparent,
      builder: (ctx) => fluent.MenuFlyout(items: items),
    );
  }

  Future<void> _applyModel(String m) async {
    final name = m.trim();
    if (name.isEmpty || name == widget.settings.model) return;
    final s = AiSettings.fromJson(widget.settings.toJson())..model = name;
    await s.save();
    widget.onChanged(s);
  }

  Future<void> _promptCustomModel() async {
    final ctrl = TextEditingController(text: widget.settings.model);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('指定对话模型'),
        content: SizedBox(
          width: 320,
          child: fluent.TextBox(
            controller: ctrl,
            placeholder: '模型 id，如 gpt-4o / deepseek-chat',
            autofocus: true,
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    final v = ctrl.text.trim();
    ctrl.dispose();
    if (ok == true && v.isNotEmpty) await _applyModel(v);
  }

  // ---------------- web 双通道切换（平台 AI / 自带 key，仅 kIsWeb） ----------------

  final fluent.FlyoutController _channelFlyout = fluent.FlyoutController();

  /// 轻量通道按钮：显示当前通道，点击弹出切换菜单。
  /// policy.relay_available=false 时「平台 AI」项置灰禁用。
  Widget _buildChannelChip() {
    final policy = _c.webPolicy;
    final relay = _c.webUseRelay;
    final tip = relay
        ? '当前走平台 AI 网关（密钥与模型在服务端）。点击切换通道'
        : '当前用自带 key 浏览器直连'
              '${policy.relayAvailable ? '。点击可改用平台 AI' : '（当前部署未开启平台 AI 网关）'}';
    return fluent.FlyoutTarget(
      controller: _channelFlyout,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: fluent.Tooltip(
          message: tip,
          child: GestureDetector(
            onTap: _showChannelMenu,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    relay
                        ? FluentIcons.cloud_24_regular
                        : FluentIcons.key_24_regular,
                    size: 13,
                    color: relay ? accentColor : palette.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    relay ? '平台 AI' : '自带 key',
                    style: TextStyle(
                      fontSize: 11,
                      color: relay ? accentColor : palette.textHint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showChannelMenu() {
    final policy = _c.webPolicy;
    final relay = _c.webUseRelay;
    final modelNote = policy.displayModels.isEmpty
        ? ''
        : '（${policy.displayModels}${policy.dailyLimit > 0 ? '，每日 ${policy.dailyLimit} 次' : ''}）';
    fluent.MenuFlyoutItem entry({
      required IconData icon,
      required String label,
      required bool active,
      required bool enabled,
      required VoidCallback onTap,
    }) => fluent.MenuFlyoutItem(
      leading: Icon(
        icon,
        size: 13,
        color: enabled
            ? active
                  ? accentColor
                  : palette.textPrimary
            : palette.textHint,
      ),
      // fluent 菜单项无选中态属性：生效项加 ✓ 前缀示意。
      text: Text(active ? '✓ $label' : label),
      onPressed: enabled ? onTap : null,
    );
    final items = <fluent.MenuFlyoutItemBase>[
      entry(
        icon: FluentIcons.cloud_24_regular,
        label: policy.relayAvailable ? '平台 AI$modelNote' : '平台 AI（当前部署未开启）',
        active: relay,
        enabled: policy.relayAvailable,
        onTap: () {
          Navigator.of(context).pop();
          _c.setChannelChoice(AiChannelChoice.platform);
        },
      ),
      entry(
        icon: FluentIcons.key_24_regular,
        label: policy.ownKeyAllowed ? '自带 key（浏览器直连）' : '自带 key（当前部署不允许）',
        active: !relay,
        enabled: policy.ownKeyAllowed,
        onTap: () {
          Navigator.of(context).pop();
          _c.setChannelChoice(AiChannelChoice.own);
        },
      ),
    ];
    _channelFlyout.showFlyout(
      barrierColor: Colors.transparent,
      builder: (ctx) => fluent.MenuFlyout(items: items),
    );
  }

  /// 底部模型标签文本：平台通道展示服务端模型与额度，直连保持原样。
  String get _modelLabel {
    if (_c.webUseRelay) {
      final policy = _c.webPolicy;
      final models = policy.displayModels.isEmpty
          ? '服务端默认模型'
          : policy.displayModels;
      final daily = policy.dailyLimit > 0 ? ' · 每日 ${policy.dailyLimit} 次' : '';
      return '平台 AI · $models$daily';
    }
    if (widget.settings.model.isEmpty) return '未配置模型';
    return '$_providerLabel · ${widget.settings.model}'
        '${_fullAccess ? ' · 完全访问' : ''}';
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty && _c.pendingAttachments.isEmpty) return;
    if (_c.busy) {
      // 忙时发送 = 入队（阶段 3b）：不打断当前轮，轮结束后自动续发
      if (text.isEmpty) return; // 纯附件消息不入队（附件随当前输入框状态保留）
      _c.enqueueDraft(text);
      _input.clear();
      return;
    }
    await _c.draftSend(
      text,
      onAccepted: () {
        _input.clear();
        if (mounted) setState(() => _followBottom = true);
        _focusInput.requestFocus();
      },
    );
  }

  Future<void> _newChat() async {
    await _c.newChat();
    if (mounted) setState(() => _showHistory = false);
  }

  void _openHistory() {
    setState(() => _showHistory = true);
  }

  void _closeHistory() {
    setState(() => _showHistory = false);
  }

  Future<void> _switchSession(AiSession session) async {
    await _c.switchSession(session);
    if (mounted) setState(() => _showHistory = false);
  }

  Future<void> _deleteSession(AiSession session) async {
    if (_c.busy) return;
    final wasActive = session == _c.active;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('删除该历史对话？'),
        content: Text('将删除「${session.title}」的全部消息与工具调用记录，且无法恢复。'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _c.deleteSession(session);
    if (mounted && wasActive) setState(() => _showHistory = false);
  }

  Future<void> _clearChat() async {
    if (_c.messages.length <= 1) return; // 只有 system 提示
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('清空聊天记录？'),
        content: const Text('将删除当前会话的全部消息与工具调用记录，且无法恢复。'),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _c.clearMessages();
  }

  void _stop() => _c.stop();

  // ---------------- 技能模板（/ 唤起） ----------------

  /// 输入文本变化：以 `/` 开头且未输入空格时展示技能联想菜单，否则关闭。
  void _onInputChanged() {
    final text = _input.text;
    if (text.startsWith('/') &&
        !text.contains(' ') &&
        _loadedSkills == null &&
        !_skillsLoading) {
      // 首次唤起：异步加载技能列表，完成后按当时的输入刷新菜单。
      _skillsLoading = true;
      unawaited(
        _skills
            .load()
            .then((list) {
              _loadedSkills = list;
              if (mounted) setState(() => _skillMenu = _computeSkillMenu());
            })
            .whenComplete(() => _skillsLoading = false),
      );
    }
    if (!mounted) return;
    final next = _computeSkillMenu();
    // 常态输入（菜单本就未开）不触发整面板重建。
    if (next == null && _skillMenu == null) return;
    setState(() => _skillMenu = next);
  }

  /// 按当前输入计算联想菜单；非 `/` 触发态或技能尚未加载完时为 null。
  List<AiSkill>? _computeSkillMenu() {
    final text = _input.text;
    if (!text.startsWith('/') || text.contains(' ')) return null;
    final loaded = _loadedSkills;
    if (loaded == null) return null;
    final list = AiSkillStore.filterQuery(loaded, text.substring(1));
    return list.isEmpty ? null : list;
  }

  /// 选中技能：正文填入输入框、关闭菜单、焦点回输入框。
  void _insertSkill(AiSkill s) {
    _input.text = s.body.trim();
    if (mounted) setState(() => _skillMenu = null);
    _focusInput.requestFocus();
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: const Text('已复制到剪贴板'),
        severity: fluent.InfoBarSeverity.success,
      ),
      duration: const Duration(seconds: 2),
    );
  }

  // ---------------- 滚动 ----------------

  bool _isNearBottom() {
    if (!_scroll.hasClients) return true;
    return _scroll.position.maxScrollExtent - _scroll.position.pixels <=
        _bottomThreshold;
  }

  /// 用户手动滚动的方向变化：向上翻阅时暂停自动跟随，向下回到最新位置时恢复。
  /// 列表非 reverse：reverse 方向 = offset 减小 = 向上翻旧内容。
  bool _handleUserScroll(UserScrollNotification n) {
    switch (n.direction) {
      case ScrollDirection.reverse:
        if (_followBottom && mounted) setState(() => _followBottom = false);
        break;
      case ScrollDirection.forward:
        if (!_followBottom && _isNearBottom() && mounted) {
          setState(() => _followBottom = true);
        }
        break;
      default:
        break;
    }
    return false;
  }

  /// 跟随模式下滚动到底部；用户翻阅时静默跳过，不抢滚动位置。
  void _scrollFollow() {
    if (_followBottom) _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------- 对话框宿主实现 ----------------

  void _toast(String message) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(message),
        severity: fluent.InfoBarSeverity.error,
      ),
      duration: const Duration(seconds: 3),
    );
  }

  /// 审批对话框（领域写操作 / 图片生成 / 插件工具三种警示样式）。
  Future<bool> _confirmDialog(
    String title,
    String detail,
    AiConfirmKind kind,
  ) async {
    if (!mounted) return false;
    final completer = Completer<bool>();
    // 兜底：对话框被系统返回键 pop 而非按钮关闭时，按拒绝完成，
    // 否则 Completer 永远 pending（onToolCall 挂死 → 面板永远“发送中”）。
    void abort() {
      if (!completer.isCompleted) completer.complete(false);
    }

    _c.registerPromptAbort(abort);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final size = MediaQuery.sizeOf(ctx);
          return fluent.ContentDialog(
            title: Text(title),
            content: SizedBox(
              width: min(520, size.width - 48),
              height: min(340, size.height * 0.6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (kind == AiConfirmKind.domain) ...[
                    Text(
                      '（预览基于原始 patch，实际写入以服务器校验与规整结果为准）',
                      style: TextStyle(fontSize: 11, color: palette.textMuted),
                    ),
                    const SizedBox(height: 8),
                  ] else if (kind == AiConfirmKind.image) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: palette.tintInfo,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: palette.primaryColor.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Text(
                        '⚠ 将调用 OpenAI Images API（产生费用），且生成的图片会写入当前模组。',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.statusInfo,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ] else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: palette.tintDanger,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: palette.danger.withValues(alpha: 0.33),
                        ),
                      ),
                      child: Text(
                        '⚠ 将调用第三方插件工具。插件以与编辑器相同的用户权限在本机运行，'
                        '可读写文件、访问网络，请确认工具与参数无误后再允许。',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.statusDanger,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: palette.bgDeep,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: palette.border),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          detail,
                          style: TextStyle(
                            fontFamily: kind == AiConfirmKind.domain
                                ? 'Consolas'
                                : null,
                            fontSize: kind == AiConfirmKind.domain ? 11.5 : 12,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              fluent.Button(
                onPressed: () {
                  if (!completer.isCompleted) completer.complete(false);
                  Navigator.pop(ctx);
                },
                child: const Text('拒绝'),
              ),
              fluent.FilledButton(
                onPressed: () {
                  if (!completer.isCompleted) completer.complete(true);
                  Navigator.pop(ctx);
                },
                child: Text(switch (kind) {
                  AiConfirmKind.image => '允许生成',
                  AiConfirmKind.plugin => '允许',
                  _ => '允许修改',
                }),
              ),
            ],
          );
        },
      ).whenComplete(() {
        _c.removePromptAbort(abort);
        abort();
      }),
    );
    return completer.future;
  }

  /// ask_user 提问对话框：AI 主动向用户提问并等待回答（答案回填给模型）。
  /// 与写操作审批不同：完全访问模式同样要弹。
  Future<String> _askUserDialog(String question, List<String> options) async {
    if (!mounted) return '用户未回答';
    final completer = Completer<String>();
    final inputCtrl = TextEditingController();
    // 兜底：见 _confirmDialog（系统返回键 pop → 按“用户未回答”完成）。
    void abort() {
      if (!completer.isCompleted) completer.complete('用户未回答');
    }

    _c.registerPromptAbort(abort);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final size = MediaQuery.sizeOf(ctx);
          return fluent.ContentDialog(
            title: const Text('AI 向你提问'),
            content: SizedBox(
              width: min(480, size.width - 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(question),
                  if (options.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final opt in options)
                          fluent.Button(
                            onPressed: () {
                              if (!completer.isCompleted) {
                                completer.complete(opt);
                              }
                              Navigator.pop(ctx);
                            },
                            child: Text(opt),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  fluent.TextBox(
                    controller: inputCtrl,
                    placeholder: options.isEmpty ? '输入你的回答…' : '或输入自定义回答…',
                    onSubmitted: (v) {
                      final t = v.trim();
                      if (!completer.isCompleted) {
                        completer.complete(t.isEmpty ? '用户未回答' : t);
                      }
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              fluent.Button(
                onPressed: () {
                  if (!completer.isCompleted) {
                    completer.complete('用户未回答');
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('跳过'),
              ),
              fluent.FilledButton(
                onPressed: () {
                  final t = inputCtrl.text.trim();
                  if (!completer.isCompleted) {
                    completer.complete(t.isEmpty ? '用户未回答' : t);
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('提交回答'),
              ),
            ],
          );
        },
      ).whenComplete(() {
        _c.removePromptAbort(abort);
        abort();
        inputCtrl.dispose();
      }),
    );
    return completer.future;
  }

  // ---------------- 生成整段事件（M6 入口，实现见 event_plan_flow.dart） ----------------

  /// 打开「生成整段事件」对话框：自然语言描述 → 结构化提案 → 逐卡确认写入。
  void _openEventPlanFlow() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return fluent.ContentDialog(
          title: const Text('生成整段事件'),
          content: SizedBox(
            width: min(760, size.width - 48),
            height: min(620, size.height * 0.8),
            child: EventPlanFlowPage(
              modName: widget.state.modName,
              settings: widget.settings,
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

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    // 空会话（只有系统提示或完全为空）时展示欢迎引导。
    final showWelcome = _c.messages.every((m) => m.role == 'system');
    // 历史会话为滑入浮层而非整屏替换：聊天子树用 Offstage 保活
    // （滚动位置/输入草稿/在途流式渲染不丢失；Offstage 使 finder 跳过
    // 隐藏层，不产生重复文本命中），浮层打开时滑入淡入（阶段 3a）。
    return Stack(
      children: [
        // TickerMode：Offstage 只挡绘制，隐藏时聊天区里的流式点点动画
        // 仍会持续出帧；停掉后重新展开自动恢复。
        Offstage(
          offstage: _showHistory,
          child: TickerMode(
            enabled: !_showHistory,
            child: _buildChatView(showWelcome),
          ),
        ),
        if (_showHistory)
          Positioned.fill(
            child: _HistoryFadeIn(
              child: ColoredBox(
                color: palette.panel,
                child: _buildHistoryView(),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChatView(bool showWelcome) {
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) => Row(
              children: [
                Icon(FluentIcons.bot_24_regular, size: 15, color: accentColor),
                const SizedBox(width: 8),
                Text(
                  'AI 助手',
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: ModBadge(name: widget.state.modName)),
                const SizedBox(width: 6),
                HoverIconBtn(
                  icon: FluentIcons.chat_history_24_regular,
                  tip: '历史对话',
                  onTap: _openHistory,
                  size: 15,
                ),
                const SizedBox(width: 2),
                HoverIconBtn(
                  icon: FluentIcons.add_24_regular,
                  tip: '新建对话',
                  onTap: _newChat,
                  size: 15,
                ),
                const SizedBox(width: 2),
                HoverIconBtn(
                  icon: _fullAccess
                      ? FluentIcons.shield_dismiss_24_regular
                      : FluentIcons.shield_24_regular,
                  tip: !_canTogglePermission
                      ? 'AI 权限：先在 AI 设置中完成配置后可切换'
                      : _fullAccess
                      ? 'AI 权限：完全访问（修改不再弹确认框）· 点击切回变更前确认'
                      : 'AI 权限：变更前确认 · 点击切换为完全访问（不再弹确认框）',
                  onTap: _canTogglePermission ? _togglePermissionMode : null,
                  size: 15,
                ),
                const SizedBox(width: 2),
                HoverIconBtn(
                  icon: FluentIcons.settings_24_regular,
                  tip: 'AI 设置',
                  onTap: widget.onOpenSettings,
                  size: 15,
                ),
                const SizedBox(width: 2),
                HoverIconBtn(
                  icon: FluentIcons.delete_24_regular,
                  tip: '清空当前对话',
                  onTap: _clearChat,
                  size: 15,
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: palette.border),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: showWelcome
                    ? WelcomeView(
                        fullAccess: _fullAccess,
                        onPick: (t) {
                          setState(() => _input.text = t);
                          _focusInput.requestFocus();
                        },
                      )
                    : NotificationListener<UserScrollNotification>(
                        onNotification: _handleUserScroll,
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(12),
                          itemCount: _c.messages.length,
                          itemBuilder: (context, i) {
                            final msg = _c.messages[i];
                            final isStreaming =
                                _c.busy && identical(msg, _c.streamingMsg);
                            // 流式中的气泡只订阅文本信号（阶段 1）：
                            // 90ms 节流刷新不再重建整棵消息列表与已完成气泡。
                            final bubble = isStreaming
                                ? ValueListenableBuilder<String>(
                                    valueListenable: _c.streamingTextV,
                                    builder: (context, live, _) =>
                                        MessageBubble(
                                          msg: msg,
                                          busy: true,
                                          liveText: live,
                                          onCopy: () => _copyText(msg.text),
                                          onRetry: _c.retry,
                                        ),
                                  )
                                : MessageBubble(
                                    msg: msg,
                                    busy: false,
                                    onCopy: () => _copyText(msg.text),
                                    onRetry: _c.retry,
                                  );
                            return RepaintBoundary(child: bubble);
                          },
                        ),
                      ),
              ),
              if (!showWelcome && !_followBottom)
                Positioned(
                  right: 16,
                  bottom: 10,
                  child: JumpLatestButton(
                    onTap: () {
                      setState(() => _followBottom = true);
                      _scrollDown();
                    },
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '对话输入框：向 AI 提问或下达修改模组文件的指令，可附带 docx/txt/md/xlsx/png/jpg 附件',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
              ),
              const SizedBox(height: 4),
              _buildInput(),
              if (_c.pendingAttachments.isNotEmpty || _c.uploading) ...[
                const SizedBox(height: 6),
                _buildPendingAttachments(),
              ],
              if (_c.outbox.isNotEmpty) ...[
                const SizedBox(height: 6),
                _buildQueueChips(),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  HoverIconBtn(
                    icon: FluentIcons.attach_24_regular,
                    tip: '上传附件（docx / txt / md / xlsx / png / jpg）',
                    onTap: _c.busy || _c.uploading ? null : _c.pickFiles,
                    size: 15,
                  ),
                  const SizedBox(width: 8),
                  HoverIconBtn(
                    icon: FluentIcons.wand_24_regular,
                    tip: '生成整段事件（描述剧情 → AI 提案 → 逐卡确认写入）',
                    onTap: _openEventPlanFlow,
                    size: 15,
                  ),
                  const SizedBox(width: 8),
                  // web 双通道：平台 AI / 自带 key 轻量切换（桌面不显示）。
                  if (kIsWeb) ...[
                    _buildChannelChip(),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: fluent.FlyoutTarget(
                      controller: _modelFlyout,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: _showModelMenu,
                          child: Tooltip(
                            message: _c.webUseRelay
                                ? '平台 AI 的服务端模型（本地模型名不影响网关配置）'
                                : '快捷切换模型（最近使用）',
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    _modelLabel,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _fullAccess
                                          ? palette.statusWarn
                                          : palette.textHint,
                                    ),
                                  ),
                                ),
                                Icon(
                                  FluentIcons.chevron_down_24_regular,
                                  size: 9,
                                  color: palette.textHint,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_c.busy)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListenableBuilder(
                          listenable: _input,
                          builder: (context, _) => fluent.Button(
                            onPressed: _input.text.trim().isNotEmpty
                                ? _send
                                : null,
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.add_24_regular, size: 13),
                                SizedBox(width: 4),
                                Text('排队', style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        fluent.Button(
                          onPressed: _stop,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(FluentIcons.stop_24_regular, size: 13),
                              SizedBox(width: 4),
                              Text('停止', style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    )
                  else
                    ListenableBuilder(
                      listenable: _input,
                      builder: (context, _) {
                        final canSend =
                            _input.text.trim().isNotEmpty ||
                            _c.pendingAttachments.isNotEmpty;
                        return fluent.FilledButton(
                          onPressed: canSend ? _send : null,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(FluentIcons.send_24_regular, size: 13),
                              SizedBox(width: 4),
                              Text('发送', style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 历史会话列表视图：按更新时间降序，点击恢复、可删除、可新建、可搜索。
  Widget _buildHistoryView() {
    var sessions = List.of(_c.sessions)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final q = _historyQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      sessions = [
        for (final s in sessions)
          if (s.title.toLowerCase().contains(q) ||
              HistoryTile.preview(s).toLowerCase().contains(q))
            s,
      ];
    }
    return Column(
      children: [
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _closeHistory,
                  child: Icon(
                    FluentIcons.arrow_left_24_regular,
                    size: 15,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                FluentIcons.chat_history_24_regular,
                size: 15,
                color: accentColor,
              ),
              const SizedBox(width: 8),
              Text(
                '历史对话',
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _newChat,
                  child: fluent.Tooltip(
                    message: '新建对话',
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        FluentIcons.add_24_regular,
                        size: 14,
                        color: palette.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: fluent.TextBox(
            controller: _historySearch,
            onChanged: (v) => setState(() => _historyQuery = v),
            placeholder: '搜索对话标题或内容关键词…',
          ),
        ),
        Expanded(
          child: sessions.isEmpty
              ? Center(
                  child: Text(
                    _historyQuery.trim().isEmpty ? '暂无历史对话' : '没有匹配的对话',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: sessions.length,
                  itemBuilder: (context, i) => HistoryTile(
                    session: sessions[i],
                    active: sessions[i] == _c.active,
                    onOpen: () => _switchSession(sessions[i]),
                    onDelete: () => _deleteSession(sessions[i]),
                  ),
                ),
        ),
      ],
    );
  }

  /// 待发送附件列表（横向排布，可逐个删除）。
  Widget _buildPendingAttachments() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final a in _c.pendingAttachments)
            AttachmentChip(
              attachment: a,
              onRemove: () => _c.removeAttachment(a),
            ),
          if (_c.uploading)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  SizedBox(width: 6),
                  Text(
                    '解析中…',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 排队消息条（阶段 3b）：点文本立即发送，点 × 取消排队。
  Widget _buildQueueChips() {
    final items = _c.outbox;
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var i = 0; i < items.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: palette.bgDeep,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: palette.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.history_24_regular,
                    size: 11,
                    color: palette.textHint,
                  ),
                  const SizedBox(width: 5),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _c.sendQueuedNow(i),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          items[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _c.removeQueued(i),
                      child: Icon(
                        FluentIcons.dismiss_24_regular,
                        size: 11,
                        color: palette.textMuted,
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

  /// 技能联想菜单：位于输入框正上方，可滚动；点击项把正文填入输入框。
  Widget _buildSkillMenu() {
    final items = _skillMenu!;
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.border),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in items)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _insertSkill(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '/${s.name}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: palette.textPrimary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 多行输入框：Enter / 小键盘 Enter 发送，Shift+Enter 换行，
  /// `/` 前缀唤起技能联想菜单（Escape 或文本变化即关闭）；菜单渲染在输入框上方。
  Widget _buildInput() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_skillMenu != null && _skillMenu!.isNotEmpty) _buildSkillMenu(),
        Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent && _skillMenu != null) {
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                setState(() => _skillMenu = null);
                return KeyEventResult.handled;
              }
            }
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
              if (!HardwareKeyboard.instance.isShiftPressed) {
                _send();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: fluent.TextBox(
            controller: _input,
            focusNode: _focusInput,
            minLines: 1,
            maxLines: 6,
            placeholder: '询问 AI，或让它修改模组文件…（/ 唤起技能模板，Enter 发送，Shift+Enter 换行）',
          ),
        ),
      ],
    );
  }
}

/// 历史浮层入场动画：快速淡入（阶段 3a）。
/// 刻意不用滑动位移——变换会把首帧命中区推出原位，
/// 动画期间的点击会落空（widget_test 回归教训）。
class _HistoryFadeIn extends StatefulWidget {
  const _HistoryFadeIn({required this.child});
  final Widget child;

  @override
  State<_HistoryFadeIn> createState() => _HistoryFadeInState();
}

class _HistoryFadeInState extends State<_HistoryFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppMotion.fast,
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: AppMotion.easeOut,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _fade, child: widget.child);
  }
}

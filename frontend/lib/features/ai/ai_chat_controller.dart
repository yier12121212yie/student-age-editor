/// AI 聊天控制器：会话状态、持久化、发送循环、工具执行、附件上传。
///
/// 从 ai_panel.dart 的 `AiPanelState` 拆出（阶段 0），与 UI 解耦：
/// - 由 [ShellState] 持有单例，三个桌面壳与移动端 sheet/全屏共用同一实例，
///   切换视图/收起侧栏不再丢失在途的流式回复与工具调用；
/// - 依赖 BuildContext 的能力（审批弹窗、提问、toast）通过 [AiDialogHost]
///   回调栈委托给当前最上层的 AiPanel 视图实现。
///
/// 状态变化通过 [ChangeNotifier] 通知；滚动请求通过 [scrollFollowTick] /
/// [scrollForceTick] 两个计数信号（跟随模式 / 强制滚到底），避免控制器
/// 依赖 ScrollController。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../settings/settings_page.dart';
import 'ai_client.dart';
import 'ai_models.dart';
import 'ai_policy.dart';
import 'ai_prompts.dart';
import 'ai_tools.dart';
import 'mcp/mcp_client.dart';
import 'mcp/mcp_transport_factory.dart';
import 'mcp/mcp_types.dart';

/// 审批对话框类型（决定 UI 的警示条样式与按钮文案）。
enum AiConfirmKind {
  /// 领域写操作（改/建/删条目、舞台调度）
  domain,

  /// 图片生成/修改（产生费用）
  image,

  /// 第三方插件工具（本机权限风险提示）
  plugin,
}

/// UI 侧提供的对话框/toast 能力；由最上层挂载的 AiPanel 注册。
class AiDialogHost {
  const AiDialogHost({
    required this.confirm,
    required this.ask,
    required this.toast,
  });

  /// 审批对话框：返回是否允许。detail 为已排好版的正文。
  final Future<bool> Function(String title, String detail, AiConfirmKind kind)
  confirm;

  /// 提问对话框：返回用户回答文本（跳过/超时按「用户未回答」）。
  final Future<String> Function(String question, List<String> options) ask;

  /// 轻量提示。
  final void Function(String message) toast;
}

class AiChatController extends ChangeNotifier {
  AiChatController({required this.appState, required AiSettings settings})
    : _settings = settings;

  /// 提供当前工作区/模组名（发送前置检查与 modContext 用）。
  final AppState appState;

  /// 当前 AI 设置。视图挂载/更新时写入；发送时读取。
  AiSettings get settings => _settings;
  AiSettings _settings;

  /// 面板每次 build 都会更新引用：仅当影响 MCP 连接的字段
  /// （enabled 服务器的 id 集合）变化时才后台重连，避免无谓握手；
  /// 其余更新顺带用已连接客户端刷新一次工具缓存。
  set settings(AiSettings value) {
    final prev = _settings;
    _settings = value;
    if (_disposed) return;
    if (_mcpSignature(prev) != _mcpSignature(value)) {
      unawaited(syncMcp());
    } else {
      _rebuildMcpTools();
    }
  }

  static String _mcpSignature(AiSettings s) =>
      [for (final c in s.mcpServers) if (c.enabled) c.id].join('\u0001');

  /// MCP 客户端（key = 服务器 id），仅在 enabled 且连接成功后在场。
  final Map<String, McpClient> _mcpClients = {};

  /// 已确认「允许连接」的 MCP 服务器 id 集合（安全批次 B，持久化名单，
  /// 首次使用时从 [McpAllowPrefs] 懒加载）。
  Set<String>? _mcpAllowed;

  /// 本次运行内被用户拒绝的 MCP 服务器 id：不再重复弹窗（不持久化，
  /// 下次启动重新询问）。
  final Set<String> _mcpDenied = {};

  /// 在途的首次连接确认（按服务器 id 去重，防并发 syncMcp 重复弹窗）。
  final Map<String, Future<bool>> _mcpConfirmInflight = {};

  /// 已连接 MCP 客户端的工具定义缓存（名字带 `mcp__<id>__` 前缀），
  /// 发送时并入 tools，与连接/断开同步刷新。
  final List<AiToolDef> _mcpTools = [];

  bool get fullAccess => settings.isFullAccess;

  // ---------------- web 双通道（M0.4，仅 kIsWeb 生效） ----------------

  /// 后端 AI 网关策略（桌面端恒为兜底值：无网关/允许自带 key/TTS 生图可用）。
  AiPolicy get webPolicy => AiPolicyStore.instance.policy;

  /// 用户在面板上显式选择的通道（auto = 有 key 直连、无 key 走平台）。
  AiChannelChoice get channelChoice => _channelChoice;
  AiChannelChoice _channelChoice = AiChannelChoice.auto;

  /// 当前实际是否走平台网关通道。
  bool get webUseRelay => resolveUseRelay(
    web: kIsWeb,
    choice: _channelChoice,
    policy: webPolicy,
    hasOwnKey: settings.apiKey.trim().isNotEmpty,
  );

  /// 面板切换通道（平台 AI / 自带 key）：持久化并刷新 UI。
  Future<void> setChannelChoice(AiChannelChoice choice) async {
    if (_channelChoice == choice) return;
    _channelChoice = choice;
    changed();
    await AiChannelPrefs.save(choice);
  }

  void _onPolicyChanged() {
    if (!_disposed) changed();
  }

  // ---------------- 持久化 key 与上限 ----------------

  /// 旧版单会话存储 key（v1，启动时迁移到多会话后清理）。
  static const _historyKey = 'ai_chat_messages_v1';
  static const _structuredKey = 'ai_chat_history_v1';

  /// 多会话存储 key。
  static const _sessionsKey = 'ai_sessions_v1';
  static const _activeKey = 'ai_active_session_v1';
  static const _maxSessions = 50;
  static const _maxPersistMessages = 100;
  static const _maxPersistItems = 300;
  static const _maxUploadBytes = 10 * 1024 * 1024;

  /// 流式输出的 UI 刷新间隔（毫秒）：数据即时累加，界面按此节流重建。
  static const int _streamFlushMs = 90;

  // ---------------- 状态 ----------------

  /// 全部会话（含当前会话），按 updatedAt 排序后展示。
  final List<AiSession> sessions = [];

  AiSession? _active;
  AiSession? get active => _active;

  /// 当前活动会话的消息列表（始终等于 _active.messages）。
  List<AiChatMessage> _messages = [];
  List<AiChatMessage> get messages => _messages;

  /// 结构化消息历史（OpenAI 风格），由 AiClient 在工具轮次中追加，
  /// 跨轮次发送保留完整上下文；与 messages 一起持久化。
  List<Map<String, dynamic>> _history = [];

  AiClient? _client;
  bool _busy = false;
  bool get busy => _busy;

  /// 当前是否有等待用户应答的审批/提问对话框（收起侧栏时的提醒角标）。
  bool get hasPendingPrompt => _pendingPromptAbort.isNotEmpty;

  /// 发送世代（阶段 2f）：draftSend/sendText 在首个 await（mod 同步检查）前
  /// 同步占用 _busy 并记录世代；stop/新会话递增，使在途预检回来后发现
  /// 世代已变即作废返回——预检挂起期间被停止，不得再继续把消息发出去。
  int _sendEpoch = 0;

  AiChatMessage? _streamingMsg;
  AiChatMessage? get streamingMsg => _streamingMsg;

  bool _loaded = false;
  bool get loaded => _loaded;
  bool _loadStarted = false;

  bool _disposed = false;

  /// 挂起的审批/提问对话框兜底关闭器（Completer 泄漏防护）：
  /// 对话框被系统返回键 pop 而非按钮关闭时，局部 Completer 不会完成，
  /// await 方（onToolCall 等）会永久挂起 → 面板永远“发送中”。
  /// 列表里存的是“若 Completer 未完成则按拒绝/未回答补完成”的回调。
  final List<void Function()> _pendingPromptAbort = [];

  /// 流式输出 UI 刷新定时器（节流）。
  Timer? _uiFlush;

  /// 本轮用户消息在 _history 中的起始下标，用于失败重试时回退。
  int _lastUserHistStart = 0;

  /// 当前流中已累积、但尚未确定归属（最终回复或工具轮次过渡文本）的文本。
  /// 当一轮以工具调用结束时，onToolRoundText 会把这部分文本从
  /// _streamingMsg.text 中拆出，移入 toolRoundTexts。
  String _pendingRoundBuf = '';

  /// 当前工具轮次号（= 已拆出的过渡文本条数）；ToolRecord.round 据此赋值。
  int _toolRound = 0;

  /// 插件声明的 AI 工具（GET /api/plugins/agent/tools）。
  final List<PluginAiTool> _pluginTools = [];

  /// 待发送附件（上传解析成功、尚未随消息发出）。
  final List<AiAttachment> pendingAttachments = [];
  bool _uploading = false;
  bool get uploading => _uploading;

  /// 排队消息（阶段 3b）：busy 时用户可继续输入并入队，
  /// 当前轮结束（完成/出错）后自动依次续发；stop 不续发。
  final List<String> outbox = [];

  /// 滚动请求信号：跟随模式（在底部时才滚）/ 强制滚到底部。
  final ValueNotifier<int> scrollFollowTick = ValueNotifier<int>(0);
  final ValueNotifier<int> scrollForceTick = ValueNotifier<int>(0);

  /// 流式气泡的实时文本：数据每 delta 即时累加到消息对象，界面按
  /// [_streamFlushMs] 节流只刷新这一颗气泡（阶段 1：局部流式刷新，
  /// 不再每 90ms 重建整棵消息列表）。非流式期间无消费者，值随意。
  final ValueNotifier<String> streamingTextV = ValueNotifier<String>('');

  /// 对话框宿主栈：最上层（最后挂载）的 AiPanel 视图负责呈现。
  final List<AiDialogHost> _hosts = [];

  // ---------------- 宿主注册 ----------------

  void attachHost(AiDialogHost host) => _hosts.add(host);

  void detachHost(AiDialogHost host) {
    _hosts.remove(host);
    // 该视图关闭时，其弹出的对话框随之消失：补完成所有挂起审批，
    // 避免 Completer 泄漏（与旧版 AiPanelState.dispose 行为一致）。
    abortPendingPrompts();
  }

  AiDialogHost? get _host => _hosts.isNotEmpty ? _hosts.last : null;

  /// 视图注册对话框的兜底关闭器（返回键 pop 时按拒绝/未回答完成）。
  void registerPromptAbort(void Function() abort) =>
      _pendingPromptAbort.add(abort);
  void removePromptAbort(void Function() abort) =>
      _pendingPromptAbort.remove(abort);

  void abortPendingPrompts() {
    final aborts = List.of(_pendingPromptAbort);
    _pendingPromptAbort.clear();
    for (final abort in aborts) {
      abort();
    }
  }

  // ---------------- 生命周期 ----------------

  /// 首次挂载时调用：恢复会话 + 拉取插件工具 + 连接 MCP（幂等，只启动一次）。
  void ensureLoaded() {
    if (_loadStarted) return;
    _loadStarted = true;
    unawaited(_restore());
    unawaited(_loadPluginTools());
    unawaited(syncMcp());
    if (kIsWeb) {
      // web 双通道：一次性拉取网关策略 + 恢复用户的通道选择。
      // 桌面端不消费 policy，行为与之前完全一致。
      AiPolicyStore.instance.addListener(_onPolicyChanged);
      unawaited(AiPolicyStore.instance.ensureLoaded());
      unawaited(
        AiChannelPrefs.load().then((c) {
          if (_disposed) return;
          _channelChoice = c;
          changed();
        }),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (kIsWeb) AiPolicyStore.instance.removeListener(_onPolicyChanged);
    _uiFlush?.cancel();
    _client?.cancel();
    // 断开全部 MCP 连接（stdio 会终止子进程，不留孤儿）。
    for (final client in _mcpClients.values) {
      unawaited(client.close().catchError((Object _) {}));
    }
    _mcpClients.clear();
    _mcpTools.clear();
    abortPendingPrompts();
    scrollFollowTick.dispose();
    scrollForceTick.dispose();
    streamingTextV.dispose();
    super.dispose();
  }

  // ---------------- 会话与持久化 ----------------

  /// 创建新会话（空的 messages/history 列表与控制器共享）。
  AiSession _newSession() {
    final id =
        's${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0xFFFFFF)}';
    return AiSession(id: id, messages: [], history: []);
  }

  /// 把控制器当前视图绑定到指定会话（共享其 messages/history 引用），
  /// 回到聊天视图并重算重试起点。
  void _activate(AiSession s) {
    _active = s;
    _messages = s.messages;
    _history = s.history;
    _lastUserHistStart = 0;
    for (var idx = 0; idx < _history.length; idx++) {
      if (_history[idx]['role'] == 'user') _lastUserHistStart = idx;
    }
  }

  /// 会话标题：第一条用户消息（或首条非空消息）的前 30 字符。
  void _updateTitle(AiSession s) {
    if (s.title != '新对话') return;
    String? first;
    for (final m in s.messages) {
      if (m.role == 'user' && m.text.trim().isNotEmpty) {
        first = m.text;
        break;
      }
    }
    first ??= s.messages.isEmpty
        ? null
        : s.messages
              .firstWhere(
                (m) => m.text.trim().isNotEmpty,
                orElse: () => s.messages.first,
              )
              .text;
    if (first == null) return;
    final t = first.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) {
      s.title = t.length > 30 ? '${t.substring(0, 30)}…' : t;
    }
  }

  /// 从旧版单会话存储（v1）构建会话；无有效数据返回 null。
  AiSession? _legacySession(String msgsRaw, String? histRaw) {
    try {
      final msgs = <AiChatMessage>[];
      final list = jsonDecode(msgsRaw) as List;
      for (final m in list) {
        if (m is Map) {
          final msg = AiChatMessage.fromJson(m.cast<String, dynamic>());
          if (msg != null) msgs.add(msg);
        }
      }
      final history = <Map<String, dynamic>>[];
      if (histRaw != null) {
        final hlist = jsonDecode(histRaw) as List;
        history.addAll(hlist.cast<Map<String, dynamic>>());
      }
      if (msgs.isEmpty && history.isEmpty) return null;
      final s = AiSession(id: 'legacy', messages: msgs, history: history);
      _updateTitle(s);
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    final msgsRaw = prefs.getString(_historyKey);
    final histRaw = prefs.getString(_structuredKey);
    final sessionsRaw = prefs.getString(_sessionsKey);
    sessions.clear();
    if (sessionsRaw != null) {
      try {
        final list = jsonDecode(sessionsRaw) as List;
        for (final s in list) {
          if (s is Map) {
            final session = AiSession.fromJson(s.cast<String, dynamic>());
            if (session != null) sessions.add(session);
          }
        }
      } catch (_) {}
    }
    AiSession? active;
    final activeId = prefs.getString(_activeKey);
    if (activeId != null) {
      for (final s in sessions) {
        if (s.id == activeId) {
          active = s;
          break;
        }
      }
    }
    // 首次升级：旧版单会话数据迁移为第一个历史会话
    if (sessions.isEmpty && msgsRaw != null) {
      final legacy = _legacySession(msgsRaw, histRaw);
      if (legacy != null) {
        sessions.add(legacy);
        active = legacy;
      }
    }
    // 兜底：总是保证存在一个可用的当前会话
    active ??= sessions.isNotEmpty ? sessions.last : _newSession();
    if (!sessions.contains(active)) sessions.add(active);
    _activate(active);
    _loaded = true;
    changed();
    // 迁移完成后清理旧版 key（保留持久化结果）
    if (msgsRaw != null) {
      await prefs.remove(_historyKey);
      await prefs.remove(_structuredKey);
    }
    await _persist();
  }

  Future<void> _persist() async {
    if (!_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final active = _active;
    if (active != null) {
      active.updatedAt = DateTime.now();
      _updateTitle(active);
    }
    // 会话数上限：保留最近更新的会话（不删除当前会话）
    while (sessions.length > _maxSessions) {
      AiSession? oldest;
      for (final s in sessions) {
        if (oldest == null || s.updatedAt.isBefore(oldest.updatedAt)) {
          oldest = s;
        }
      }
      if (oldest == null || oldest == active) break;
      sessions.remove(oldest);
    }
    // 逐会话截断后序列化（避免单条超大内容撑爆本地配置）
    final list = [for (final s in sessions) _sessionToPersistedJson(s)];
    await prefs.setString(_sessionsKey, jsonEncode(list));
    await prefs.setString(_activeKey, active?.id ?? '');
  }

  /// 将会话序列化为持久化 JSON：单条文本/工具结果/结构化内容截断，
  /// 消息与历史条目数量上限，结构化历史以 user 开头对齐。
  Map<String, dynamic> _sessionToPersistedJson(AiSession s) {
    final msgs = s.messages.map((m) {
      final j = m.toJson();
      final t = j['text'];
      if (t is String && t.length > 20000) j['text'] = t.substring(0, 20000);
      final tools = j['tools'];
      if (tools is List) {
        for (final t2 in tools) {
          if (t2 is Map) {
            final r = t2['result'];
            if (r is String && r.length > 5000) {
              t2['result'] = r.substring(0, 5000);
            }
          }
        }
      }
      return j;
    }).toList();
    if (msgs.length > _maxPersistMessages) {
      msgs.removeRange(0, msgs.length - _maxPersistMessages);
    }
    final hist = <Map<String, dynamic>>[];
    for (final m in s.history) {
      final j = Map<String, dynamic>.from(m);
      final c = j['content'];
      if (c is String) {
        if (c.length > 20000) j['content'] = c.substring(0, 20000);
      } else if (c is List) {
        // 图片 base64 数据不持久化：image_url 块降级为文本占位，
        // 避免历史记录被大字符串撑爆；恢复后仅保留可读说明。
        final blocks = <Map<String, dynamic>>[];
        for (final b in c) {
          if (b is! Map<String, dynamic>) continue;
          if (b['type'] == 'image_url') {
            blocks.add({
              'type': 'text',
              'text': '（图片附件：${b['attachment_name'] ?? ''}）',
            });
          } else {
            final copy = Map<String, dynamic>.from(b);
            final t = copy['text'];
            if (t is String && t.length > 20000) {
              copy['text'] = t.substring(0, 20000);
            }
            blocks.add(copy);
          }
        }
        j['content'] = blocks;
      }
      hist.add(j);
    }
    if (hist.length > _maxPersistItems) {
      hist.removeRange(0, hist.length - _maxPersistItems);
    }
    // 对齐：结构化消息必须以 user 开头（避免恢复后以孤立 tool/tool_calls 消息
    // 开头导致 API 400；同时保证 _lastUserHistStart 恢复后指向有效 user 条目）
    while (hist.isNotEmpty && hist.first['role'] != 'user') {
      hist.removeAt(0);
    }
    return {
      'id': s.id,
      'title': s.title,
      'createdAt': s.createdAt.millisecondsSinceEpoch,
      'updatedAt': s.updatedAt.millisecondsSinceEpoch,
      'messages': msgs,
      'history': hist,
    };
  }

  // ---------------- 发送 / 重试 / 清空 ----------------

  /// 控制器当前是否无法接收注入（忙/上传中/未就绪）。供外部轮询方区分
  /// 「被 busy 拒绝（稍后自然可投）」与「真失败」——阶段 2f。
  bool get isBusy => _busy || _uploading || !_loaded;

  /// 公开注入接口：把外部构造好的文本（如预览画笔圈选上下文）作为
  /// 用户消息发送给 AI。返回是否成功进入发送流程；未就绪 / 忙时返回 false。
  Future<bool> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy || _uploading || !_loaded) return false;
    if (appState.modName.isEmpty) {
      _toast('请先在「模组」列表中选择一个模组，AI 才能修改模组内容');
      return false;
    }
    await _sendFlow(t);
    return true;
  }

  /// 输入框发送：完成 mod 同步前置检查后回调 [onAccepted]（视图在此清空
  /// 输入框/恢复跟随），随后进入发送流程。前置检查失败时不清空输入，
  /// 用户消息不丢；[onPrecheckFailed] 供排队续发把消息放回队首。
  Future<void> draftSend(
    String text, {
    void Function()? onAccepted,
    void Function()? onPrecheckFailed,
  }) async {
    if ((text.isEmpty && pendingAttachments.isEmpty) ||
        _busy ||
        _uploading ||
        !_loaded) {
      return;
    }
    // 未选 mod 时提前拦截（避免清空输入后才发现无法操作）；
    // 完整的前后端同步由 _sendFlow 内的 _ensureModSynced 负责。
    if (appState.modName.isEmpty) {
      _toast('请先在「模组」列表中选择一个模组，AI 才能修改模组内容');
      return;
    }
    final attachments = List<AiAttachment>.of(pendingAttachments);
    // 阶段 2f：首个 await 前同步占忙——_ensureModSynced 是网络往返，
    // 不占位的话连点两次发送双双通过 _busy 检查，第二条在 _sendFlow 处
    // 被拒时输入框已清空，消息静默蒸发。
    _busy = true;
    final epoch = ++_sendEpoch;
    // 先做 mod 同步检查，通过后才清空输入框与附件：否则 _ensureModSynced
    // 失败/超时直接 return，用户输入的文本与附件已不可恢复。
    final synced = await _ensureModSynced();
    if (!synced || _disposed || epoch != _sendEpoch) {
      if (!_disposed && epoch == _sendEpoch) _busy = false; // 世代已被 stop 接管则不动
      if (!_disposed) onPrecheckFailed?.call();
      return;
    }
    onAccepted?.call();
    changed(); // pendingAttachments.clear() 在 _sendFlow 之前由下面执行
    pendingAttachments.clear();
    _busy = false;
    await _sendFlow(text, attachments: attachments, skipModSync: true);
  }

  /// 真正的发送流程（原 _sendText）：构造用户消息、流式接收、工具循环。
  Future<void> _sendFlow(
    String text, {
    bool appendUser = true,
    List<AiAttachment> attachments = const [],
    AiChatMessage? retryInto,
    bool skipModSync = false,
  }) async {
    if (_busy || !_loaded) return;
    // 阶段 2f：与 draftSend 同一套预检占位——本入口也被重试/续发直接调用
    // （skipModSync=false），首个 await 前必须占忙并记世代。
    _busy = true;
    final epoch = ++_sendEpoch;
    // 默认只修改「当前选定的 mod」：未选 mod 时阻止操作；
    // 后端与前端不一致时先同步，避免 AI 改到其他模组。
    if (!skipModSync) {
      final synced = await _ensureModSynced();
      if (!synced || _disposed || epoch != _sendEpoch) {
        if (!_disposed && epoch == _sendEpoch) _busy = false; // 已被 stop 接管则不动
        return;
      }
    }
    // web 双通道（M0.4）：relay=平台网关（协议/模型以 policy 为准，密钥在服务端）；
    // 其余情况（桌面、web 自带 key）沿用直连——桌面仍为流式 SSE，行为零改动。
    final relay = webUseRelay;
    final policy = webPolicy;
    final client = AiClient(
      settings,
      modContext:
          '当前模组：${appState.modName}。默认只修改这个模组，'
          '不要读取或修改其他模组的内容。',
      channel: relay ? AiTransportChannel.relay : AiTransportChannel.direct,
      relayProvider: relay ? policy.provider : '',
      relayModel: relay ? policy.model : '',
      relayModels: relay ? policy.models : const [],
    );
    final content = _buildContent(text, attachments);
    if (appendUser) {
      _messages.add(
        AiChatMessage(role: 'user', text: text, attachments: attachments),
      );
      _lastUserHistStart = _history.length; // 用户消息在 _history 中的下标
      _history.add({'role': 'user', 'content': content});
    }
    if (retryInto != null) {
      // 重试复用失败的气泡：已流出的部分文本保留，追加重连提示后继续流式输出，
      // 不清空该消息；工具卡片/过渡文本归属已回滚的那次尝试，随重试从 0 轮重来。
      retryInto
        ..error = null
        ..toolRecords.clear()
        ..toolRoundTexts.clear();
      final sep = retryInto.text.isEmpty ? '' : '\n\n';
      retryInto.text = '${retryInto.text}$sep⚠ 连接中断，正在重试…\n';
      _streamingMsg = retryInto;
    } else {
      _streamingMsg = AiChatMessage(role: 'assistant');
      _messages.add(_streamingMsg!);
    }
    _busy = true;
    _pendingRoundBuf = '';
    _toolRound = 0;
    streamingTextV.value = _streamingMsg!.text;
    changed();
    unawaited(_persist());
    scrollForceTick.value++;
    _client = client;
    try {
      await client.send(
        history: _history,
        tools: [...kBuiltinTools, ..._pluginTools, ..._mcpTools],
        callbacks: AiCallbacks(
          onText: (delta) {
            if (_disposed || _streamingMsg == null) return;
            if (!identical(_client, client)) return; // 旧流回调，已停止
            // 数据层即时累加，界面按 _streamFlushMs 节流刷新，
            // 避免长回复时每个 delta 都重建整个消息列表导致卡顿。
            _streamingMsg!.text += delta;
            _pendingRoundBuf += delta;
            _scheduleStreamFlush();
          },
          onToolRoundText: (roundText) {
            if (_disposed || _streamingMsg == null) return;
            if (!identical(_client, client)) return; // 旧流回调，已停止
            // 把本轮的过渡文本从流式 text 中拆出（它们已作为 delta
            // 追加在 text 末尾），避免与最终回复混在同一个气泡里。
            final t = _streamingMsg!.text;
            if (_pendingRoundBuf.isNotEmpty &&
                t.length >= _pendingRoundBuf.length &&
                t.endsWith(_pendingRoundBuf)) {
              _streamingMsg!.text = t.substring(
                0,
                t.length - _pendingRoundBuf.length,
              );
            }
            _pendingRoundBuf = '';
            if (roundText.trim().isNotEmpty) {
              _streamingMsg!.toolRoundTexts.add(roundText);
            }
            // 轮次推进：后续工具卡片按当前轮次标记
            _toolRound = _streamingMsg!.toolRoundTexts.length;
            streamingTextV.value = _streamingMsg!.text;
            changed();
            scrollFollowTick.value++;
          },
          onToolCall: (call) {
            // 阶段 2f：与 onText/onDone 同一 identical 校验——停止/新会话
            // 接管后，旧流的工具调用不得再进 _runTool（其中含写操作与
            // 审批弹窗，重复执行即重复落盘）。
            if (!identical(_client, client)) {
              return Future.value('已停止：忽略旧工具流调用。');
            }
            return _runTool(call);
          },
          onToolResult: (name, result) {
            if (_disposed || _streamingMsg == null) return;
            if (!identical(_client, client)) return; // 旧流回调，已停止
            final rec = _streamingMsg!.toolRecords.isNotEmpty
                ? _streamingMsg!.toolRecords.last
                : null;
            if (rec != null && rec.name == name) {
              rec.result = result;
              final st = rec.startedAt;
              if (st != null) {
                rec.durationMs = DateTime.now().difference(st).inMilliseconds;
              }
            }
            changed();
          },
          onDone: () {
            if (_disposed) return;
            if (!identical(_client, client)) return; // 已被停止/新会话接管
            _busy = false;
            _streamingMsg = null;
            _client = null;
            _pendingRoundBuf = '';
            changed();
            unawaited(_persist());
            _maybeDrainOutbox();
          },
        ),
      );
    } catch (e) {
      if (_disposed) return;
      if (!identical(_client, client)) return; // 已被停止/新会话接管
      _streamingMsg?.error = e.toString();
      _busy = false;
      _streamingMsg = null;
      _client = null;
      _pendingRoundBuf = '';
      changed();
      unawaited(_persist());
      _maybeDrainOutbox();
    }
  }

  // ---------------- 会话管理 ----------------

  /// 新建对话：当前会话已有内容时先保存（含在持久化中），再创建空会话。
  /// 允许在流式回复进行中切换视图：在途流按对象引用继续写入旧会话，
  /// 不受激活会话切换影响（阶段 3a）。
  Future<void> newChat() async {
    if (!_loaded) return;
    final active = _active;
    if (active != null && active.messages.isEmpty) return; // 当前已是空会话
    await _persist();
    if (_disposed) return;
    final s = _newSession();
    sessions.add(s);
    _activate(s);
    changed();
    await _persist();
    scrollForceTick.value++;
  }

  /// 切换/恢复会话：把控制器绑定到该会话。允许在流式进行中浏览
  /// 其它会话（在途流继续写入其所属会话，阶段 3a）。
  Future<void> switchSession(AiSession s) async {
    if (!_loaded) return;
    if (s == _active) return;
    _activate(s);
    changed();
    scrollForceTick.value++;
  }

  /// 删除会话（确认对话框由视图负责）；删除的是当前会话时，
  /// 激活最近更新的另一个会话。
  Future<void> deleteSession(AiSession s) async {
    if (_busy) return;
    sessions.remove(s);
    if (_active == s) {
      final sorted = List.of(sessions)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final next = sorted.isNotEmpty ? sorted.first : _newSession();
      _activate(next);
      if (!sessions.contains(next)) sessions.add(next);
    }
    changed();
    await _persist();
  }

  /// 重试：回滚结构化历史（保留用户消息及其 user 条目），在同一失败气泡内
  /// 续写——已流出的部分文本保留，追加重连提示后重新流式生成，不清空该消息。
  Future<void> retry() async {
    if (_busy || _messages.isEmpty) return;
    final lastUser = _messages.lastWhere(
      (m) => m.role == 'user',
      orElse: () => _messages.first,
    );
    if (lastUser.role != 'user') return;
    final failed = _messages.last;
    if (failed.role != 'assistant' || failed.error == null) return; // 只有失败气泡可重试
    // 只回退结构化历史到该轮起点之后（保留用户消息本身）；
    // 失败气泡不删除，重试在同一气泡续写
    if (_lastUserHistStart < _history.length) {
      _history.removeRange(_lastUserHistStart + 1, _history.length);
    }
    await _sendFlow(lastUser.text, appendUser: false, retryInto: failed);
  }

  /// 清空当前会话消息（确认对话框由视图负责）。
  void clearMessages() {
    if (_messages.length <= 1) return; // 只有 system 提示
    _messages
      ..clear()
      ..add(
        AiChatMessage(
          role: 'system',
          text: kAiSystemHint(fullAccess: fullAccess),
        ),
      );
    _history.clear();
    _active?.title = '新对话';
    changed();
    unawaited(_persist());
  }

  void stop() {
    _sendEpoch++; // 作废在途预检（_ensureModSynced 的 await）
    _client?.cancel();
    // 打断已挂起的审批/提问：否则停止后 Future 仍挂在 onToolCall 上，
    // _busy 无法恢复；且用户若事后点「允许」，写操作仍会执行。
    abortPendingPrompts();
    _busy = false;
    _streamingMsg = null;
    _client = null;
    _pendingRoundBuf = '';
    streamingTextV.value = '';
    changed();
  }

  // ---------------- 排队消息（阶段 3b） ----------------

  /// 把文本加入发送队列（busy 时的「发送」即入队，不打断当前轮）。
  void enqueueDraft(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    outbox.add(t);
    changed();
  }

  /// 删除一条排队消息。
  void removeQueued(int index) {
    if (index < 0 || index >= outbox.length) return;
    outbox.removeAt(index);
    changed();
  }

  /// 立即发送某条排队消息：提到队首并触发续发（空闲时）。
  void sendQueuedNow(int index) {
    if (index <= 0) {
      _maybeDrainOutbox();
      return;
    }
    if (index >= outbox.length) return;
    final t = outbox.removeAt(index);
    outbox.insert(0, t);
    changed();
    _maybeDrainOutbox();
  }

  /// 空闲且有排队消息时续发队首；mod 同步失败放回队首等待下次触发。
  void _maybeDrainOutbox() {
    if (_disposed || _busy || _uploading || !_loaded || outbox.isEmpty) return;
    final text = outbox.removeAt(0);
    changed();
    unawaited(
      draftSend(
        text,
        onPrecheckFailed: () {
          if (_disposed) return;
          outbox.insert(0, text);
          changed();
        },
      ),
    );
  }

  // ---------------- 流式节流 ----------------

  /// 流式输出按 [_streamFlushMs] 节流刷新 UI：数据已即时写入消息，
  /// 这里只是把重建合并到定时器里，避免高频通知卡顿。
  void _scheduleStreamFlush() {
    if (_uiFlush != null) return;
    _uiFlush = Timer(Duration(milliseconds: _streamFlushMs), () {
      _uiFlush = null;
      _streamChanged();
    });
  }

  void _streamChanged() {
    if (_disposed || _streamingMsg == null) return;
    // 阶段 1：只推流式气泡的文本信号，整棵面板不再随节流定时器重建；
    // 结构性变化（轮次过渡文本/工具卡片）仍走 changed()。
    streamingTextV.value = _streamingMsg!.text;
    scrollFollowTick.value++;
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  // ---------------- 附件 ----------------

  /// 组装发送给模型的内容：文本附件拼入正文；图片附件转为多模态 image_url 块。
  Object _buildContent(String text, List<AiAttachment> attachments) {
    final textParts = <String>[
      for (final a in attachments)
        if (a.kind == 'text' && (a.text ?? '').isNotEmpty)
          '【附件：${a.name}】\n${a.text}',
    ];
    final images = attachments.where((a) => a.kind == 'image').toList();
    final fullText = [
      if (textParts.isNotEmpty) textParts.join('\n\n'),
      text,
    ].where((s) => s.isNotEmpty).join('\n\n');
    if (images.isEmpty) return fullText;
    return [
      {'type': 'text', 'text': fullText},
      for (final img in images)
        {
          'type': 'image_url',
          'image_url': {'url': 'data:${img.mime};base64,${img.dataB64}'},
          // 持久化降级时用作图片占位说明
          'attachment_name': img.name,
        },
    ];
  }

  Future<void> pickFiles() async {
    if (_busy || _uploading || _disposed) return;
    const groups = [
      XTypeGroup(label: '文档', extensions: ['docx', 'txt', 'md', 'xlsx']),
      XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'jpeg']),
    ];
    final files = await openFiles(acceptedTypeGroups: groups);
    if (files.isEmpty || _disposed) return;
    for (final f in files) {
      await _uploadFile(f);
    }
  }

  Future<void> _uploadFile(XFile f) async {
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length > _maxUploadBytes) {
        _toast('「${f.name}」超过 10MB 上限，已跳过');
        return;
      }
      _uploading = true;
      changed();
      final r = await ApiClient.instance.post(
        '/api/ai/upload',
        body: {'name': f.name, 'data': base64Encode(bytes)},
      );
      final kind = r['kind'] as String? ?? 'text';
      final att = AiAttachment(
        name: r['name'] as String? ?? f.name,
        kind: kind,
        size: (r['size'] as num?)?.toInt() ?? bytes.length,
        text: kind == 'text' ? (r['text'] as String? ?? '') : null,
        mime: r['mime'] as String?,
        dataB64: kind == 'image' ? (r['data'] as String?) : null,
      );
      if (_disposed) return;
      pendingAttachments.add(att);
      _uploading = false;
      changed();
    } catch (e) {
      if (_disposed) return;
      _uploading = false;
      changed();
      _toast('上传「${f.name}」失败：$e');
    }
  }

  void removeAttachment(AiAttachment a) {
    pendingAttachments.remove(a);
    changed();
  }

  // ---------------- 工具执行 ----------------

  /// 确保 AI 只作用于「当前选定的 mod」：
  /// - 未选 mod 时返回 false 并提示（不静默回退到后端默认模组）；
  /// - 后端当前模组与前端不一致时先同步 select，再继续。
  Future<bool> _ensureModSynced() async {
    final modName = appState.modName;
    if (modName.isEmpty) {
      _toast('请先在「模组」列表中选择一个模组，AI 才能修改模组内容');
      return false;
    }
    try {
      final st = await ApiClient.instance.get('/api/state');
      if ((st['mod_name'] as String? ?? '') != modName) {
        await ApiClient.instance.post(
          '/api/mods/select',
          body: {'name': modName},
        );
      }
      return true;
    } catch (e) {
      _toast('同步当前模组失败：$e');
      return false;
    }
  }

  /// 拉取插件声明的 AI 工具，追加到发送给模型的 tools 列表；
  /// 失败静默（后端暂不支持插件工具时不阻塞聊天）。
  Future<void> _loadPluginTools() async {
    try {
      final r = await ApiClient.instance.get('/api/plugins/agent/tools');
      if (_disposed) return;
      final list = r is Map ? (r['tools'] as List? ?? const []) : const [];
      final tools = <PluginAiTool>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final name = (m['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        tools.add(
          PluginAiTool(
            name: name,
            description: m['description'] as String? ?? '',
            parameters: m['parameters'] is Map
                ? Map<String, dynamic>.from(m['parameters'] as Map)
                : const {},
            confirm: m['confirm'] == true,
          ),
        );
      }
      _pluginTools
        ..clear()
        ..addAll(tools);
      changed();
    } catch (_) {
      // 静默：插件工具不可用时不打断聊天
    }
  }

  // ---------------- MCP 连接 ----------------

  /// 同步 MCP 连接：settings.mcpServers 的 enabled 项与 [_mcpClients]
  /// 现有 key 对比——新增者拉起传输并 start()（握手 + tools/list），
  /// 移除/禁用者 close()。连接失败静默（debugPrint 留痕），不影响聊天。
  ///
  /// 安全批次 B：首次连接（持久化名单外）的 server 先经用户确认
  /// （[_ensureMcpAllowed]），未确认不连接。
  ///
  /// 幂等：可被 [ensureLoaded] 与 [settings] setter 反复调用。
  Future<void> syncMcp() async {
    if (_disposed) return;
    final wanted = <String, McpServerConfig>{
      for (final c in settings.mcpServers)
        if (c.enabled) c.id: c,
    };
    for (final id in _mcpClients.keys.toList()) {
      if (!wanted.containsKey(id)) {
        final client = _mcpClients.remove(id);
        if (client != null) {
          unawaited(client.close().catchError((Object _) {}));
        }
      }
    }
    for (final entry in wanted.entries) {
      if (_mcpClients.containsKey(entry.key)) continue; // 连接中/已连接
      final cfg = entry.value;
      // 网页版没有子进程，stdio 服务器本就不可用（stub 工厂必然抛错）：
      // 直接跳过，不为注定失败的连接弹确认框。
      if (kIsWeb && cfg.transport != 'http') continue;
      // 安全批次 B：首次连接需用户确认——stdio 传输会在本机拉起子进程执行
      // 命令，未经确认（名单外未询问/已拒绝/无面板可弹窗）一律跳过，
      // 不建立连接、不执行任何工具。
      if (!await _ensureMcpAllowed(cfg)) continue;
      if (_disposed) return;
      // 等待确认期间可能已被并发的 syncMcp 拉起，复查防重复连接。
      if (_mcpClients.containsKey(entry.key)) continue;
      final transport = defaultMcpTransport(cfg);
      final client = McpClient(cfg, transport);
      // 先登记再连：并发的 syncMcp 不会重复拉起同一服务器；
      // 连接失败的在 [_startMcpClient] 里摘除。
      _mcpClients[cfg.id] = client;
      unawaited(_startMcpClient(client));
    }
    _rebuildMcpTools();
  }

  /// MCP 首次连接确认（安全批次 B）：持久化名单内的服务器直接放行；
  /// 名单外先弹确认对话框（说明将在本机执行命令），确认后写入持久化
  /// 名单、后续不再询问，拒绝则本会话内跳过该服务器并 toast 提示。
  /// 返回是否允许连接。
  Future<bool> _ensureMcpAllowed(McpServerConfig cfg) async {
    if (_mcpDenied.contains(cfg.id)) return false;
    final allowed = _mcpAllowed ??= await McpAllowPrefs.load();
    if (allowed.contains(cfg.id)) return true;
    final inflight = _mcpConfirmInflight[cfg.id];
    if (inflight != null) return inflight; // 并发调用共用同一次弹窗
    final host = _host;
    if (host == null) {
      // 无面板挂载（无处弹窗）：未确认不连接，等下次 syncMcp 再询问。
      debugPrint('MCP 服务器 ${cfg.id} 未经确认，跳过连接（无对话框宿主）');
      return false;
    }
    final future = _askMcpAllow(host, cfg);
    _mcpConfirmInflight[cfg.id] = future;
    try {
      return await future;
    } finally {
      _mcpConfirmInflight.remove(cfg.id);
    }
  }

  /// 弹出首次连接确认对话框并按结果更新名单/拒绝集合。
  Future<bool> _askMcpAllow(AiDialogHost host, McpServerConfig cfg) async {
    final what = cfg.transport == 'stdio'
        // stdio：本机子进程，可读写文件、访问网络（与编辑器同权限）。
        ? '将在本机执行命令：${cfg.command} ${cfg.args.join(' ')}'.trim()
        : '将连接远程服务：${cfg.url}';
    final ok = await host.confirm(
      '允许连接 MCP 服务？',
      '该 MCP 服务（「${cfg.name}」）$what，是否允许？'
          '确认后连接该服务器并不再询问；拒绝则本次运行内跳过。',
      AiConfirmKind.plugin,
    );
    if (ok) {
      _mcpAllowed!.add(cfg.id);
      await McpAllowPrefs.allow(cfg.id);
    } else {
      _mcpDenied.add(cfg.id);
      host.toast('已跳过 MCP 服务器「${cfg.name}」（未允许连接）');
    }
    return ok;
  }

  Future<void> _startMcpClient(McpClient client) async {
    try {
      await client.start();
    } catch (e) {
      // 静默：坏配置/不可达服务器不阻塞聊天，只摘除该客户端。
      debugPrint('MCP 连接失败（${client.cfg.id}）：$e');
      if (_mcpClients[client.cfg.id] == client) {
        _mcpClients.remove(client.cfg.id);
      }
      try {
        await client.close();
      } catch (_) {}
    }
    if (_disposed) return;
    _rebuildMcpTools();
    changed();
  }

  /// 用已连接客户端缓存的工具重建 [_mcpTools]（发送时并入 tools）。
  void _rebuildMcpTools() {
    _mcpTools.clear();
    for (final client in _mcpClients.values) {
      if (!client.connected) continue;
      for (final t in client.tools) {
        _mcpTools.add(t.toToolDef(client.cfg.id));
      }
    }
  }

  /// 解析 `mcp__<serverId>__<tool>` → (serverId, toolName)；
  /// 非 mcp__ 前缀返回 null。
  ///
  /// serverId 允许含下划线（[McpServerConfig.sanitizeId] 只替换
  /// 非 `[A-Za-z0-9_]` 字符），纯字符串切分存在歧义：优先用已登记的
  /// 服务器 id 做前缀匹配（多个命中取最长 id），无命中（服务器已断开
  /// 被摘除等）再退回「前缀后第一个 __ 分段」的解析以便给出明确报错。
  static ({String serverId, String toolName})? parseMcpToolName(
    String name,
    Iterable<String> knownServerIds,
  ) {
    const prefix = 'mcp__';
    if (!name.startsWith(prefix)) return null;
    String? bestId;
    for (final id in knownServerIds) {
      if (id.isEmpty) continue;
      final p = '$prefix${id}__';
      if (name.length > p.length &&
          name.startsWith(p) &&
          (bestId == null || id.length > bestId.length)) {
        bestId = id;
      }
    }
    if (bestId != null) {
      return (
        serverId: bestId,
        toolName: name.substring(prefix.length + bestId.length + 2),
      );
    }
    final rest = name.substring(prefix.length);
    final sep = rest.indexOf('__');
    if (sep <= 0 || sep + 2 >= rest.length) return null; // id 或工具名为空
    return (
      serverId: rest.substring(0, sep),
      toolName: rest.substring(sep + 2),
    );
  }

  /// 执行工具：映射到后端 API。
  Future<String> _runTool(AiToolCall call) async {
    final rec = ToolRecord(
      name: call.name,
      arguments: call.arguments,
      round: _toolRound,
    )..startedAt = DateTime.now();
    if (_disposed || _streamingMsg == null) return '错误：面板已关闭';
    _streamingMsg!.toolRecords.add(rec);
    changed();

    try {
      switch (call.name) {
        case 'list_domains':
          final r = await ApiClient.instance.get('/api/ai/domains');
          final domains = (r['domains'] as List)
              .whereType<Map>()
              .map((d) {
                final m = Map<String, dynamic>.from(d);
                final tables = (m['tables'] is Map)
                    ? (m['tables'] as Map).keys.join('、')
                    : '';
                return '${m['id']}（${m['name']}）：${m['desc']}\n  包含表：$tables';
              })
              .join('\n\n');
          return domains.isEmpty ? '(无领域)' : domains;
        case 'get_game_dicts':
          final name = (call.arguments['name'] as String?) ?? '';
          final q = (call.arguments['q'] as String?) ?? '';
          final limit = (call.arguments['limit'] as num?)?.toInt();
          final r = await ApiClient.instance.get(
            '/api/ai/dicts',
            query: {
              if (name.isNotEmpty) 'name': name,
              if (q.isNotEmpty) 'q': q,
              if (limit != null) 'limit': '$limit',
            },
          );
          if (r['dicts'] != null) {
            // 列出可用字典
            final dicts = (r['dicts'] as List)
                .map((d) {
                  final m = d as Map<String, dynamic>;
                  return '${m['id']}（${m['name']}）：${m['count']} 项';
                })
                .join('\n');
            return '可用字典：\n$dicts';
          }
          final items = (r['items'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']} · ${m['name']}';
              })
              .join('\n');
          return '[${r['cn']}] 共 ${r['total']} 条匹配：\n$items';
        case 'list_domain_items':
          final domain = (call.arguments['domain'] as String?) ?? '';
          if (domain.isEmpty) return '错误：缺少 domain 参数';
          final q = (call.arguments['q'] as String?) ?? '';
          final table = (call.arguments['table'] as String?) ?? '';
          final limit = (call.arguments['limit'] as num?)?.toInt();
          final r = await ApiClient.instance.get(
            '/api/ai/domain/items',
            query: {
              'domain': domain,
              if (q.isNotEmpty) 'q': q,
              if (table.isNotEmpty) 'table': table,
              if (limit != null) 'limit': '$limit',
            },
          );
          final items = (r['items'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                final name = (m['name'] as String? ?? '').trim();
                final summary = (m['summary'] as String? ?? '').trim();
                final label = name.isEmpty
                    ? 'id=${m['id']}'
                    : '「$name」(id=${m['id']})';
                final extra = summary.isEmpty ? '' : ' — $summary';
                return '[${m['cfg']}] $label$extra';
              })
              .join('\n');
          return items.isEmpty ? '(该领域暂无条目，或关键词无匹配)' : items;
        case 'get_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final id = (call.arguments['id'] as String?) ?? '';
          if (domain.isEmpty || cfg.isEmpty || id.isEmpty) {
            return '错误：缺少 domain/cfg/id 参数';
          }
          final r = await ApiClient.instance.get(
            '/api/ai/domain/item',
            query: {'domain': domain, 'cfg': cfg, 'id': id},
          );
          final data = r['data'];
          return '[${r['cfg_cn'] ?? cfg}] id=$id\n${jsonEncode(data)}';
        case 'update_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final id = (call.arguments['id'] as String?) ?? '';
          final patch = call.arguments['patch'];
          if (domain.isEmpty || cfg.isEmpty || id.isEmpty) {
            return '错误：缺少 domain/cfg/id 参数';
          }
          if (patch is! Map<String, dynamic> || patch.isEmpty) {
            return '错误：patch 必须是非空对象';
          }
          // 先读取原条目用于 diff 预览
          final old = await ApiClient.instance.get(
            '/api/ai/domain/item',
            query: {'domain': domain, 'cfg': cfg, 'id': id},
          );
          final rawOld = old['data'];
          final oldData = rawOld is Map
              ? rawOld.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{};
          final newData = Map<String, dynamic>.from(oldData)..addAll(patch);
          final approved = await _confirmDomainChange(
            'AI 请求修改「${old['cfg_cn'] ?? cfg}」id=$id',
            _diffJson(oldData, newData),
          );
          if (!approved) {
            rec.approved = false;
            changed();
            return '用户拒绝修改。请停止该操作并向用户说明。';
          }
          final r2 = await ApiClient.instance.put(
            '/api/ai/domain/item',
            body: {'domain': domain, 'cfg': cfg, 'id': id, 'patch': patch},
          );
          if (r2['changed'] == true) {
            return '已修改字段：${(r2['patched_fields'] as List).join('、')}\n'
                '新内容：${jsonEncode(r2['data'])}';
          }
          return '未改动（${r2['note'] ?? 'patch 与原内容一致'}）';
        case 'create_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final data = call.arguments['data'];
          if (domain.isEmpty || cfg.isEmpty) {
            return '错误：缺少 domain/cfg 参数';
          }
          if (data is! Map<String, dynamic> || data.isEmpty) {
            return '错误：data 必须是非空对象';
          }
          final approved = await _confirmDomainChange(
            'AI 请求在「$cfg」新建条目',
            '(新条目)\n\n${jsonEncode(data)}',
          );
          if (!approved) {
            rec.approved = false;
            changed();
            return '用户拒绝新建。请停止该操作并向用户说明。';
          }
          final r2 = await ApiClient.instance.post(
            '/api/ai/domain/item',
            body: {'domain': domain, 'cfg': cfg, 'data': data},
          );
          return '已新建 id=${r2['id']}：${jsonEncode(r2['data'])}';
        case 'delete_domain_item':
          final domain = (call.arguments['domain'] as String?) ?? '';
          final cfg = (call.arguments['cfg'] as String?) ?? '';
          final id = (call.arguments['id'] as String?) ?? '';
          if (domain.isEmpty || cfg.isEmpty || id.isEmpty) {
            return '错误：缺少 domain/cfg/id 参数';
          }
          final old = await ApiClient.instance.get(
            '/api/ai/domain/item',
            query: {'domain': domain, 'cfg': cfg, 'id': id},
          );
          final approved = await _confirmDomainChange(
            'AI 请求删除「${old['cfg_cn'] ?? cfg}」id=$id',
            '(被删除内容)\n\n${jsonEncode(old['data'])}',
          );
          if (!approved) {
            rec.approved = false;
            changed();
            return '用户拒绝删除。请停止该操作并向用户说明。';
          }
          await ApiClient.instance.delete(
            '/api/ai/domain/item',
            query: {'domain': domain, 'cfg': cfg, 'id': id},
          );
          return '已删除：$cfg id=$id';
        case 'list_files':
          final path = (call.arguments['path'] as String?) ?? '';
          final scope = (call.arguments['scope'] as String?) ?? 'mod';
          final r = await ApiClient.instance.get(
            '/api/tools/list',
            query: {'scope': scope, 'path': path, 'deep': '1'},
          );
          final entries = (r['entries'] as List)
              .take(300)
              .map((e) {
                final m = e as Map<String, dynamic>;
                final p = m['name'];
                final isDir = m['type'] == 'dir';
                return (isDir ? '[目录] ' : '[文件] ') + p.toString();
              })
              .join('\n');
          return entries.isEmpty ? '(空目录)' : entries;
        case 'read_file':
          final path = (call.arguments['path'] as String?) ?? '';
          if (path.isEmpty) return '错误：缺少 path 参数';
          final r = await ApiClient.instance.get(
            '/api/tools/read',
            query: {'scope': 'mod', 'path': path},
          );
          final text = r['text'] as String?;
          if (text == null) return '错误：二进制文件或读取失败';
          return text;
        case 'list_mods':
          final r = await ApiClient.instance.get('/api/mods');
          final mods = (r['mods'] as List)
              .map((e) => (e as Map<String, dynamic>)['name'].toString())
              .join('\n');
          return mods.isEmpty ? '(无模组)' : mods;
        case 'get_stage_dicts':
          final sr = await ApiClient.instance.get('/api/ai/stage/dicts');
          final exprs = (sr['expressions'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']}=${m['name']}';
              })
              .join(' ');
          final actions = (sr['actions'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                final target = m['role'] == true ? '作用于角色' : '屏幕特效';
                return '[${m['type']}] ${m['name']}（${m['category']}/$target）：${m['params']}';
              })
              .join('\n');
          final poses = (sr['positions'] as List)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']}=${m['name']}';
              })
              .join(' ');
          final roles = (sr['roles'] as List)
              .take(80)
              .map((e) {
                final m = e as Map<String, dynamic>;
                return '${m['id']}=${m['name']}';
              })
              .join(' ');
          return '人物表情：$exprs\n\n动作类型：\n$actions\n\n站位：$poses\n\n'
              '角色（前 80 个，完整列表可用 get_game_dicts(name=roles)）：\n$roles';
        case 'get_talk_stage':
          final talkId = (call.arguments['talk_id'] as String?) ?? '';
          if (talkId.isEmpty) return '错误：缺少 talk_id 参数';
          final sr2 = await ApiClient.instance.get(
            '/api/ai/stage/roles',
            query: {'talk_id': talkId},
          );
          return '对白 $talkId 当前人物舞台：\n${sr2['desc']}';
        case 'set_talk_stage':
          final talkId = (call.arguments['talk_id'] as String?) ?? '';
          final commands = call.arguments['commands'];
          final clear = call.arguments['clear'] == true;
          if (talkId.isEmpty) return '错误：缺少 talk_id 参数';
          if (commands is! List || commands.isEmpty) {
            return '错误：commands 必须是非空数组';
          }
          // 先编码预览（后端校验并合并原有指令，不写盘）
          final sr3 = await ApiClient.instance.post(
            '/api/ai/stage/encode',
            body: {'talk_id': talkId, 'commands': commands, 'clear': clear},
          );
          final oldDesc = (sr3['old_desc'] as String? ?? '').trim();
          final newDesc = (sr3['new_desc'] as String? ?? '').trim();
          final newRoles = sr3['new_roles'];
          final approved = await _confirmDomainChange(
            'AI 请求修改对白 $talkId 的人物舞台',
            '修改前：\n$oldDesc\n\n修改后：\n$newDesc\n\n'
                '编码结果（roles 字段）：\n${jsonEncode(newRoles)}',
          );
          if (!approved) {
            rec.approved = false;
            changed();
            return '用户拒绝修改舞台。请停止该操作并向用户说明。';
          }
          await ApiClient.instance.put(
            '/api/ai/domain/item',
            body: {
              'domain': 'story',
              'cfg': 'TalkCfg',
              'id': talkId,
              'patch': {'roles': newRoles},
            },
          );
          return '已更新对白 $talkId 的人物舞台：\n$newDesc';
        case 'generate_image':
          return await _runGenerateImage(call, rec);
        case 'edit_image':
          return await _runEditImage(call, rec);
        case 'ask_user':
          final question = ((call.arguments['question'] as String?) ?? '')
              .trim();
          final rawOpts = call.arguments['options'];
          final options = <String>[
            if (rawOpts is List)
              for (final o in rawOpts)
                if (o is String && o.trim().isNotEmpty) o.trim(),
          ].take(6).toList();
          return await _askUser(question, options);
        default:
          // MCP 工具路由（mcp__<serverId>__<tool>）：置于内置/插件名之前，
          // 内置与插件工具名均不带 mcp__ 前缀，不会误伤。
          if (call.name.startsWith('mcp__')) {
            final parsed = parseMcpToolName(call.name, _mcpClients.keys);
            if (parsed == null) {
              return '错误：无法解析的 MCP 工具名 ${call.name}';
            }
            final client = _mcpClients[parsed.serverId];
            if (client == null || !client.connected) {
              return '错误：MCP 服务器未连接 ${parsed.serverId}';
            }
            return await client.callTool(parsed.toolName, call.arguments);
          }
          // 插件工具兜底分支（置于内置工具之后）
          for (final pt in _pluginTools) {
            if (pt.name == call.name) {
              return await _runPluginTool(pt, call, rec);
            }
          }
          return '错误：未知工具 ${call.name}';
      }
    } catch (e) {
      return '工具执行失败: $e';
    }
  }

  // ---------------- 插件工具 ----------------

  /// 插件工具兜底分支：confirm 标记为 true 时先请求用户确认，
  /// 确认后 POST /api/plugins/agent/exec {"name": 全名, "args"}。
  Future<String> _runPluginTool(
    PluginAiTool tool,
    AiToolCall call,
    ToolRecord rec,
  ) async {
    if (tool.confirm) {
      final approved = await _confirmPluginTool(tool.name, call.arguments);
      if (!approved) {
        rec.approved = false;
        changed();
        return '用户拒绝了插件工具 ${tool.name} 的调用。请停止该操作并向用户说明。';
      }
    }
    final r = await ApiClient.instance.post(
      '/api/plugins/agent/exec',
      body: {'name': tool.name, 'args': call.arguments},
    );
    final result = r is Map ? r['result'] : r;
    if (result == null) return '';
    return result.toString();
  }

  Future<bool> _confirmDomainChange(String title, String diffText) async {
    if (fullAccess) return true;
    final h = _host;
    if (h == null) return false;
    return h.confirm(title, diffText, AiConfirmKind.domain);
  }

  Future<bool> _confirmImageAction(String title, String detailText) async {
    if (fullAccess) return true;
    final h = _host;
    if (h == null) return false;
    return h.confirm(title, detailText, AiConfirmKind.image);
  }

  /// 插件工具确认（对齐图片审批：不可点背景关闭）。完全访问模式直接放行。
  Future<bool> _confirmPluginTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (fullAccess) return true;
    final h = _host;
    if (h == null) return false;
    return h.confirm(
      '确认调用插件工具',
      '【工具】$toolName\n\n【参数】\n${jsonEncode(args)}',
      AiConfirmKind.plugin,
    );
  }

  /// ask_user 提问：AI 主动向用户提问并等待回答（答案回填给模型）。
  /// 与写操作审批不同：不检查 fullAccess——完全访问模式同样要问。
  Future<String> _askUser(String question, List<String> options) async {
    final h = _host;
    if (h == null) return '用户未回答';
    return h.ask(question, options);
  }

  void _toast(String message) => _host?.toast(message);

  // ---------------- 图片生成（openai-image-api） ----------------

  /// web 托管形态（policy.tts_image_available=false，密钥不在服务端）下
  /// 拦截生图/改图工具；非拦截返回 null。桌面恒 null（不拉 policy）。
  String? _imageToolBlockedHint() {
    if (kIsWeb && !webPolicy.ttsImageAvailable) {
      return '$kAiTtsImageDisabledHint：generate_image/edit_image 不可用，'
          '请告知用户该部署未开启服务端生图能力。';
    }
    return null;
  }

  /// generate_image 工具：审批 → 调 OpenAI images/generations → 保存到模组 Art/ai/。
  Future<String> _runGenerateImage(AiToolCall call, ToolRecord rec) async {
    final blocked = _imageToolBlockedHint();
    if (blocked != null) return blocked;
    final prompt = (call.arguments['prompt'] as String?)?.trim() ?? '';
    if (prompt.isEmpty) return '错误：缺少 prompt（图片内容描述）参数';
    final n = _clampInt(call.arguments['n'], 1, 10, 1);
    final size = (call.arguments['size'] as String?)?.trim() ?? '';
    final quality = (call.arguments['quality'] as String?)?.trim() ?? '';
    final style = (call.arguments['style'] as String?)?.trim() ?? '';
    final background = (call.arguments['background'] as String?)?.trim() ?? '';
    final model = (call.arguments['model'] as String?)?.trim() ?? '';

    final detail = StringBuffer('【生成内容】\n$prompt\n\n');
    detail.writeln('【数量】$n 张');
    if (size.isNotEmpty) detail.writeln('【尺寸】$size');
    if (quality.isNotEmpty) detail.writeln('【质量】$quality');
    if (style.isNotEmpty) detail.writeln('【风格】$style');
    if (background.isNotEmpty) detail.writeln('【背景】$background');
    detail.writeln(
      '【模型】${model.isEmpty ? settings.effectiveImageModel : model}',
    );
    detail.writeln(
      '\n将调用 OpenAI Images API（images/generations）生成图片，'
      '完成后自动保存到当前模组的 Art/ai/ 目录。注意：调用图片服务会消耗 API 额度（产生费用），请确认内容无误后再允许。',
    );

    final approved = await _confirmImageAction('AI 请求生成图片', detail.toString());
    if (!approved) {
      rec.approved = false;
      changed();
      return '用户拒绝了图片生成请求。请停止该操作并向用户说明。';
    }

    try {
      // 生图是最容易超 5 分钟的长任务：async=1 + 轮询，maxWait 600s。
      final r = await ApiClient.instance.runLongTask(
        '/api/ai/image/generate',
        body: {
          'api_key': settings.effectiveImageApiKey,
          'base_url': settings.effectiveImageBaseUrl,
          'model': model.isEmpty ? settings.effectiveImageModel : model,
          'prompt': prompt,
          'n': n,
          if (size.isNotEmpty) 'size': size,
          if (quality.isNotEmpty) 'quality': quality,
          if (style.isNotEmpty) 'style': style,
          if (background.isNotEmpty) 'background': background,
        },
        timeout: const Duration(seconds: 300),
        maxWait: const Duration(seconds: 600),
      );
      final images = r['images'] as List? ?? [];
      if (images.isEmpty) return '图片服务未返回任何图片';
      final paths = <String>[];
      final saved = <String>[];
      final ts = _aiImageTs();
      for (var i = 0; i < images.length; i++) {
        final img = images[i] as Map<String, dynamic>;
        final b64 = img['b64'] as String? ?? '';
        if (b64.isEmpty) continue;
        final rel = 'Art/ai/${ts}_${i + 1}.png';
        final write = await ApiClient.instance.put(
          '/api/tools/write',
          body: {'scope': 'mod', 'path': rel, 'content': b64, 'base64': true},
        );
        final savedPath = (write['path'] as String?) ?? rel;
        paths.add(savedPath);
        saved.add(savedPath);
      }
      if (saved.isEmpty) return '图片生成成功但保存失败（无有效图片数据）';
      rec.images.addAll(saved);
      changed();
      return '已生成并保存 ${saved.length} 张图片到模组：\n'
          '${saved.join('\n')}\n'
          '（路径可用于 update_domain_item 写入配置，如 BgCfg 的 url 字段）';
    } catch (e) {
      return '图片生成失败: $e';
    }
  }

  /// edit_image 工具：读取模组图片 → 审批 → 调 OpenAI images/edits → 保存。
  Future<String> _runEditImage(AiToolCall call, ToolRecord rec) async {
    final blocked = _imageToolBlockedHint();
    if (blocked != null) return blocked;
    final image = (call.arguments['image'] as String?)?.trim() ?? '';
    final prompt = (call.arguments['prompt'] as String?)?.trim() ?? '';
    final mask = (call.arguments['mask'] as String?)?.trim() ?? '';
    final n = _clampInt(call.arguments['n'], 1, 10, 1);
    final size = (call.arguments['size'] as String?)?.trim() ?? '';
    final model = (call.arguments['model'] as String?)?.trim() ?? '';
    if (image.isEmpty) return '错误：缺少 image（要修改的图片路径）参数';
    if (prompt.isEmpty) return '错误：缺少 prompt（修改指令）参数';

    // 读取要修改的图片与可选蒙版（均为模组内相对路径）
    Map<String, dynamic>? imgData;
    Map<String, dynamic>? maskData;
    try {
      imgData = await ApiClient.instance.get(
        '/api/tools/read',
        query: {'scope': 'mod', 'path': image},
      );
      if (mask.isNotEmpty) {
        maskData = await ApiClient.instance.get(
          '/api/tools/read',
          query: {'scope': 'mod', 'path': mask},
        );
      }
    } catch (e) {
      return '读取图片失败（$image）：$e';
    }
    final imageB64 = imgData?['base64'] as String?;
    if (imageB64 == null || imageB64.isEmpty) {
      return '错误：$image 不是可读取的图片文件（需要 png/jpg 等二进制图片）';
    }
    final maskB64 = (maskData?['base64'] as String?)?.isNotEmpty == true
        ? maskData!['base64'] as String
        : null;

    final detail = StringBuffer('【修改对象】$image\n');
    if (mask.isNotEmpty) detail.writeln('【蒙版】$mask');
    detail.writeln('【修改指令】\n$prompt\n');
    detail.writeln('【数量】$n 张');
    if (size.isNotEmpty) detail.writeln('【尺寸】$size');
    detail.writeln(
      '【模型】${model.isEmpty ? settings.effectiveImageModel : model}',
    );
    detail.writeln(
      '\n将调用 OpenAI Images API（images/edits）修改图片，'
      '完成后自动保存到当前模组的 Art/ai/ 目录。注意：调用图片服务会消耗 API 额度（产生费用），请确认内容无误后再允许。',
    );

    final approved = await _confirmImageAction('AI 请求修改图片', detail.toString());
    if (!approved) {
      rec.approved = false;
      changed();
      return '用户拒绝了图片修改请求。请停止该操作并向用户说明。';
    }

    try {
      // 改图同样走长任务轮询：上传 base64 大图 + 上游编辑常超时。
      final r = await ApiClient.instance.runLongTask(
        '/api/ai/image/edit',
        body: {
          'api_key': settings.effectiveImageApiKey,
          'base_url': settings.effectiveImageBaseUrl,
          'model': model.isEmpty ? settings.effectiveImageModel : model,
          'prompt': prompt,
          'image_base64': imageB64,
          'mask_base64': ?maskB64,
          'n': n,
          if (size.isNotEmpty) 'size': size,
        },
        timeout: const Duration(seconds: 300),
        maxWait: const Duration(seconds: 600),
      );
      final images = r['images'] as List? ?? [];
      if (images.isEmpty) return '图片服务未返回任何图片';
      final saved = <String>[];
      final ts = _aiImageTs();
      for (var i = 0; i < images.length; i++) {
        final img = images[i] as Map<String, dynamic>;
        final b64 = img['b64'] as String? ?? '';
        if (b64.isEmpty) continue;
        final rel = 'Art/ai/${ts}_edit_${i + 1}.png';
        final write = await ApiClient.instance.put(
          '/api/tools/write',
          body: {'scope': 'mod', 'path': rel, 'content': b64, 'base64': true},
        );
        saved.add((write['path'] as String?) ?? rel);
      }
      if (saved.isEmpty) return '图片修改成功但保存失败（无有效图片数据）';
      rec.images.addAll(saved);
      changed();
      return '已修改并保存 ${saved.length} 张图片到模组：\n${saved.join('\n')}';
    } catch (e) {
      return '图片修改失败: $e';
    }
  }

  /// 整数参数规整：空/非法用 [def]，否则 clamp 到 [min, max]。
  int _clampInt(dynamic v, int min, int max, int def) {
    if (v is num) {
      return (v.toInt()).clamp(min, max);
    }
    if (v is String) {
      final i = int.tryParse(v.trim());
      if (i != null) return i.clamp(min, max);
    }
    return def;
  }

  /// 生成时间戳文件名前缀（本地时间，秒级 + 随机避免并发冲突）。
  String _aiImageTs() {
    final now = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    return 'ai_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${Random().nextInt(900) + 100}';
  }

  /// 两个 JSON 对象的行级 diff（- 删除行 / + 新增行 / 相同行保留）。
  String _diffJson(Map<String, dynamic> oldData, Map<String, dynamic> newData) {
    final keys = <String>{...oldData.keys, ...newData.keys};
    final buf = StringBuffer();
    for (final k in keys.toList()..sort()) {
      final ov = jsonEncode(oldData[k]);
      final nv = jsonEncode(newData[k]);
      if (oldData.containsKey(k) && newData.containsKey(k) && ov == nv) {
        buf.writeln('  "$k": $ov,');
      } else {
        if (oldData.containsKey(k)) buf.writeln('- "$k": $ov,');
        if (newData.containsKey(k)) buf.writeln('+ "$k": $nv,');
      }
    }
    return buf.toString();
  }
}

/// MCP 服务器首次连接确认名单（安全批次 B）：stdio 传输会在本机拉起子进程
/// 执行任意命令，因此「允许连接」过的服务器 id 持久化到 SharedPreferences
/// （与 [AiChannelPrefs] 同款存储），后续连接不再询问。用户拒绝不持久化，
/// 仅本次运行内跳过，下次启动重新询问。
class McpAllowPrefs {
  McpAllowPrefs._();

  static const _key = 'ai_mcp_allowed_v1';

  static Future<Set<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_key) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> allow(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allowed = (prefs.getStringList(_key) ?? const <String>[]).toSet()
        ..add(id);
      await prefs.setStringList(_key, allowed.toList()..sort());
    } catch (_) {}
  }
}

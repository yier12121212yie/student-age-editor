import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/history_client.dart';
import '../../core/models.dart';
import '../editor/field_meta.dart';
import '../editor/suggestion_text_field.dart';
import 'story_flow_clipboard.dart';
import 'story_flow_field_codec.dart';
import 'story_flow_graph.dart';
import 'story_flow_inspector.dart';
import 'story_flow_minimap.dart';
import 'story_flow_history.dart';
import 'story_flow_models.dart';
import 'story_flow_relayout.dart';
import 'story_flow_node_presets.dart';
import 'story_flow_side_toolbar.dart';
import 'story_flow_suggest.dart';
import 'story_logic.dart';

/// C7 观测计数：evtTitles 派生扫描过的 EvtCfg 行数（kDebugMode 才累加）。
/// 准出：跨多次 _bumpGraph 保持不变（标题只随 EvtCfg 重载重算）。
int debugEvtCfgTitleRows = 0;

/// 剧情图模式工作区：满铺流程图画布 + 浮动层（事件切换器、操作簇、
/// 左侧工具栏、媒体资产面板），节点内联展开编辑参数。
///
/// 数据流（S3 去整表往返）：启动只全量拉 6 张小表，Talk/Option 只探
/// meta（mtime）→ 切事件用 `?prefix=` 拉该事件的两小批 + stageOf 切舞台副本 →
/// 编辑副本 → diffStage 推导增量补丁，`PUT {patch, if_match}` 行级乐观锁写回。
/// 节点位置持久化到 `<mod根>/.editor_flow.json`（游戏不读取该文件）。
class StoryFlowWorkspace extends StatefulWidget {
  const StoryFlowWorkspace({
    super.key,
    required this.state,
    required this.onPreview,
    this.aiOpen = false,
    this.onToggleAi,
    required this.onOpenPlugins,
    required this.onOpenSettings,
  });

  final AppState state;

  /// 事件 id → 打开场景预览（宿主打开 OpenDoc.preview）。
  final ValueChanged<String> onPreview;

  /// AI 侧栏开关状态与切换（透传外壳的 AiPanel 控制）。
  final bool aiOpen;
  final VoidCallback? onToggleAi;

  /// 插件页 / 设置页入口（外壳切换内容栈视图）。
  final VoidCallback onOpenPlugins;
  final VoidCallback onOpenSettings;

  @override
  State<StoryFlowWorkspace> createState() => _StoryFlowWorkspaceState();
}

class _StoryFlowWorkspaceState extends State<StoryFlowWorkspace> {
  static const _tables = [
    'EvtCfg',
    'TalkCfg',
    'OptionCfg',
    'PersonCfg',
    'BgCfg',
    'AudioCfg',
    'EvtTypeCfg',
    'CGCfg',
  ];

  final _graphKey = GlobalKey<StoryFlowGraphState>();
  final Map<String, TextEditingController> _ctls = {};
  final List<TextEditingController> _allCtls = [];

  /// 与 [_ctls] 同键的焦点节点：补全输入框把按键处理挂在 FocusNode 上，
  /// 生命周期必须与控制器一致，否则摘掉控制器会留下悬空焦点。
  final Map<String, FocusNode> _focuses = {};

  /// 图数据缓存：`_graph` 原为每次 build 全量重算的 getter，拖拽一帧即重建
  /// 整张图（bench B2：buildFlowGraph 1.0 次/帧）。仅舞台内容/卡型声明变化时
  /// 置空，纯移动节点不失效——位置不属于图数据。
  FlowGraph? _cachedGraph;

  /// C5：内联字段元数据缓存（key=节点 id）。作废点只有 [_bumpGraph]。
  final Map<String, List<FieldMeta>> _inlineMetasCache = {};

  /// 位置版本：[_positions] 原地修改、身份永不变，`shouldRepaint` 无从比较，
  /// 此前连线能跟随节点纯粹是「graph 身份每帧都变」的副作用。缓存 graph 后
  /// 必须显式把它交给画布，否则拖拽时连线会静止。
  /// C10：改为 ValueNotifier，拖拽帧经画布内的 ValueListenableBuilder 直达
  /// 画布，不再触发宿主 setState 全 Stack 重绘（debugWorkspaceBuilds 准出：
  /// 拖拽 30 帧 == 0）。
  final ValueNotifier<int> _positionsRev = ValueNotifier(0);

  /// 事件 id 排序结果（每次 build 排 3,154 个 key 是纯浪费）。
  List<String> _sortedEventIds = const [];

  // 全量表（GET /api/cfg 的 data）
  final Map<String, Map<String, dynamic>> _tablesData = {};

  /// 插件流程卡片声明（GET /api/plugins/ui/flow_cards）。
  List<Map<String, dynamic>> _flowCards = [];
  bool _loading = true;
  String _error = '';

  // 当前事件舞台
  String? _evtId;
  List<String> _prefixes = const [];
  Map<String, dynamic> _stageTalks = {};
  Map<String, dynamic> _stageOpts = {};
  Map<String, dynamic> _talkBaseline = {};
  Map<String, dynamic> _optBaseline = {};

  /// 「脏」标记同时是图缓存的失效钩子：所有改动舞台内容的路径（加删边、
  /// 加删节点、字段编辑、资产落到字段、丢弃修改、切事件）都会给 `_dirty`
  /// 赋值，而纯移动节点的 `_onMoveNode` 恰恰不碰它 —— 这正是「内容变了」与
  /// 「只是位置变了」的分界。借此把 12 处散落的失效收敛成一处，且只可能
  /// 过度失效（等价于改动前的行为），不可能漏。
  bool _stageDirty = false;
  bool get _dirty => _stageDirty;
  set _dirty(bool v) {
    _stageDirty = v;
    _bumpGraph();
  }

  /// 未保存改动的撤销栈（后端 /api/history 只覆盖已保存内容，见该类注释）。
  final FlowEditHistory _history = FlowEditHistory();

  /// 子图剪贴板（纯内存）：记录 + 原坐标，粘贴时重分配 id 并整体偏移。
  Map<String, dynamic> _clipTalks = {};
  Map<String, dynamic> _clipOpts = {};
  Map<String, Offset> _clipPos = {};

  bool get _hasClip => _clipTalks.isNotEmpty || _clipOpts.isNotEmpty;

  /// 内容变更的唯一入口：标脏（顺带作废图缓存）+ 记一步可撤销快照。
  /// 撤销/重做回滚时**不要**走这里，直接赋值 `_dirty`，否则回滚会被记成新改动。
  void _markEdited({Object? mergeKey}) {
    _dirty = true;
    _bumpGraph();
    _history.record(_stageTalks, _stageOpts, _positions, mergeKey: mergeKey);
  }

  /// 事件切换 / Mod 切换的进行中标记：两条链路都含「脏数据确认弹窗 +
  /// 网络请求」多个 await，期间芯片仍可点击；不拦截会出现两次切换交错、
  /// _tablesData 与 .editor_flow.json 来自不同 Mod 的串档写入。
  bool _transitioning = false;

  /// 当前画布数据所对应的 modRoot。外部切换（模组页 / AI 面板的
  /// setMod）不走 _switchMod，workspace 保活状态下仍持旧 Mod 的全表
  /// 缓存，此时点保存会把旧 Mod 数据写进新 Mod——监听 AppState 检测。
  String? _loadedModRoot;

  /// 外部切换确认弹窗里用户选择「暂不重载」时记下该 root：
  /// 后续其它 AppState 通知（AA 轮询等）不再重复弹窗；保存被 _save 拒绝。
  String? _externalModRefusedRoot;

  /// GET /api/cfg 返回的各表 mtime_ns：保存时回传做乐观锁冲突检测。
  final Map<String, int?> _tableMtime = {};

  // 节点位置
  Map<String, Offset> _positions = {};
  Map<String, dynamic> _flowFile = {};
  Timer? _layoutSaveTimer;

  /// `.editor_flow.json` 是否已加载完成；就绪前禁止回写布局，
  /// 避免用空壳数据覆盖其他事件已保存的节点坐标。
  bool _flowLoaded = false;

  // 选中集（画布支持多选/框选；详情面板与内联编辑只在单选时可用）
  FlowSelection _selection = FlowSelection.none;
  String? get _selectedNode => _selection.onlyNode;

  /// 小地图要订阅画布视口，而视口 notifier 活在画布 State 里、首帧才存在：
  /// 拿到后 setState 一次即可（notifier 身份在画布存活期内不变）。
  ValueListenable<FlowViewport>? _vpListen;
  final ValueNotifier<FlowViewport> _vpIdle = ValueNotifier(
    const FlowViewport(1, Offset.zero),
  );

  /// 新节点落点：多选时取最近加入选中集的那一个，否则框选完再添加会掉回左上角。
  Offset get _addAnchor {
    for (final id in _selection.nodes.toList().reversed) {
      final p = _positions[id];
      if (p != null) return p;
    }
    return const Offset(60, 40);
  }

  // 内联编辑展开的节点
  final Set<String> _expandedNodes = {};

  /// 写回失败的字段，键为 `nodeId|field`（卡片/面板红字提示）。
  ///
  /// 只放「填坏了」，不放「还没填」：必填未填走 [_requiredMissing]，混在
  /// 一起会让用户把空白字段读成损坏字段。
  final Set<String> _fieldInvalid = {};

  /// 字段元数据按表缓存：一次 21 个 key，重算纯属浪费。
  final Map<String, List<FieldMeta>> _metasCache = {};

  // 右侧 Inspector：仅单选非 missing 节点时出现
  bool _inspectorOpen = false;
  bool _inspectorAdvanced = false;

  // 媒体资产
  bool _assetsOpen = false;
  String? _dragHoverNode;

  @override
  void initState() {
    super.initState();
    _loadedModRoot = widget.state.modRoot;
    widget.state.addListener(_onAppStateChanged);
    // 注册切模式守卫：app.dart 用 ValueKey(uiMode) 重建整壳，
    // 不拦截的话未保存的舞台修改与 800ms 内待落盘的布局会被无声吞掉
    widget.state.leaveGuard = _confirmLeaveGuard;
    _init();
  }

  @override
  void dispose() {
    if (widget.state.leaveGuard == _confirmLeaveGuard) {
      widget.state.leaveGuard = null;
    }
    widget.state.removeListener(_onAppStateChanged);
    // _vpListen 归画布 State 所有，不能在这里 dispose。
    _vpIdle.dispose();
    _positionsRev.dispose();
    // 防抖中的布局回写必须立即冲刷：直接 cancel 会吞掉最近 800ms 的
    // 节点移动（切 UI 模式 / 关窗口时最后几次拖拽丢失）
    final pending = _layoutSaveTimer;
    _layoutSaveTimer = null;
    if (pending?.isActive ?? false) {
      unawaited(_writeLayoutFile());
    }
    for (final c in _allCtls) {
      c.dispose();
    }
    for (final f in _focuses.values) {
      f.dispose();
    }
    // 延后回收的批次：postFrame 回调卸载后会被 mounted 判断跳过，这里兜底。
    for (final c in _retiredCtls) {
      c.dispose();
    }
    for (final f in _retiredFocuses) {
      f.dispose();
    }
    _retiredCtls.clear();
    super.dispose();
  }

  /// 切 UI 模式的守卫：脏数据先弹「保存 / 放弃 / 取消」，
  /// 返回 false 表示放弃切换（壳不重建）。
  Future<bool> _confirmLeaveGuard() async {
    if (!_dirty) return true;
    final action = await _confirmDirtyDiscard(what: '切换界面模式');
    if (!mounted || action == null) return false;
    if (action == 'discard') {
      _discardStage();
      return true;
    }
    return await _save();
  }

  /// 监听外部 setMod（模组页 / AI 面板）：服务端沙箱根已切，
  /// 画布的 _tablesData/_flowFile 仍是旧 Mod 的，保存会串档污染新 Mod。
  void _onAppStateChanged() {
    if (!mounted) return;
    if (widget.state.modRoot == _loadedModRoot) return;
    if (_transitioning) return; // 自家 _switchMod 链路在途（其内部也调 setMod）
    if (widget.state.modRoot == _externalModRefusedRoot) return; // 用户选了暂不重载
    _reloadForExternalMod();
  }

  Future<void> _reloadForExternalMod() async {
    _transitioning = true;
    try {
      if (_dirty) {
        // 服务端根已切走，此时保存必写进别的 Mod，只能放弃舞台
        final action = await fluent.showDialog<String>(
          context: context,
          builder: (ctx) => fluent.ContentDialog(
            title: const Text('Mod 已被外部切换'),
            content: Text(
              '当前画布仍显示旧 Mod 的未保存修改，但保存目标已随 Mod 切换变更，'
              '继续编辑会把旧数据写进新 Mod。是否放弃这些修改并重载？',
              style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, 'later'),
                child: const Text('先留在旧画面'),
              ),
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, 'discard'),
                child: const Text('放弃并重载'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (action != 'discard') {
          _externalModRefusedRoot = widget.state.modRoot;
          _toast('画布已陈旧，保存被禁止直到重载新 Mod', fluent.InfoBarSeverity.warning);
          return;
        }
        _discardStage();
      }
      await _reloadForMod();
      if (!mounted) return;
      _toast(
        '已跟随外部切换到 Mod：${widget.state.modName}',
        fluent.InfoBarSeverity.success,
      );
    } finally {
      if (mounted) _transitioning = false;
    }
  }

  // ---------- 数据层 ----------
  /// 先加载布局文件再加载配置表：`_load` 完成后要按 `_flowFile` 恢复
  /// 节点位置，且布局未就绪前禁止回写，两步必须串行不能并行。
  Future<void> _init() async {
    // 首帧渲染后加载仍在进行，芯片已可点击；持门防止加载未完时切换串档
    _transitioning = true;
    try {
      await _loadFlowFile();
      if (!mounted) return;
      await _load();
      if (mounted) _loadedModRoot = widget.state.modRoot;
    } finally {
      _transitioning = false;
    }
  }

  int? _asInt(dynamic v) => v is num ? v.toInt() : null;

  Map<String, dynamic> _asDataMap(dynamic raw) => raw is Map
      ? {for (final e in raw.entries) e.key.toString(): e.value}
      : {};

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      // S3：TalkCfg/OptionCfg 只探 meta（mtime），不再拉 9.8 万行全表；
      // 舞台数据改由 _selectEventInner 的 ?prefix= 小批量按需加载。
      final results = await Future.wait([
        for (final t in _tables)
          ApiClient.instance.get(
            '/api/cfg/$t',
            query: (t == 'TalkCfg' || t == 'OptionCfg') ? {'meta': '1'} : null,
          ),
      ]);
      _tablesData.remove('TalkCfg');
      _tablesData.remove('OptionCfg');
      for (var i = 0; i < _tables.length; i++) {
        final t = _tables[i];
        // meta 响应没有 data 键：只有真拉到 data 的小表才进全表缓存
        if (results[i]['data'] != null) {
          _tablesData[t] = _asDataMap(results[i]['data']);
        }
        // 记下磁盘版本号，保存时回传做乐观锁
        _tableMtime[t] = _asInt(results[i]['mtime_ns']);
      }
      // 卡型声明：插件 flow_cards 在前、内置节点预设在后（first-match 即插件优先）
      List<Map<String, dynamic>> pluginCards = [];
      try {
        final fc = await ApiClient.instance.get('/api/plugins/ui/flow_cards');
        final list = fc['flow_cards'];
        pluginCards = list is List
            ? [
                for (final c in list)
                  if (c is Map) Map<String, dynamic>.from(c),
              ]
            : [];
      } catch (_) {
        pluginCards = [];
      }
      _flowCards = [...pluginCards, ...builtinFlowCardSpecs()];
      _bumpGraph(); // 卡型声明参与节点着色/命名，不属 _dirty 覆盖面
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshEventList();
        });
        if (_sortedEventIds.isNotEmpty) {
          await _selectEventInner(_sortedEventIds.first);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载配置失败: $e';
        });
      }
    }
  }

  /// 读取 .editor_flow.json。必须区分三种失败：
  ///  - 400（文件不存在 / 沙箱拒绝）：合法的「空布局」，就绪可回写；
  ///  - JSON 损坏：按空布局修复（下次回写覆盖为有效内容），就绪；
  ///  - 其余（5xx / 网络 / 超时）：**不得**就绪——此前一律当空布局且置
  ///    就绪，下一次拖节点的全量回写会清掉其他事件已保存的全部坐标。
  Future<void> _loadFlowFile() async {
    var ready = false;
    Object? ioError;
    try {
      final r = await ApiClient.instance.get(
        '/api/tools/read',
        query: {'path': '.editor_flow.json'},
      );
      ready = true;
      final text = r['text'];
      if (text is String && text.trim().isNotEmpty) {
        try {
          final parsed = jsonDecode(text);
          if (parsed is Map) {
            _flowFile = Map<String, dynamic>.from(parsed);
          }
        } catch (_) {
          // 损坏 JSON：保持空布局并照常就绪（自动修复语义）
        }
      }
    } on ApiException catch (e) {
      if (e.statusCode == 400) {
        ready = true; // 不存在/沙箱拒绝：空布局是正解
      } else {
        ioError = e;
      }
    } catch (e) {
      ioError = e;
    }
    _flowLoaded = ready;
    if (!ready && mounted) {
      _toast(
        '节点布局文件读取失败（$ioError），坐标暂不会回写以防清档',
        fluent.InfoBarSeverity.warning,
      );
    }
  }

  void _persistLayout() {
    _layoutSaveTimer?.cancel();
    // 异步回调必须 await+捕获：Future 里的 HTTP 异常逃不出同步 try，
    // 之前写盘失败被彻底吞掉，布局静默丢失。
    _layoutSaveTimer = Timer(const Duration(milliseconds: 800), () {
      _layoutSaveTimer = null;
      unawaited(_writeLayoutFile());
    });
  }

  Future<void> _writeLayoutFile() async {
    // 序列化推迟到这里结算（C3）：拖拽期间每帧只有 _positionsRev.value++，
    // 全量坐标复制只发生在真正回写前的一次。
    _settleDirtyPositions();
    // 先取快照再写：连续触发时不携带在途写入之后才产生的改动
    final content = jsonEncode(_flowFile);
    try {
      await ApiClient.instance.put(
        '/api/tools/write',
        body: {'path': '.editor_flow.json', 'content': content},
      );
      // ignore: invalid_use_of_visible_for_testing_member
      if (kDebugMode) debugLayoutSnapshots++;
    } catch (e) {
      if (mounted) {
        _toast('布局保存失败（节点位置未落盘）: $e', fluent.InfoBarSeverity.warning);
      }
    }
  }

  // ---------- 事件选择 ----------
  /// 脏数据守卫：弹窗确认「保存 / 放弃 / 取消」。返回 false 表示调用方
  /// 应中止本次切换/进入流程。调用方需自行持有 [_transitioning] 门。
  Future<bool> _confirmDirtyGate() async {
    if (!_dirty) return true;
    final action = await _confirmDirtyDiscard();
    if (!mounted || action == null) return false;
    if (action == 'discard') {
      _discardStage();
      return true;
    }
    return await _save();
  }

  Future<void> _selectEvent(String evtId) async {
    if (evtId == _evtId || _transitioning) return;
    _transitioning = true;
    try {
      if (!await _confirmDirtyGate()) return;
      if (mounted) await _selectEventInner(evtId);
    } finally {
      _transitioning = false;
    }
  }

  /// 全局切换 Mod：未保存修改先确认，POST /api/mods/select 成功后同步
  /// AppState，并重载布局文件与配置表（事件列表/舞台数据/保存目标
  /// 全部随新 mod 根切换，与模组页、AI 面板的切换语义一致）。
  Future<void> _switchMod(String name) async {
    if (name == widget.state.modName || _transitioning) return;
    _transitioning = true;
    try {
      if (!await _confirmDirtyGate()) return;
      try {
        final r = await ApiClient.instance.post(
          '/api/mods/select',
          body: {'name': name},
        );
        final mod = r['mod'];
        if (mod is! Map) throw '响应缺少 mod 字段';
        if (!mounted) return;
        widget.state.setMod(
          mod['name'] as String? ?? name,
          mod['root'] as String? ?? '',
        );
        await _reloadForMod();
        if (!mounted) return;
        if (_error.isNotEmpty) {
          // select 成功但表重载失败（_load 吞错进 _error）：
          // 无区分地弹成功 toast 会误导用户在坏数据上继续编辑
          _toast(
            '已切换到 Mod「$name」，但数据重载失败：$_error',
            fluent.InfoBarSeverity.error,
          );
        } else {
          _toast('已切换到 Mod：$name', fluent.InfoBarSeverity.success);
        }
      } catch (e) {
        if (!mounted) return;
        _toast('切换 Mod 失败: $e', fluent.InfoBarSeverity.error);
      }
    } finally {
      _transitioning = false;
    }
  }

  /// 按当前 AppState.modRoot 重建画布全部上下文：停掉指向旧 Mod 沙箱的
  /// 布局回写、清舞台/控制器/布局缓存，串行重载布局文件与 8 表。
  /// _switchMod（自家切换）与 _reloadForExternalMod（外部切换）共用。
  Future<void> _reloadForMod() async {
    // 取消防抖中的布局回写：该写入指向旧 mod 的沙箱，切换后不得串档
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = null;
    // 清掉旧 mod 的舞台残留：新 mod 若无事件，_load 不会自动选中
    _evtId = null;
    _prefixes = const [];
    _stageTalks = {};
    _stageOpts = {};
    _talkBaseline = {};
    _optBaseline = {};
    _dirty = false;
    _flowFile = {};
    _flowLoaded = false;
    // Mod 整体重置：旧 Mod 的待结算坐标一并作废（C3）
    _layoutDirtyEvent = null;
    _positions = {};
    _selection = FlowSelection.none;
    _expandedNodes.clear();
    _fieldInvalid.clear();
    _dragHoverNode = null;
    _tableMtime.clear();
    _inspectorOpen = false;
    // schema/keyMaps 随 Mod 变，缓存过的字段元数据一律作废
    _invalidateMetas();
    // 字段控制器按「事件|节点|字段」缓存，Mod 间同 id 普遍存在，
    // 不清会导致新 mod 的节点编辑区回显旧 mod 文本。
    _dropAllCtls();
    await _loadFlowFile();
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    _loadedModRoot = widget.state.modRoot;
    _externalModRefusedRoot = null;
  }

  String? _eventTitle(String id) {
    final e = _tablesData['EvtCfg']?[id];
    if (e is Map) {
      final t = cln(e['title']);
      if (t.isNotEmpty) return t;
    }
    return null;
  }

  void _discardStage() {
    _stageTalks = copyRecords(_talkBaseline);
    _stageOpts = copyRecords(_optBaseline);
    _resetPanelCtls();
    if (mounted) setState(() => _dirty = false);
    // 栈必须跟着重置，否则撤销会把刚刚「放弃」的改动整批拉回来。
    _history.seed(_stageTalks, _stageOpts, _positions);
  }

  /// 切事件的竞态防护令牌：两次切换并发在途时（脏确认 + 网络多个 await，
  /// 芯片/保存链路都可达），旧请求在每个 await 后作废。
  int _selectSeq = 0;

  Future<void> _selectEventInner(String evtId) async {
    final token = ++_selectSeq;
    // 必须赶在 _evtId 改值之前按旧前缀回收：控制器键里带事件 id，
    // 赋完值就再也摘不到上一批了（长会话下会无界堆积）。
    if (_evtId != null) _dropCtls('$_evtId|');
    // EvtCfg 仍在内存（启动全量加载、事件增删后同步），前缀同步可算。
    final prefixes = storyRelatedPrefixes(evtId, _tablesData['EvtCfg'] ?? const {});
    Map<String, dynamic> freshT = const {};
    Map<String, dynamic> freshO = const {};
    var fetchFailed = false;
    try {
      final p = prefixes.join(',');
      // S3：只拉该事件相关的两小批（对白 suffix=3 默认、选项 suffix=2），
      // 不再持有 Talk/Option 全表。
      final results = await Future.wait([
        ApiClient.instance.get('/api/cfg/TalkCfg', query: {'prefix': p}),
        ApiClient.instance.get(
          '/api/cfg/OptionCfg',
          query: {'prefix': p, 'suffix': '2'},
        ),
      ]);
      if (!mounted || token != _selectSeq) return;
      freshT = Map<String, dynamic>.from(results[0] as Map);
      freshO = Map<String, dynamic>.from(results[1] as Map);
      _tableMtime['TalkCfg'] =
          _asInt(freshT['mtime_ns']) ?? _tableMtime['TalkCfg'];
      _tableMtime['OptionCfg'] =
          _asInt(freshO['mtime_ns']) ?? _tableMtime['OptionCfg'];
    } catch (e) {
      if (!mounted || token != _selectSeq) return;
      // 与旧「表加载失败」等价：toast + 空舞台空基线，不让异常炸掉画布
      fetchFailed = true;
      _toast('加载事件数据失败: $e', fluent.InfoBarSeverity.error);
    }
    setState(() {
      _evtId = evtId;
      _prefixes = prefixes;
      if (fetchFailed) {
        _stageTalks = {};
        _stageOpts = {};
      } else {
        // ?prefix= 拉回的本身就是该事件行；stageOf 再过一遍是兜底：
        // MockClient / 旧后端忽略 query 返回全量时行为不变（等价性要求）。
        _stageTalks = stageOf(_asDataMap(freshT['data']), _prefixes);
        _stageOpts = stageOf(
          _asDataMap(freshO['data']),
          _prefixes,
          isOption: true,
        );
      }
      _talkBaseline = copyRecords(_stageTalks);
      _optBaseline = copyRecords(_stageOpts);
      _dirty = false;
      _selection = FlowSelection.none;
      _expandedNodes.clear();
      _fieldInvalid.clear();
      _inspectorOpen = false;
      _dragHoverNode = null;
      _loadPositionsForEvent();
    });
    _history.seed(_stageTalks, _stageOpts, _positions);
  }

  // ---------- 撤销 / 重做 ----------

  /// Ctrl+Z。两层：内存栈覆盖「改了没保存」，栈空且舞台干净时才落到后端
  /// 表级历史（后端快照只在存表时打点，且 Talk/Option 各一条独立栈）。
  Future<void> _undo() => _historyStep(_history.undo(), 'undo');

  Future<void> _redo() => _historyStep(_history.redo(), 'redo');

  Future<void> _historyStep(FlowEditSnapshot? step, String op) async {
    if (step != null) {
      // 内联输入框持有旧文案，只能整体作废重建（与切事件同一套做法）。
      _resetPanelCtls();
      setState(() {
        _stageTalks = step.talks;
        _stageOpts = step.opts;
        _positions = step.positions;
        _expandedNodes.removeWhere((id) => !_hasRecord(id));
        _fieldInvalid.removeWhere((k) => !_hasRecord(k.split('|').first));
        _selection = FlowSelection.none;
        // 回滚不走 _markEdited：否则撤销本身又被记成新的改动一步。
        _dirty =
            !sameStage(_stageTalks, _talkBaseline) ||
            !sameStage(_stageOpts, _optBaseline);
        _bumpGraph();
      });
      // 位置回滚要落盘，否则撤销回来的节点坐标下次载入就丢。
      _markLayoutDirty();
      return;
    }
    // 舞台还有未保存改动时禁止落到后端：整表回读会把没保存的编辑冲掉。
    if (_dirty) {
      _toast(
        '画布上没有更多可${op == 'undo' ? '撤销' : '重做'}的改动',
        fluent.InfoBarSeverity.warning,
      );
      return;
    }
    await _savedHistory(op);
  }

  bool _hasRecord(String id) =>
      _stageTalks.containsKey(id) || _stageOpts.containsKey(id);

  /// 展开/收起内联参数编辑器（卡片右下角箭头与右键菜单同一入口）。
  void _toggleExpand(String id) {
    setState(() {
      if (!_expandedNodes.remove(id)) _expandedNodes.add(id);
    });
  }

  /// 局部重排：只重铺选中集的诱导子图，包围盒左上角锚死在原位，
  /// 未选中的节点一个都不动（整图 auto layout 会毁掉手工布局）。
  void _relayoutSelection() {
    final ids = _selection.nodes;
    if (ids.length < 2) {
      _toast('先框选两个以上节点再重排', fluent.InfoBarSeverity.warning);
      return;
    }
    final next = relayoutSelection(
      graph: _graph,
      positions: _positions,
      selected: ids,
    );
    if (next.isEmpty) return;
    setState(() {
      _positions.addAll(next);
      // 快照含坐标，所以走 _markEdited：重排本身可以 Ctrl+Z 退回去。
      _markEdited();
    });
    // 位置是原地改的：这一步同时递增 positionsRev，连线才会跟着重绘。
    _markLayoutDirty();
  }

  /// 画布右键菜单。
  ///
  /// 用 Material `showMenu` + 显式不透明底板：`fluent.MenuFlyout` 的底板走
  /// FluentTheme 的半透明 Mica `cardColor`，而本 app 有全局透明 Material 祖先
  /// （app.dart），菜单悬浮在画布上时会直接透出节点与连线。
  Future<void> _onContextMenu(FlowContextTap tap) async {
    final box = _graphKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final p = box.localToGlobal(tap.screen, ancestor: overlay);
    final nodeId = tap.nodeId;
    final edge = tap.edge;
    // 右键点在选中组之外 = 改单选它：否则菜单里的复制/删除会作用在用户
    // 没指的那一批节点上。点在组内则保留整组（与左键一致）。
    if (nodeId != null && !_selection.nodes.contains(nodeId)) {
      setState(() => _selection = FlowSelection.ofNode(nodeId));
    }
    final batch = nodeId != null && _selection.nodes.length > 1;
    final items = <PopupMenuEntry<String>>[
      if (nodeId != null) ...[
        _menuItem(
          'toggle',
          _expandedNodes.contains(nodeId) ? '收起参数' : '展开编辑参数',
        ),
        _menuItem('copy', batch ? '复制 ${_selection.nodes.length} 个节点' : '复制'),
        _menuItem('paste', '粘贴', enabled: _hasClip),
        _menuItem(
          'relayout',
          '重排 ${_selection.nodes.length} 个节点',
          enabled: batch,
        ),
        _menuItem(
          'delete',
          batch ? '删除 ${_selection.nodes.length} 个节点' : '删除节点',
        ),
        _menuItem('separator', ''),
      ] else if (edge != null) ...[
        _menuItem(
          'delete',
          fieldForEdge(edge.kind) == null ? '终端跳转边（改选项的 nextEvtId）' : '删除连线',
          enabled: fieldForEdge(edge.kind) != null,
        ),
        _menuItem('separator', ''),
      ] else ...[
        _menuItem('paste', '粘贴', enabled: _hasClip),
        _menuItem('addTalk', '添加对白'),
        _menuItem('addOption', '添加选项'),
        _menuItem('separator', ''),
      ],
      _menuItem('undo', '撤销', enabled: _history.canUndo),
      _menuItem('redo', '重做', enabled: _history.canRedo),
      _menuItem('fit', '适应视图'),
    ];
    final picked = await showMenu<String>(
      context: context,
      color: palette.card,
      position: RelativeRect.fromLTRB(
        p.dx,
        p.dy,
        p.dx,
        overlay.size.height - p.dy,
      ),
      items: items,
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'toggle':
        if (nodeId != null) _toggleExpand(nodeId);
      case 'copy':
        _copySelection();
      case 'paste':
        _pasteClipboard();
      case 'relayout':
        _relayoutSelection();
      case 'delete':
        if (nodeId != null) {
          // 组内右键 = 整组删除，与 Delete 键同一条批量路径。
          if (batch) {
            _requestDelete();
          } else {
            _deleteNode(nodeId);
          }
        } else if (edge != null) {
          final field = fieldForEdge(edge.kind);
          if (field != null) _onDeleteEdge(edge.from, field, edge.to);
        }
      case 'undo':
        await _undo();
      case 'redo':
        await _redo();
      case 'fit':
        _graphKey.currentState?.fitView();
      case 'addTalk':
        _addTalkAfterSelected();
      case 'addOption':
        _addOptionForSelected();
    }
  }

  PopupMenuItem<String> _menuItem(
    String value,
    String label, {
    bool enabled = true,
  }) {
    if (value == 'separator') {
      return const PopupMenuItem<String>(
        enabled: false,
        height: 9,
        child: Divider(height: 1),
      );
    }
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: 32,
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppType.chip,
          color: enabled ? palette.textPrimary : palette.textFaint,
        ),
      ),
    );
  }

  /// 复制选中子图：存记录深拷贝，id 在粘贴时才重新分配（同 id 二次粘贴会撞号）。
  void _copySelection() {
    final ids = _selection.nodes;
    if (ids.isEmpty) {
      _toast('先选中节点再复制', fluent.InfoBarSeverity.warning);
      return;
    }
    _clipTalks = {
      for (final id in ids)
        if (_stageTalks[id] is Map)
          id: copyRecords(_stageTalks[id] as Map<String, dynamic>),
    };
    _clipOpts = {
      for (final id in ids)
        if (_stageOpts[id] is Map)
          id: copyRecords(_stageOpts[id] as Map<String, dynamic>),
    };
    _clipPos = {
      for (final id in ids)
        if (_positions[id] != null) id: _positions[id]!,
    };
    _toast(
      '已复制 ${_clipTalks.length + _clipOpts.length} 个节点',
      fluent.InfoBarSeverity.success,
    );
  }

  /// 粘贴剪贴板子图：新 ID 由舞台分配、指向选区外的连线剪断（见该函数注释），
  /// 坐标按副本原点整体偏移 +40 以便与原群区分。粘贴后选中新节点，可连续拖。
  void _pasteClipboard() {
    if (_clipTalks.isEmpty && _clipOpts.isEmpty) {
      _toast('剪贴板是空的', fluent.InfoBarSeverity.warning);
      return;
    }
    final mapping = cloneSubgraphInto(
      selected: {..._clipTalks.keys, ..._clipOpts.keys},
      talks: _stageTalks,
      opts: _stageOpts,
      prefixes: _prefixes,
      sourceTalks: _clipTalks,
      sourceOpts: _clipOpts,
    );
    if (mapping.isEmpty) {
      // 半份粘贴会留下没有来源的孤儿节点，所以失败时舞台一字不改。
      _toast('本事件的对白/选项编号已用尽，无法粘贴', fluent.InfoBarSeverity.error);
      return;
    }
    final pasted = <String>{};
    mapping.forEach((oldId, newId) {
      _positions[newId] =
          (_clipPos[oldId] ?? _addAnchor) + const Offset(40, 40);
      pasted.add(newId);
    });
    _markLayoutDirty();
    setState(() {
      _selection = FlowSelection(nodes: pasted);
      _markEdited();
    });
  }

  /// 已保存内容：两张表各探一次后端栈，都空才提示；成功后重读两表重建舞台。
  Future<void> _savedHistory(String op) async {
    final t = await historyOp(
      op,
      cfg: 'TalkCfg',
      context: context,
      quietEmpty: true,
    );
    if (!mounted) return;
    // D4：busy 是在途让路（Ctrl 连发/双表连探），不是空栈，静默放弃本次。
    if (t == HistoryOpResult.busy) return;
    final o = await historyOp(
      op,
      cfg: 'OptionCfg',
      context: context,
      quietEmpty: true,
    );
    if (!mounted) return;
    final applied =
        t == HistoryOpResult.applied || o == HistoryOpResult.applied;
    if (!applied) {
      // 两表都空才提示；真实失败已由 historyOp 弹条，不再叠加误导性空栈提示
      if (t != HistoryOpResult.failed && o != HistoryOpResult.failed) {
        _toast(
          '没有可${op == 'undo' ? '撤销' : '重做'}的已保存改动',
          fluent.InfoBarSeverity.warning,
        );
      }
      return;
    }
    if (!mounted || _evtId == null) return;
    try {
      // S3：后端已回滚，不再 GET 全表——直接走切事件的 ?prefix= 重建路径。
      // 不刷新 _tableMtime：后端 undo 后 mtime 已变，下次保存的行级
      // if_match 会兜住无关行的假冲突。
      // 与切事件同一条重建路径：基线、位置、栈都跟着重置。
      await _selectEventInner(_evtId!);
    } catch (e) {
      _toast('回滚后重载失败: $e', fluent.InfoBarSeverity.error);
    }
  }

  Future<String?> _confirmDirtyDiscard({String what = '切换事件'}) {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('未保存的修改'),
        content: Text(
          '当前事件的修改尚未保存，$what前要保存吗？',
          style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('放弃修改'),
          ),
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 保存：用 [diffStage] 把舞台相对基线的差异推导成增量补丁，随
  /// `PUT /api/cfg/<t>` 的 `patch` 字段发往后端（S3）。行级 if_match 深比对
  /// 精确保护被改的行（不回传全表、不带回全表）；**不带 expect_mtime_ns、
  /// 不 force**——表级 mtime 只会给无关行制造假冲突。行级冲突（409）弹
  /// 三选对话框：采用磁盘值 / 覆盖并重试 / 取消。
  ///
  /// EvtCfg 舞台从不修改（事件增删自落盘），不参与保存。
  Future<bool> _save({bool retried = false}) async {
    if (_evtId == null) return false;
    if (_loadedModRoot != null && widget.state.modRoot != _loadedModRoot) {
      // 外部切 Mod 后用户选了「先留在旧画面」：此时保存 = 旧数据写新沙箱
      _toast(
        'Mod 已在别处切换，画布仍为旧 Mod 数据，禁止保存——请重载后再试',
        fluent.InfoBarSeverity.error,
      );
      return false;
    }
    final talkPatch = diffStage(_talkBaseline, _stageTalks, _prefixes);
    final optPatch = diffStage(
      _optBaseline,
      _stageOpts,
      _prefixes,
      isOption: true,
    );
    if (talkPatch.isEmpty && optPatch.isEmpty) {
      // 无差异（基线 == 舞台）：不空发 PUT，按成功收尾
      setState(() => _dirty = false);
      _toast('已是最新', fluent.InfoBarSeverity.success);
      return true;
    }
    return _sendPatches(talkPatch, optPatch, retried: retried);
  }

  /// 单表补丁 PUT + 基线增量结算（绝不写舞台引用）。空补丁不发请求。
  Future<void> _putTablePatch(
    String cfg,
    StagePatch patch, {
    bool force = false,
  }) async {
    if (patch.isEmpty && !force) return;
    final resp = await ApiClient.instance.put(
      '/api/cfg/$cfg',
      body: {
        'patch': {'set': patch.set, 'remove': patch.remove},
        'if_match': patch.ifMatch,
        if (force) 'force': true,
      },
    );
    final baseline = cfg == 'TalkCfg' ? _talkBaseline : _optBaseline;
    final stage = cfg == 'TalkCfg' ? _stageTalks : _stageOpts;
    for (final k in patch.remove) {
      baseline.remove(k);
    }
    patch.set.forEach((k, v) => baseline[k] = copyRecordValue(stage[k] ?? v));
    _tableMtime[cfg] = _asInt(resp['mtime_ns']) ?? _tableMtime[cfg];
  }

  /// 两表串行发送（Talk → Option），保持原有顺序。单表成功即结算该表基线，
  /// 后一表失败/冲突时已落盘的改动不会在重试中被重复发送。
  Future<bool> _sendPatches(
    StagePatch talkPatch,
    StagePatch optPatch, {
    required bool retried,
    bool skipTalk = false,
    bool skipOpt = false,
  }) async {
    try {
      if (!skipTalk) {
        try {
          await _putTablePatch('TalkCfg', talkPatch);
        } on ApiException catch (e) {
          if (e.statusCode == 409 && !retried) {
            return await _handleSaveConflict(
              isOption: false,
              talkPatch: talkPatch,
              optPatch: optPatch,
            );
          }
          rethrow;
        }
      }
      if (!skipOpt) {
        try {
          await _putTablePatch('OptionCfg', optPatch);
        } on ApiException catch (e) {
          if (e.statusCode == 409 && !retried) {
            // Talk 已发送并结算：冲突恢复只处理 Option，不再重发 Talk
            return await _handleSaveConflict(
              isOption: true,
              talkPatch: talkPatch,
              optPatch: optPatch,
            );
          }
          rethrow;
        }
      }
    } on ApiException catch (e) {
      if (!mounted) return false;
      _toast(
        e.statusCode == 409
            ? '保存冲突：表在保存窗口内又被外部修改，画布修改未丢——请再点一次保存'
            : '保存失败: $e',
        fluent.InfoBarSeverity.error,
      );
      return false;
    } catch (e) {
      if (!mounted) return false;
      _toast('保存失败: $e', fluent.InfoBarSeverity.error);
      return false;
    }
    if (!mounted) return false;
    setState(() => _dirty = false);
    _toast('已保存', fluent.InfoBarSeverity.success);
    return true;
  }

  /// 409 行级冲突三选对话框（S3-4）。ApiException 只带 message 拿不到
  /// conflicting_keys：重拉该表 prefix 行，用 [_sameValue] 逐行比对
  /// ifMatch 基线值与磁盘现值，前端自己算出被外部改动的行。
  Future<bool> _handleSaveConflict({
    required bool isOption,
    required StagePatch talkPatch,
    required StagePatch optPatch,
  }) async {
    final cfg = isOption ? 'OptionCfg' : 'TalkCfg';
    final patch = isOption ? optPatch : talkPatch;
    Map<String, dynamic> fresh;
    try {
      fresh = await ApiClient.instance.get(
        '/api/cfg/$cfg',
        query: {'prefix': _prefixes.join(','), if (isOption) 'suffix': '2'},
      );
    } catch (e) {
      if (!mounted) return false;
      _toast('保存冲突，且读取磁盘最新值失败: $e', fluent.InfoBarSeverity.error);
      return false;
    }
    if (!mounted) return false;
    final disk = _asDataMap(fresh['data']);
    final conflicts = <(String, Map<String, dynamic>, Map<String, dynamic>)>[];
    patch.ifMatch.forEach((k, baseVal) {
      final diskVal = disk[k];
      if (!_sameValue(baseVal, diskVal)) {
        conflicts.add((
          k,
          baseVal is Map ? Map<String, dynamic>.from(baseVal) : const {},
          diskVal is Map ? Map<String, dynamic>.from(diskVal) : const {},
        ));
      }
    });
    if (conflicts.isEmpty) {
      // 理论上不会：ifMatch 全部仍与磁盘一致却报了行冲突，按 rows 冲突提示
      _toast(
        '保存冲突：表在保存窗口内又被外部修改，画布修改未丢——请再点一次保存',
        fluent.InfoBarSeverity.error,
      );
      return false;
    }
    final action = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('保存冲突'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${conflicts.length} 行在保存窗口内被外部修改过：',
              style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
            ),
            const SizedBox(height: 6),
            for (final (k, base, diskRow) in conflicts.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '  #$k：${_conflictDiffSummary(base, diskRow)}',
                  style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
                ),
              ),
            if (conflicts.length > 8)
              Text(
                '  …等 ${conflicts.length} 行',
                style: TextStyle(fontSize: 11.5, color: palette.textSecondary),
              ),
            const SizedBox(height: 6),
            Text(
              '采用磁盘值将丢弃画布上对这些行的修改；覆盖并重试以外部的改动为准直接覆盖。',
              style: TextStyle(fontSize: 11.5, color: palette.textHint),
            ),
          ],
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'disk'),
            child: const Text('采用磁盘值'),
          ),
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'force'),
            child: const Text('覆盖并重试'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return false;
    if (action == 'disk') {
      // 舞台与基线一并换成磁盘值：重算补丁后这些行不再有差异
      final stage = isOption ? _stageOpts : _stageTalks;
      final baseline = isOption ? _optBaseline : _talkBaseline;
      setState(() {
        for (final (k, _, diskRow) in conflicts) {
          stage[k] = copyRecordValue(diskRow);
          baseline[k] = copyRecordValue(diskRow);
        }
      });
      _bumpGraph();
      // 递归一次（retried=true）：再次冲突直接 toast 失败，避免无限循环
      return _save(retried: true);
    }
    // 'force'：带 force 重发冲突表补丁，然后继续发还没落盘的表
    //（冲突在 Talk → 只剩 Option；冲突在 Option → Talk 已发送结算，无剩余）
    try {
      await _putTablePatch(cfg, patch, force: true);
    } catch (e) {
      if (!mounted) return false;
      _toast('保存失败: $e', fluent.InfoBarSeverity.error);
      return false;
    }
    return _sendPatches(
      talkPatch,
      optPatch,
      retried: true,
      skipTalk: true,
      skipOpt: isOption,
    );
  }

  /// 冲突行的字段差异概述（最多列 3 个字段名）。
  String _conflictDiffSummary(
    Map<String, dynamic> base,
    Map<String, dynamic> disk,
  ) {
    final fields = <String>[
      for (final f in {...base.keys, ...disk.keys})
        if (!_sameValue(base[f], disk[f])) f.toString(),
    ];
    if (fields.isEmpty) return '整行';
    final head = fields.take(3).join('、');
    return fields.length > 3 ? '$head 等 ${fields.length} 项' : head;
  }

  void _toast(String msg, fluent.InfoBarSeverity sev) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(title: Text(msg), severity: sev),
    );
  }

  // ---------- 图数据 ----------
  /// 作废图缓存。任何改动 `_stageTalks`/`_stageOpts` 内容（含其中记录字段）
  /// 或 `_flowCards` 的路径都必须调用它；纯改节点位置**不要**调用。
  /// 内联字段元数据（C5）以图内容为失效键，随之一起作废。
  void _bumpGraph() {
    _cachedGraph = null;
    _inlineMetasCache.clear();
  }

  /// 事件 id 排序列表只在 EvtCfg 变化时重算（真实约 3,154 个 key，
  /// 原先每次 build 都排一遍）。evtTitles（C7）与它同一失效键：
  /// 三处 EvtCfg 赋值点都紧跟本调用，graph 重建只消费缓存。
  Map<String, String> _evtTitles = const {};

  void _refreshEventList() {
    _sortedEventIds = (_tablesData['EvtCfg'] ?? const {}).keys.toList()
      ..sort(compareEventIds);
    final titles = <String, String>{};
    final evt = _tablesData['EvtCfg'];
    if (evt != null) {
      if (kDebugMode) debugEvtCfgTitleRows += evt.length;
      evt.forEach((id, v) {
        if (v is Map) {
          final t = cln(v['title']);
          if (t.isNotEmpty) titles[id] = t;
        }
      });
    }
    _evtTitles = titles;
  }

  FlowGraph get _graph => _cachedGraph ??= _buildGraph();

  FlowGraph _buildGraph() {
    return buildFlowGraph(
      talks: _stageTalks,
      options: _stageOpts,
      prefixes: _prefixes,
      evtTitles: _evtTitles,
      starts: _evtId == null
          ? const []
          : storyStartIds(_evtId!, _tablesData['EvtCfg']!, _stageTalks),
      cardStyles: _flowCards,
    );
  }

  // ---------- 节点位置 ----------
  void _loadPositionsForEvent() {
    // 旧事件的待结算坐标先归位到 _flowFile，再替换 _positions（C3），
    // 否则切事件前最后一段拖拽会以新事件的坐标被覆盖丢失。
    _settleDirtyPositions();
    final out = <String, Offset>{};
    final saved = _flowFile[_evtId];
    if (saved is Map) {
      saved.forEach((id, v) {
        if (v is Map) {
          final x = (v['x'] is num) ? (v['x'] as num).toDouble() : null;
          final y = (v['y'] is num) ? (v['y'] as num).toDouble() : null;
          if (x != null && y != null) out[id.toString()] = Offset(x, y);
        }
      });
    }
    _positions = out;
    // 缺少位置的节点用分层 DAG 自动布局补齐
    final layout = layoutFlow(graph: _graph);
    final auto = <String, Offset>{};
    layout.forEach((id, pos) {
      if (!_positions.containsKey(id)) auto[id] = pos;
    });
    _positions.addAll(auto);
    _positionsRev.value++;
  }

  /// 拖拽期间有待结算序列化的事件 id（C3）。位置改动每帧只记这里，
  /// 整个 _positions → {id:{x,y}} 的复制推迟到 [_writeLayoutFile]/
  /// 切事件结算点，拖拽帧不再复制全量坐标。
  String? _layoutDirtyEvent;

  void _markLayoutDirty() {
    // 位置是原地改的，画布靠这个版本号判定连线是否需要重绘。
    // 放在 _flowLoaded 守卫之前：能否回写磁盘与是否通知重绘互不相关。
    _positionsRev.value++;
    // 布局文件未加载完成前不回写：此时 _flowFile 可能是空壳，
    // 全量 PUT 会清空其他事件已保存的节点坐标。
    if (!_flowLoaded) return;
    final evt = _evtId;
    if (evt == null) return;
    _layoutDirtyEvent = evt;
    _persistLayout();
  }

  /// 把待结算的 [_positions] 序列化进 [_flowFile]。必须发生在替换
  /// [_positions]（切事件）或回写磁盘（_writeLayoutFile）之前，否则
  /// 最后一段拖拽的坐标会留在旧事件名下或整体丢失。
  void _settleDirtyPositions() {
    final dirty = _layoutDirtyEvent;
    if (dirty == null) return;
    _layoutDirtyEvent = null;
    final saved = <String, dynamic>{};
    _positions.forEach((id, pos) {
      saved[id] = {'x': pos.dx.round(), 'y': pos.dy.round()};
    });
    _flowFile[dirty] = saved;
  }

  // ---------- 图编辑操作 ----------
  void _onMoveNode(String id, Offset pos) {
    _positions[id] = pos;
    _markLayoutDirty();
    // 位置变更经 [_positionsRev]（ValueNotifier）直达画布内的
    // ValueListenableBuilder，拖拽帧不再 setState 全宿主重绘（C10）——
    // 此前这里的 setState 只为让卡片跟手，Inspector 等其余 UI 不消费位置。
  }

  void _onAddEdge(String fromId, String field, String targetId) {
    final rec = _stageTalks[fromId] ?? _stageOpts[fromId];
    if (rec == null) return;
    var targetField = field;
    // 语义适配与校验
    if (_stageTalks.containsKey(fromId)) {
      if (_stageOpts.containsKey(targetId)) {
        // 对白连接到选项节点：自动适配为 option 字段
        targetField = 'option';
      } else if (_stageTalks.containsKey(targetId)) {
        // 对白连接到对白节点：若误从 option 端口拉出，自动矫正为下一句
        if (targetField == 'option') targetField = 'nextTalk';
      } else {
        _toast('该端口只能连接到对白或选项节点', fluent.InfoBarSeverity.warning);
        return;
      }
    } else if (_stageOpts.containsKey(fromId)) {
      if (!_stageTalks.containsKey(targetId)) {
        _toast('选项节点只能连接到对白节点', fluent.InfoBarSeverity.warning);
        return;
      }
    }
    pushEdgeTarget(rec, targetField, targetId);
    setState(() => _markEdited());
  }

  void _onDeleteEdge(String fromId, String field, String targetId) {
    if (!_removeEdgeData(fromId, field, targetId)) return;
    setState(() {
      _selection = _selection.withoutEdges;
      _markEdited();
    });
  }

  /// 纯数据改写：删一条边的目标引用。返回 false 表示源记录已不存在。
  bool _removeEdgeData(String fromId, String field, String targetId) {
    final rec = _stageTalks[fromId] ?? _stageOpts[fromId];
    if (rec == null) return false;
    removeEdgeTarget(rec, field, targetId);
    return true;
  }

  /// Delete/Backspace：一次手势清掉整个选中集（先节点后边）。
  /// 逐项 setState 会让「框选 20 个再删」重算 20 次图，所以纯数据先跑完、
  /// 收尾只刷一次；不能删的终端跳转边汇总成一条 toast，不逐条刷屏。
  void _requestDelete() {
    final sel = _selection;
    var changed = false;
    for (final id in sel.nodes) {
      if (_deleteNodeData(id)) changed = true;
    }
    var skipped = 0;
    for (final e in sel.edges) {
      final field = fieldForEdge(e.kind);
      if (field == null || !_removeEdgeData(e.from, field, e.to)) {
        skipped++;
        continue;
      }
      changed = true;
    }
    if (changed) {
      setState(() {
        _selection = FlowSelection.none;
        _markEdited();
      });
    }
    if (skipped > 0) {
      _toast(
        '$skipped 条终端跳转边不可删除（请直接编辑选项的 nextEvtId）',
        fluent.InfoBarSeverity.warning,
      );
    }
  }

  void _deleteNode(String id) {
    if (!_deleteNodeData(id)) return;
    setState(() {
      _selection = FlowSelection.none;
      _markEdited();
    });
  }

  /// 纯数据改写：删节点并把上游重连。批量删除时由调用方统一 setState。
  bool _deleteNodeData(String id) {
    if (_stageTalks.containsKey(id)) {
      var replacement = normalizeStoryIdList(_stageTalks[id]['nextTalk']);
      if (replacement.isEmpty) {
        // 兑现 remapDeletedTarget 注释承诺的回退：被删行没有后继时，
        // 把上游重连到同事件后续最近的对白，而不是整体剪断剧情链
        final nxt = nextTalkInEvent(_stageTalks.keys, id);
        if (nxt != null) replacement = [int.tryParse(nxt) ?? nxt];
      }
      remapDeletedTarget(_stageTalks, _stageOpts, _prefixes, id, replacement);
      _stageTalks.remove(id);
    } else if (_stageOpts.containsKey(id)) {
      _stageOpts.remove(id);
      // 选项被删，从所有对白的 option 引用中移除该 id
      for (final t in _stageTalks.values) {
        if (t is Map && t['option'] != null) {
          (t as Map<String, dynamic>)['option'] = normalizeStoryIdList(
            t['option'],
          ).where((e) => cln(e) != id).toList();
        }
      }
    } else {
      return false;
    }
    _positions.remove(id);
    // 标脏布局：否则被删节点的坐标残留在 .editor_flow.json，
    // 之后新建复用同一 ID 的节点会"复活"到旧位置
    _markLayoutDirty();
    _expandedNodes.remove(id);
    _fieldInvalid.removeWhere((k) => k.startsWith('$id|'));
    if (_selectedNode == id) _inspectorOpen = false;
    return true;
  }

  // ---------- 添加节点 ----------
  /// 新分配的对白 ID 必须落在当前事件前缀内：编号逼近上限时 +1 会跨到
  /// 下一事件（如 1000999→1001000），节点在图上不可见、保存后成幻影悬挂。
  bool _talkIdUsable(String id) =>
      id.isNotEmpty && (_prefixes.isEmpty || storyIsInPrefixes(_prefixes, id));

  void _addTalkAfterSelected() {
    final sel = _selectedNode;
    final cur = sel != null ? _stageTalks[sel] : null;
    final curId = sel;
    final newId = curId == null || cur == null
        ? appendTalkId(null, _evtId ?? '', _stageTalks)
        : insertTalkId(curId, _stageTalks);
    if (!_talkIdUsable(newId)) {
      _toast(
        newId.isEmpty ? '无法分配对白 ID' : '该事件的对白编号已用尽（再分配会越出事件前缀），无法添加',
        fluent.InfoBarSeverity.warning,
      );
      return;
    }
    final next = cur == null
        ? <dynamic>[]
        : normalizeStoryIdList(cur['nextTalk']);
    final newTalk = cur == null
        ? {
            'id': int.tryParse(newId) ?? 0,
            'roleIds': <dynamic>[],
            'content': '【新对白】',
            'nextTalk': <dynamic>[],
            'nextTalk2': <dynamic>[],
            'option': <dynamic>[],
          }
        : buildInsertedTalkRecord(cur as Map<String, dynamic>, newId, next);
    if (cur != null) {
      cur['nextTalk'] = normalizeStoryIdList([newId]);
    }
    _stageTalks[newId] = newTalk;
    final base = _positions[curId] ?? Offset(60, 40);
    _positions[newId] = base + const Offset(0, kFlowNodeH + 24);
    _markLayoutDirty();
    setState(() {
      _selection = FlowSelection.ofNode(newId);
      _markEdited();
    });
  }

  void _addOptionForSelected() {
    final sel = _selectedNode;
    if (sel == null || !_stageTalks.containsKey(sel)) {
      _toast('请先选中一个对白节点', fluent.InfoBarSeverity.warning);
      return;
    }
    final oid = allocOptionId(getTalkPrefix(sel), {
      for (final k in _stageOpts.keys) cln(k),
    });
    if (oid == null) {
      _toast('选项 ID 已用尽', fluent.InfoBarSeverity.warning);
      return;
    }
    _stageOpts[oid] = {
      'id': int.tryParse(oid) ?? 0,
      'content': '新选项',
      'talkId': <dynamic>[],
      'talkId2': <dynamic>[],
    };
    pushEdgeTarget(_stageTalks[sel], 'option', oid);
    final base = _positions[sel] ?? Offset(60, 40);
    _positions[oid] = base + const Offset(kFlowNodeW + 60, 20);
    _markLayoutDirty();
    setState(() {
      _selection = FlowSelection.ofNode(oid);
      _markEdited();
    });
  }

  /// 卡型节点添加（插件卡与内置预设共用）：新建 talk/option 记录后，
  /// 按 match 的 equals 播种字段（插件协议）、再整体合并 initial 预置字段
  /// （内置预设），使其按卡型渲染。
  void _addPluginCard(String typeId, String appliesTo) {
    Map<String, dynamic>? style;
    for (final c in _flowCards) {
      if (c['type_id'] == typeId) {
        style = c;
        break;
      }
    }
    if (style == null) return;
    void applyMatch(Map<String, dynamic> rec) {
      final m = style!['match'];
      if (m is Map && m['field'] is String && m['equals'] != null) {
        rec[m['field'] as String] = m['equals'];
      }
    }

    void applyInitial(Map<String, dynamic> rec) {
      final init = style!['initial'];
      if (init is Map && init.isNotEmpty) {
        // JSON 往返深拷贝：避免多个新节点共享预设里的 const 列表
        rec.addAll(jsonDecode(jsonEncode(init)) as Map<String, dynamic>);
      }
    }

    final selPos = _addAnchor;
    if (appliesTo == 'talk') {
      final newId = appendTalkId(null, _evtId ?? '', _stageTalks);
      if (!_talkIdUsable(newId)) {
        _toast(
          newId.isEmpty ? '无法分配对白 ID' : '该事件的对白编号已用尽（再分配会越出事件前缀），无法添加',
          fluent.InfoBarSeverity.warning,
        );
        return;
      }
      final rec = <String, dynamic>{
        'id': int.tryParse(newId) ?? 0,
        'roleIds': <dynamic>[],
        'content': '【${style['name'] ?? '新对白'}】',
        'nextTalk': <dynamic>[],
        'nextTalk2': <dynamic>[],
        'option': <dynamic>[],
      };
      applyMatch(rec);
      applyInitial(rec);
      _stageTalks[newId] = rec;
      _positions[newId] = selPos + const Offset(0, kFlowNodeH + 24);
      _markLayoutDirty();
      setState(() {
        _selection = FlowSelection.ofNode(newId);
        _markEdited();
      });
    } else {
      final sel = _selectedNode;
      if (sel == null || !_stageTalks.containsKey(sel)) {
        _toast('请先选中一个对白节点', fluent.InfoBarSeverity.warning);
        return;
      }
      final oid = allocOptionId(getTalkPrefix(sel), {
        for (final k in _stageOpts.keys) cln(k),
      });
      if (oid == null) {
        _toast('选项 ID 已用尽', fluent.InfoBarSeverity.warning);
        return;
      }
      final rec = <String, dynamic>{
        'id': int.tryParse(oid) ?? 0,
        'content': '【${style['name'] ?? '新选项'}】',
        'talkId': <dynamic>[],
        'talkId2': <dynamic>[],
      };
      applyMatch(rec);
      applyInitial(rec);
      _stageOpts[oid] = rec;
      pushEdgeTarget(_stageTalks[sel], 'option', oid);
      _positions[oid] = selPos + const Offset(kFlowNodeW + 60, 20);
      _markLayoutDirty();
      setState(() {
        _selection = FlowSelection.ofNode(oid);
        _markEdited();
      });
    }
  }

  // ---------- 事件增删 ----------
  void _promptCreateEvent() {
    final idCtl = _makeCtl('_evtId', '');
    final titleCtl = _makeCtl('_evtTitle', '');
    // 专用键不带「evtId|」前缀，_resetPanelCtls 够不到；每次打开前清空，
    // 否则第二次弹窗会预填上一个事件的 ID/标题
    idCtl.clear();
    titleCtl.clear();
    fluent
        .showDialog<String>(
          context: context,
          builder: (ctx) => fluent.ContentDialog(
            title: const Text('新建事件'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: idCtl,
                  decoration: const InputDecoration(
                    labelText: '事件 ID（7 位数字，首位 1）',
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: titleCtl,
                  decoration: const InputDecoration(labelText: '事件标题'),
                ),
              ],
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              fluent.FilledButton(
                onPressed: () => Navigator.pop(ctx, 'ok'),
                child: const Text('创建'),
              ),
            ],
          ),
        )
        .then((r) async {
          if (r != 'ok' || !mounted) return;
          if (_transitioning) return;
          final id = idCtl.text.trim();
          if (!RegExp(r'^1\d{6}$').hasMatch(id)) {
            _toast('事件 ID 必须是 7 位数字且首位为 1', fluent.InfoBarSeverity.warning);
            return;
          }
          if (_tablesData['EvtCfg']!.containsKey(id)) {
            _toast('事件 $id 已存在', fluent.InfoBarSeverity.warning);
            return;
          }
          _transitioning = true;
          try {
            final title = titleCtl.text.trim();
            try {
              // 重取后插入再带乐观锁写回：不用 _load 旧缓存整表覆盖外部新增行；
              // 失败则内存里从未出现幽灵事件（不再需要回滚补丁）
              final fresh = await ApiClient.instance.get('/api/cfg/EvtCfg');
              final evts = _asDataMap(fresh['data']);
              final mE = _asInt(fresh['mtime_ns']);
              if (evts.containsKey(id)) {
                _toast('事件 $id 已存在', fluent.InfoBarSeverity.warning);
                return;
              }
              evts[id] = {
                'id': int.parse(id),
                if (title.isNotEmpty) 'title': title,
              };
              await ApiClient.instance.put(
                '/api/cfg/EvtCfg',
                body: {'data': evts, 'expect_mtime_ns': ?mE},
              );
              if (!mounted) return;
              _tablesData['EvtCfg'] = evts;
              _refreshEventList();
              _toast('事件已创建', fluent.InfoBarSeverity.success);
            } catch (e) {
              if (mounted) _toast('创建失败: $e', fluent.InfoBarSeverity.error);
              return;
            }
            // 经脏数据守卫再切入：否则当前事件未保存的舞台修改
            // 会被 _selectEventInner 无声丢弃
            if (!mounted) return;
            if (await _confirmDirtyGate()) await _selectEventInner(id);
          } finally {
            _transitioning = false;
          }
        });
  }

  void _promptDeleteEvent() {
    final evt = _evtId;
    if (evt == null) return;
    fluent
        .showDialog<bool>(
          context: context,
          builder: (ctx) => fluent.ContentDialog(
            title: const Text('删除事件'),
            content: Text(
              '删除事件 $evt${_eventTitle(evt) == null ? '' : '（${_eventTitle(evt)}）'}？'
              '该事件下的全部对白与选项也会一并删除。',
              style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
            ),
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
        )
        .then((ok) async {
          if (ok != true || !mounted) return;
          if (_transitioning) return;
          _transitioning = true;
          final prefixes = _prefixes;
          final matcher = PrefixMatcher(prefixes);
          try {
            // 同 _save 的 rebase：EvtCfg 重取后删除再带乐观锁写回；
            // Talk/Option 只拉该事件前缀的小批量（S3），取回的 key 全部
            // 进 patch.remove，删除是毁灭性操作故保留表级乐观锁
            // expect_mtime_ns。409 → toast 提示重试（无三选框）。
            final freshE = await ApiClient.instance.get('/api/cfg/EvtCfg');
            final freshT = await ApiClient.instance.get(
              '/api/cfg/TalkCfg',
              query: {'prefix': prefixes.join(',')},
            );
            final freshO = await ApiClient.instance.get(
              '/api/cfg/OptionCfg',
              query: {'prefix': prefixes.join(','), 'suffix': '2'},
            );
            final evts = _asDataMap(freshE['data']);
            final talks = _asDataMap(freshT['data']);
            final opts = _asDataMap(freshO['data']);
            final mE = _asInt(freshE['mtime_ns']);
            final mT = _asInt(freshT['mtime_ns']);
            final mO = _asInt(freshO['mtime_ns']);
            evts.remove(evt);
            // matcher 过滤是兜底：MockClient/旧后端忽略 query 返回全量时
            // 不至于把别的事件的行也删了
            final removeT = [
              for (final k in talks.keys)
                if (matcher.match(k)) k.toString(),
            ];
            final removeO = [
              for (final k in opts.keys)
                if (matcher.match(k, isOption: true)) k.toString(),
            ];
            await ApiClient.instance.put(
              '/api/cfg/EvtCfg',
              body: {'data': evts, 'expect_mtime_ns': ?mE},
            );
            final respT = await ApiClient.instance.put(
              '/api/cfg/TalkCfg',
              body: {
                'patch': {'set': <String, dynamic>{}, 'remove': removeT},
                'expect_mtime_ns': ?mT,
              },
            );
            final respO = await ApiClient.instance.put(
              '/api/cfg/OptionCfg',
              body: {
                'patch': {'set': <String, dynamic>{}, 'remove': removeO},
                'expect_mtime_ns': ?mO,
              },
            );
            // 先作废待结算的布局脏标记：删前若拖拽过本事件，_layoutDirtyEvent==evt
            // 会让 _settleDirtyPositions 把被删事件的节点坐标重新写回 _flowFile
            //（同 ID 事件重建时复活旧布局，与 _deleteNodeData 清坐标的防复活设计相悖）
            if (_layoutDirtyEvent == evt) _layoutDirtyEvent = null;
            _flowFile.remove(evt);
            _persistLayout();
            if (!mounted) return;
            _tablesData['EvtCfg'] = evts;
            _tableMtime['TalkCfg'] = _asInt(respT['mtime_ns']) ?? mT;
            _tableMtime['OptionCfg'] = _asInt(respO['mtime_ns']) ?? mO;
            _refreshEventList();
            // 该事件的字段控制器全部作废：同 ID 事件重建时不得回显已删内容
            _dropCtls('$evt|');
            _evtId = null;
            _prefixes = const [];
            _stageTalks = {};
            _stageOpts = {};
            _expandedNodes.clear();
            _fieldInvalid.clear();
            _inspectorOpen = false;
            setState(() => _dirty = false);
            _toast('事件已删除', fluent.InfoBarSeverity.success);
          } on ApiException catch (e) {
            if (!mounted) return;
            _toast(
              e.statusCode == 409 ? '事件删除冲突，请重试' : '删除失败: $e',
              fluent.InfoBarSeverity.error,
            );
          } catch (e) {
            if (!mounted) return;
            _toast('删除失败: $e', fluent.InfoBarSeverity.error);
          } finally {
            if (mounted) _transitioning = false;
          }
        });
  }

  // ---------- 字段编辑 ----------
  /// 控制器按 key（事件|节点|字段 或专用键）懒创建，仅在创建时设初值。
  /// 重建时不重置文本：用户正在输入的中间态（逗号分隔、半截 JSON）一旦被
  /// 回退成上一个合法值，字段就永远打不进去。需要刷新文本时用
  /// [_resetPanelCtls] 清缓存，下次 build 以记录现值重建。
  TextEditingController _makeCtl(String key, String init) {
    return _ctls.putIfAbsent(key, () {
      final c = TextEditingController(text: init);
      _allCtls.add(c);
      return c;
    });
  }

  /// 数据被外部回退（放弃修改等）时清除字段控制器缓存。
  void _resetPanelCtls() => _dropCtls('$_evtId|');

  /// 本帧刚摘除、尚未回收的控制器。
  final List<TextEditingController> _retiredCtls = [];
  final List<FocusNode> _retiredFocuses = [];

  /// 按 key 前缀摘除控制器与焦点节点：同时从 [_allCtls] 移除并延到下一帧
  /// dispose。不能立即 dispose —— 触发本次清理的 setState 还没跑，当前帧的
  /// TextField 仍持有它；也不能不管 —— 跨事件/跨 Mod 长会话会无界堆积
  /// （每个展开过的字段一个控制器）。
  void _dropCtls(String prefix) {
    final dropped = <TextEditingController>[];
    _ctls.removeWhere((k, v) {
      if (!k.startsWith(prefix)) return false;
      dropped.add(v);
      return true;
    });
    final droppedFocuses = <FocusNode>[];
    _focuses.removeWhere((k, v) {
      if (!k.startsWith(prefix)) return false;
      droppedFocuses.add(v);
      return true;
    });
    if (dropped.isEmpty && droppedFocuses.isEmpty) return;
    _allCtls.removeWhere(dropped.contains);
    _retiredCtls.addAll(dropped);
    _retiredFocuses.addAll(droppedFocuses);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final c in _retiredCtls) {
        c.dispose();
      }
      _retiredCtls.clear();
      for (final f in _retiredFocuses) {
        f.dispose();
      }
      _retiredFocuses.clear();
    });
  }

  /// 节点属于哪张表：对白走 TalkCfg、选项走 OptionCfg。
  /// 字段类型必须按表取（gameSchema[cfg][field]）——/api/schema 的 field_types
  /// 是跨表拍平的，同名字段会互相覆盖。
  String? _cfgOf(String nodeId) {
    if (_stageTalks.containsKey(nodeId)) return 'TalkCfg';
    if (_stageOpts.containsKey(nodeId)) return 'OptionCfg';
    return null;
  }

  Map<String, dynamic>? _nodeRec(String nodeId) {
    final rec = _stageTalks[nodeId] ?? _stageOpts[nodeId];
    return rec is Map<String, dynamic> ? rec : null;
  }

  // ---------- Inspector ----------
  /// Inspector 的目标节点：仅「单选 + 该节点在舞台上有记录」。
  /// 多选不做批量合并编辑：bg=0 意为「沿用上一句」，整批写会把语义一起改掉。
  String? get _inspectorTarget {
    final id = _selectedNode;
    if (id == null || !_inspectorOpen) return null;
    return _cfgOf(id) == null ? null : id;
  }

  void _openInspector(String nodeId) {
    if (_cfgOf(nodeId) == null) return;
    setState(() {
      _selection = FlowSelection.ofNode(nodeId);
      _inspectorOpen = true;
    });
  }

  /// 该表的字段元数据（按 schema 缓存，避免每帧重算 21 个 key）。
  List<FieldMeta> _metasFor(String cfg) =>
      _metasCache[cfg] ??= flowFieldMetas(widget.state, cfg);

  void _invalidateMetas() => _metasCache.clear();

  bool _fieldWritable(String cfg, String field) =>
      flowFieldWritable(widget.state.gameSchema, cfg, field);

  /// 全量回收（Mod 重载：此时 `_evtId` 已置 null，按前缀摘不到）。
  void _dropAllCtls() {
    _retiredCtls.addAll(_ctls.values);
    _retiredFocuses.addAll(_focuses.values);
    _ctls.clear();
    _focuses.clear();
    _allCtls.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final c in _retiredCtls) {
        c.dispose();
      }
      _retiredCtls.clear();
      for (final f in _retiredFocuses) {
        f.dispose();
      }
      _retiredFocuses.clear();
    });
  }

  /// 内联展开卡片的字段输入控制器（key = evtId|n:nodeId|field）。
  TextEditingController? _nodeCtlFor(String nodeId, String field) {
    final rec = _nodeRec(nodeId);
    final cfg = _cfgOf(nodeId);
    if (rec == null || cfg == null || _evtId == null) return null;
    final type = cfgTypeOf(widget.state.gameSchema, cfg, field);
    if (type == null || !_fieldWritable(cfg, field)) return null;
    final key = _fieldKey(nodeId, field);
    return _ctls.putIfAbsent(
      key,
      () => _makeCtl(key, encodeFieldValue(rec, field, type)),
    );
  }

  /// 与控制器同键的焦点节点（补全输入框把按键处理挂在它上面）。
  FocusNode? _nodeFocusFor(String nodeId, String field) {
    final cfg = _cfgOf(nodeId);
    if (cfg == null || _evtId == null) return null;
    if (cfgTypeOf(widget.state.gameSchema, cfg, field) == null) return null;
    final key = _fieldKey(nodeId, field);
    return _focuses.putIfAbsent(key, FocusNode.new);
  }

  String _fieldKey(String nodeId, String field) => '$_evtId|n:$nodeId|$field';

  /// 外部写回字段后同步已存在的输入框文案（如资产拖放设置 bg/audio、
  /// 建边写 talkId）。按类型编码，漏分支不会再刷出垃圾文本。
  void _syncNodeCtl(String nodeId, String field) {
    final c = _ctls[_fieldKey(nodeId, field)];
    if (c == null) return;
    final rec = _nodeRec(nodeId);
    final cfg = _cfgOf(nodeId);
    if (rec == null || cfg == null) return;
    final type = cfgTypeOf(widget.state.gameSchema, cfg, field);
    if (type == null) return;
    c.text = encodeFieldValue(rec, field, type);
  }

  /// 编辑文本写回：类型驱动解析。
  ///
  /// 与旧实现的两处语义差别，都是为「不污染存档」服务：
  /// - 空串 → 删除该字段（而不是写成 0 或空串）；
  /// - 解析失败 → 记录与输入框都保持原样，仅标记该字段无效。
  void _applyFieldText(String nodeId, String field, String text) {
    final rec = _nodeRec(nodeId);
    final cfg = _cfgOf(nodeId);
    if (rec == null || cfg == null) return;
    final type = cfgTypeOf(widget.state.gameSchema, cfg, field);
    final invalidKey = '$nodeId|$field';
    if (type == null || !_fieldWritable(cfg, field)) {
      setState(() => _fieldInvalid.add(invalidKey));
      return;
    }
    final r = decodeFieldValue(text, type);
    if (!r.ok) {
      setState(() => _fieldInvalid.add(invalidKey));
      return;
    }
    if (r.cleared) {
      rec.remove(field);
    } else {
      rec[field] = r.value;
    }
    if (_fieldInvalid.remove(invalidKey)) {
      setState(() {});
    }
    setState(() => _markEdited(mergeKey: 'field:$nodeId:$field'));
  }

  bool _fieldInvalidFor(String nodeId, String field) =>
      _fieldInvalid.contains('$nodeId|$field');

  /// 该字段与载入基线不同：Inspector 的「已改」标记。
  bool _fieldDirty(String nodeId, String field) {
    final stage = _nodeRec(nodeId);
    if (stage == null) return false;
    final base = _talkBaseline[nodeId] ?? _optBaseline[nodeId];
    final before = base is Map ? base[field] : null;
    return !_sameValue(stage[field], before);
  }

  static bool _sameValue(dynamic a, dynamic b) {
    if (a == b) return true;
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  // ---------- 候选来源 ----------
  /// 舞台外表的 (id, 预览) 缓存：cfg → 列表。/api/cfg_ids 有 500 条硬截断，
  /// 所以只给舞台外引用（EvtCfg / MinigameCfg）用，舞台内引用一律扫内存。
  final Map<String, List<(String, String)>> _offStageCache = {};

  Future<List<(String, String)>> _offStageIds(String cfg) async {
    final cached = _offStageCache[cfg];
    if (cached != null) return cached;
    try {
      final r = await ApiClient.instance
          .get('/api/cfg_ids', query: {'name': cfg})
          .timeout(const Duration(seconds: 5));
      final items = r is Map ? r['items'] : null;
      if (items is! List) return const [];
      final out = [
        for (final e in items)
          if (e is Map)
            (e['id']?.toString() ?? '', e['preview']?.toString() ?? ''),
      ];
      _offStageCache[cfg] = out;
      return out;
    } catch (_) {
      return const [];
    }
  }

  FlowSuggestDeps get _suggestDeps => FlowSuggestDeps(
    state: widget.state,
    stageTalks: () => _stageRecords.toList(),
    stageOptions: () => _optRecords.toList(),
    offStageIds: _offStageIds,
    modTable: (cfg) => _tablesData[cfg],
  );

  Iterable<Map<String, dynamic>> get _stageRecords =>
      _stageTalks.values.whereType<Map<String, dynamic>>();

  Iterable<Map<String, dynamic>> get _optRecords =>
      _stageOpts.values.whereType<Map<String, dynamic>>();

  /// 内联区要渲染的字段：按节点所属表取，过滤掉不可写字段。
  /// C5：展开卡片每次 build 都会来取，结果按节点缓存，作废点 =
  /// [_bumpGraph]（内容/卡型/可写性变化的唯一汇合点）。
  List<FieldMeta> _inlineMetas(String nodeId) {
    final hit = _inlineMetasCache[nodeId];
    if (hit != null) return hit;
    // ignore: invalid_use_of_visible_for_testing_member
    if (kDebugMode) debugFlowFieldMetasBuilds++;
    final cfg = _cfgOf(nodeId);
    if (cfg == null) return const [];
    final isOption = cfg == 'OptionCfg';
    final out = [
      for (final m in flowInlineMetas(widget.state, cfg, isOption))
        if (m.editable && _fieldWritable(cfg, m.key)) m,
    ];
    // ignore: invalid_use_of_visible_for_testing_member
    return _inlineMetasCache[nodeId] = out;
  }

  SuggestionSource? _suggestForNode(String nodeId, FieldMeta meta) {
    final cfg = _cfgOf(nodeId);
    if (cfg == null) return null;
    return sourceForField(cfg, meta, _suggestDeps);
  }

  // ---------- 媒体资产拖放 ----------
  /// 资产 key ↔ AudioCfg/BgCfg.url 匹配：basename（去目录/扩展名）相等。
  List<(String, Map<String, dynamic>)> _matchCfgByUrl(
    Map<String, dynamic> table,
    String key,
  ) {
    final kb = _baseName(key);
    final out = <(String, Map<String, dynamic>)>[];
    table.forEach((id, v) {
      if (v is! Map) return;
      final url = cln(v['url']);
      if (url.isEmpty) return;
      if (_baseName(url) == kb) {
        out.add((id.toString(), Map<String, dynamic>.from(v)));
      }
    });
    return out;
  }

  String _baseName(String p) {
    var s = p.replaceAll('\\', '/').toLowerCase();
    final i = s.lastIndexOf('/');
    if (i >= 0) s = s.substring(i + 1);
    final d = s.lastIndexOf('.');
    if (d > 0) s = s.substring(0, d);
    return s.trim();
  }

  /// CGCfg.urls（贴图 key/路径数组）↔ 资产 key basename 匹配。
  List<(String, Map<String, dynamic>)> _matchCgByUrl(
    Map<String, dynamic> table,
    String key,
  ) {
    final kb = _baseName(key);
    final out = <(String, Map<String, dynamic>)>[];
    table.forEach((id, v) {
      if (v is! Map) return;
      final urls = v['urls'];
      if (urls is! List) return;
      for (final u in urls) {
        if (_baseName(cln(u)) == kb) {
          out.add((id.toString(), Map<String, dynamic>.from(v)));
          break;
        }
      }
    });
    return out;
  }

  /// 拖入相册 CG（未命中 BgCfg 时）：整句只有一个屏幕效果，直接写
  /// screenEffect = [4015, CGid]（播放CG 指令，data_dicts SCREEN_EFFECT_DB）。
  void _writePlayCg(String nodeId, (String, Map<String, dynamic>) hit) {
    final rec = _stageTalks[nodeId];
    if (rec == null) return;
    final cgId = int.tryParse(hit.$1) ?? hit.$1;
    rec['screenEffect'] = [4015, cgId];
    _syncNodeCtl(nodeId, 'screenEffect');
    setState(() => _markEdited(mergeKey: 'field:$nodeId:screenEffect'));
    final name = cln(hit.$2['name']);
    _toast(
      name.isEmpty ? '已插入播放CG（CG $cgId）' : '已插入播放CG：$name',
      fluent.InfoBarSeverity.success,
    );
  }

  Future<void> _applyAssetDrop(String nodeId, FlowAssetRef ref) async {
    final rec = _stageTalks[nodeId];
    if (rec == null) {
      _toast('媒体资产只能拖到对白节点上', fluent.InfoBarSeverity.warning);
      return;
    }
    final tableName = ref.kind == 'aud' ? 'AudioCfg' : 'BgCfg';
    final field = ref.kind == 'aud' ? 'audio' : 'bg';
    final table = _tablesData[tableName];
    final List<(String, Map<String, dynamic>)> matches =
        (table == null || table.isEmpty)
        ? const []
        : _matchCfgByUrl(table, ref.key);
    if (matches.isEmpty) {
      // 贴图未命中背景表：再按 CG 相册表匹配 → 插入播放CG 指令
      if (ref.kind != 'aud') {
        final cgTable = _tablesData['CGCfg'];
        final cgMatches = cgTable == null || cgTable.isEmpty
            ? const <(String, Map<String, dynamic>)>[]
            : _matchCgByUrl(cgTable, ref.key);
        if (cgMatches.isNotEmpty) {
          final hit = cgMatches.length > 1
              ? await _pickCfgDialog('CGCfg', cgMatches)
              : cgMatches.single;
          if (hit == null || !mounted) return;
          _writePlayCg(nodeId, hit);
          return;
        }
      }
      if (table == null || table.isEmpty) {
        _toast('$tableName 为空，无法匹配资产', fluent.InfoBarSeverity.warning);
        return;
      }
      _toast(
        '$tableName 中 url 没有匹配「${ref.key}」的记录，'
        '请先在资源页导出或登记该资产',
        fluent.InfoBarSeverity.warning,
      );
      return;
    }
    if (matches.length > 1) {
      final picked = await _pickCfgDialog(tableName, matches);
      if (picked == null || !mounted) return;
      _writeAssetField(nodeId, field, picked);
      return;
    }
    _writeAssetField(nodeId, field, matches.single);
  }

  void _writeAssetField(
    String nodeId,
    String field,
    (String, Map<String, dynamic>) hit,
  ) {
    final rec = _stageTalks[nodeId];
    if (rec == null) return;
    final idVal = int.tryParse(hit.$1) ?? hit.$1;
    rec[field] = idVal;
    _syncNodeCtl(nodeId, field);
    setState(() => _markEdited(mergeKey: 'field:$nodeId:$field'));
    final name = cln(hit.$2['name']);
    _toast(
      '已将对白 $nodeId 的${field == 'audio' ? '音频' : '背景'}设为 '
      '#${hit.$1}${name.isEmpty ? '' : '（$name）'}',
      fluent.InfoBarSeverity.success,
    );
  }

  /// 多个候选时弹选择框（id + name + url 列表）。
  Future<(String, Map<String, dynamic>)?> _pickCfgDialog(
    String tableName,
    List<(String, Map<String, dynamic>)> matches,
  ) {
    return fluent.showDialog<(String, Map<String, dynamic>)>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: Text('$tableName 匹配到 ${matches.length} 条记录，请选择'),
        content: SizedBox(
          width: 420,
          height: math.min(320, matches.length * 44 + 16),
          child: ListView.builder(
            itemCount: matches.length,
            itemBuilder: (context, i) {
              final hit = matches[i];
              final name = cln(hit.$2['name']);
              final url = cln(hit.$2['url']);
              return InkWell(
                onTap: () => Navigator.pop(ctx, hit),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    color: palette.panel,
                  ),
                  margin: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Text(
                        '#${hit.$1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF6C5CE7),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name.isEmpty ? url : '$name\n$url',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    // C10 观测计数：宿主 build 次数。准出用例断拖拽 30 帧 == 0
    //（位置更新走 ValueNotifier 直达画布，不再每次 setState 全宿主重绘）。
    // ignore: invalid_use_of_visible_for_testing_member
    if (kDebugMode) debugWorkspaceBuilds++;
    if (_loading) {
      return const Center(child: fluent.ProgressRing());
    }
    if (_error.isNotEmpty) {
      // 整页只有错误文案会造成「死锁界面」：补重试按钮，
      // 失败后无需重开编辑器即可恢复
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: palette.textHint, size: 32),
            const SizedBox(height: 8),
            Text(_error, style: TextStyle(color: palette.textSecondary)),
            const SizedBox(height: 12),
            fluent.Button(
              onPressed: _transitioning ? null : _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: palette.bgAlt, child: _buildCanvasPane()),
        ),
        // 右上：操作簇（适配视图 / 预览 / 保存）
        Positioned(right: 12, top: 10, child: _buildActionsPill()),
        // 左侧浮动工具栏
        Positioned(
          left: 12,
          top: 0,
          bottom: 0,
          child: Center(
            child: StoryFlowSideToolbar(
              enabled: _evtId != null,
              flowCards: _flowCards,
              assetsOpen: _assetsOpen,
              aiOpen: widget.aiOpen,
              onToggleAssets: () => setState(() => _assetsOpen = !_assetsOpen),
              onToggleAi: widget.onToggleAi ?? () {},
              onAddTalk: _addTalkAfterSelected,
              onAddOption: _addOptionForSelected,
              onAddCard: _addPluginCard,
              onOpenPlugins: widget.onOpenPlugins,
              onOpenSettings: widget.onOpenSettings,
            ),
          ),
        ),
        // 媒体资产浮动面板
        if (_assetsOpen)
          Positioned(
            left: 62,
            top: 48,
            bottom: 16,
            width: 252,
            child: FlowAssetPanel(state: widget.state),
          ),
        // 右侧完整参数面板（仅单选非 missing 节点）。top:48 让开右上操作簇。
        if (_inspectorTarget case final id?)
          Positioned(
            right: 12,
            top: 48,
            bottom: 16,
            width: 336,
            child: FlowInspectorPanel(
              nodeId: id,
              cfgName: _cfgOf(id)!,
              record: _nodeRec(id)!,
              metas: _metasFor(_cfgOf(id)!),
              fieldController: _nodeCtlFor,
              fieldFocus: _nodeFocusFor,
              onFieldChanged: _applyFieldText,
              suggestFor: (cfg, meta) => sourceForField(cfg, meta, _suggestDeps),
              fieldInvalid: _fieldInvalidFor,
              fieldDirty: _fieldDirty,
              showAdvanced: _inspectorAdvanced,
              onToggleAdvanced: () =>
                  setState(() => _inspectorAdvanced = !_inspectorAdvanced),
              onClose: () => setState(() => _inspectorOpen = false),
            ),
          ),
        // 右下：小地图（导航用）。canvasSize 用 LayoutBuilder 现取，
        // 不存字段：窗口尺寸变化时这条重建才会跟着刷新。
        // 与右侧参数面板互斥：面板展开时让位隐藏，面板关闭后随重建恢复。
        if (_evtId != null && _inspectorTarget == null)
          Positioned(
            right: 12,
            bottom: 12,
            child: LayoutBuilder(
              builder: (context, c) =>
                  // 小地图同样订阅位置版本：拖拽帧宿主不再 setState（C10），
                  // 不订阅的话小地图节点点会滞后到下一次宿主重建才动。
                  ValueListenableBuilder<int>(
                    valueListenable: _positionsRev,
                    builder: (context, positionsRev, _) => StoryFlowMinimap(
                      graph: _graph,
                      positions: _positions,
                      // positions 原地修改身份不变，repaint 判定靠版本号（D1）
                      positionsVersion: positionsRev,
                      viewport: _vpListen ?? _vpIdle,
                      canvasSize: c.biggest,
                      onJumpTo: (world) =>
                          _graphKey.currentState?.centerOn(world),
                    ),
                  ),
            ),
          ),
        // 左上：事件切换器 + Mod 切换器
        Positioned(
          left: 12,
          top: 10,
          child: Row(
            children: [
              _EventChip(
                evtId: _evtId,
                title: _evtId == null ? null : _eventTitle(_evtId!),
                events: _sortedEventIds,
                titleOf: _eventTitle,
                onSelect: _selectEvent,
                onCreate: _promptCreateEvent,
                onDelete: _evtId == null ? null : _promptDeleteEvent,
              ),
              const SizedBox(width: 8),
              _ModChip(
                modName: widget.state.modName,
                enabled: !_transitioning,
                onSelect: _switchMod,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ----- 画布 -----
  Widget _buildCanvasPane() {
    if (_evtId == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 40, color: palette.iconDisabled),
            const SizedBox(height: 10),
            Text(
              '从左上角选择或新建一个事件开始编排',
              style: TextStyle(color: palette.textHint),
            ),
            const SizedBox(height: 4),
            Text(
              '提示：靠近屏幕顶部可呼出标签条，展开节点右下角箭头可编辑参数',
              style: TextStyle(fontSize: 11, color: palette.textFaint),
            ),
          ],
        ),
      );
    }
    final graph = _graph;
    // C10：画布包 ValueListenableBuilder——拖拽帧的位置更新只重建这一段
    // （StoryFlowGraph + DragTarget），宿主 Stack / Inspector / 小地图不再
    // 每帧跟着重绘。
    return ValueListenableBuilder<int>(
      valueListenable: _positionsRev,
      builder: (context, positionsRev, _) => DragTarget<FlowAssetRef>(
        onWillAcceptWithDetails: (_) => true,
        onMove: (details) {
          final id = _graphKey.currentState?.hitNodeAt(details.offset);
          if (id != _dragHoverNode) setState(() => _dragHoverNode = id);
        },
        onLeave: (_) {
          if (_dragHoverNode != null) {
            setState(() => _dragHoverNode = null);
          }
        },
        onAcceptWithDetails: (details) {
          final node = _graphKey.currentState?.hitNodeAt(details.offset);
          setState(() => _dragHoverNode = null);
          if (node != null) _applyAssetDrop(node, details.data);
        },
        builder: (context, candidate, rejected) {
          _syncViewportSource();
          return StoryFlowGraph(
            key: _graphKey,
            graph: graph,
            positions: _positions,
            positionsVersion: positionsRev,
            selection: _selection,
            expandedNodes: _expandedNodes,
            highlightNode: _dragHoverNode,
            onContextMenu: _onContextMenu,
            onUndo: _undo,
            onRedo: _redo,
            onCopy: _copySelection,
            onPaste: _pasteClipboard,
            fieldInvalid: _fieldInvalidFor,
            fieldDirty: _fieldDirty,
            inlineMetas: _inlineMetas,
            nodeFocus: _nodeFocusFor,
            suggestFor: _suggestForNode,
            onRequestInspector: (nodeId) => () => _openInspector(nodeId),
            onSelectionChanged: (s) => setState(() {
              _selection = s;
              final id = s.onlyNode;
              if (id != null && _cfgOf(id) != null) _inspectorOpen = true;
            }),
            onMoveNode: _onMoveNode,
            onAddEdge: _onAddEdge,
            onDeleteEdge: _onDeleteEdge,
            onRequestDelete: _requestDelete,
            onToggleExpand: _toggleExpand,
            fieldController: _nodeCtlFor,
            onFieldChanged: _applyFieldText,
            onDeleteNode: _deleteNode,
          );
        },
      ),
    );
  }

  /// 把画布的视口 notifier 接到宿主手上（小地图用）。只在身份变化时排一帧。
  void _syncViewportSource() {
    final l = _graphKey.currentState?.viewportListenable;
    if (l == null || identical(l, _vpListen)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _vpListen = l);
    });
  }

  // ----- 右上操作簇 -----
  Widget _buildActionsPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
        boxShadow: [
          BoxShadow(
            color: palette.bgDeep2.withValues(alpha: 0.55),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pillAction(
            icon: Icons.fit_screen_outlined,
            label: '适配视图',
            onTap: () => _graphKey.currentState?.fitView(),
          ),
          if (_dirty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFE67E22).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '未保存',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFE67E22)),
              ),
            ),
          ],
          _pillAction(
            icon: Icons.play_circle_outline,
            label: '运行预览',
            onTap: _evtId == null ? null : () => widget.onPreview(_evtId!),
          ),
          _pillAction(
            icon: Icons.save_outlined,
            label: _dirty ? '保存修改' : '已保存',
            onTap: (_dirty && _evtId != null) ? _save : null,
            primary: true,
          ),
        ],
      ),
    );
  }

  Widget _pillAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    final enabled = onTap != null;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: primary
                  ? const Color(0xFF6C5CE7)
                  : enabled
                  ? palette.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 13,
                  color: primary
                      ? Colors.white
                      : enabled
                      ? palette.textSecondary
                      : palette.iconDisabled,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: primary
                        ? Colors.white
                        : enabled
                        ? palette.textPrimary
                        : palette.iconDisabled,
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

/// 画布左上角事件切换 chip：点击弹出锚定面板（搜索 + 列表 + 新建/删除）。
class _EventChip extends StatefulWidget {
  const _EventChip({
    required this.evtId,
    required this.title,
    required this.events,
    required this.titleOf,
    required this.onSelect,
    required this.onCreate,
    this.onDelete,
  });

  final String? evtId;
  final String? title;
  final List<String> events;

  /// 事件 id → 标题（无标题返回 null/空串），列表行与搜索用它显示名称。
  final String? Function(String id) titleOf;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final VoidCallback? onDelete;

  @override
  State<_EventChip> createState() => _EventChipState();
}

class _EventChipState extends State<_EventChip> {
  final _link = LayerLink();
  OverlayEntry? _overlay;
  String _filter = '';

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
  }

  String _rowLabel(String id) {
    final t = widget.titleOf(id);
    if (t == null || t.isEmpty) return id;
    return '$id  $t';
  }

  @override
  void didUpdateWidget(covariant _EventChip old) {
    super.didUpdateWidget(old);
    if (old.evtId != widget.evtId && _overlay != null) _close();
  }

  void _toggle() {
    if (_overlay != null) {
      _close();
    } else {
      _open();
    }
  }

  void _open() {
    _overlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // 点击面板外关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.shrink(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 6),
            child: Material(type: MaterialType.transparency, child: _panel()),
          ),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  Widget _panel() {
    return StatefulBuilder(
      builder: (context, setPanel) {
        final filter = _filter.trim();
        final shown = widget.events
            .where(
              (id) =>
                  filter.isEmpty ||
                  id.contains(filter) ||
                  (widget.titleOf(id)?.contains(filter) ?? false),
            )
            .toList();
        return Container(
          width: 300,
          constraints: const BoxConstraints(maxHeight: 380),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.bgDeep2.withValues(alpha: 0.6),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: fluent.TextBox(
                  autofocus: true,
                  placeholder: '搜索事件 ID',
                  prefix: const Icon(Icons.search, size: 13),
                  style: const TextStyle(fontSize: 12),
                  onChanged: (v) => setPanel(() => _filter = v),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final id = shown[i];
                    final sel = id == widget.evtId;
                    return InkWell(
                      onTap: () {
                        setPanel(() => _filter = '');
                        _close();
                        widget.onSelect(id);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: sel ? palette.hover : Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: sel
                                ? const Color(0xFF6C5CE7)
                                : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.event_note,
                              size: 13,
                              color: sel
                                  ? const Color(0xFF6C5CE7)
                                  : palette.textHint,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _rowLabel(id),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: sel
                                      ? palette.textHigh
                                      : palette.textSecondary,
                                  fontWeight: sel
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Divider(height: 1, color: palette.border),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: fluent.Button(
                        onPressed: () {
                          _close();
                          widget.onCreate();
                        },
                        child: const Text(
                          '＋ 新建事件',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: fluent.Button(
                        onPressed: widget.onDelete == null
                            ? null
                            : () {
                                _close();
                                widget.onDelete!();
                              },
                        child: const Text(
                          '删除当前',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.evtId == null;
    return CompositedTransformTarget(
      link: _link,
      child: Material(
        type: MaterialType.transparency,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _toggle,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
                boxShadow: [
                  BoxShadow(
                    color: palette.bgDeep2.withValues(alpha: 0.55),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.alt_route,
                    size: 14,
                    color: Color(0xFF6C5CE7),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      empty
                          ? '选择事件'
                          : (widget.title == null || widget.title!.isEmpty
                                ? widget.evtId!
                                : '${widget.evtId}  ${widget.title}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: empty ? palette.textHint : palette.textHigh,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: palette.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 画布左上角、事件切换器右侧的 Mod 切换 chip。
/// 点击时先经 GET /api/mods 拉最新列表再弹菜单（本版本 Flutter 的
/// PopupMenuItemBuilder 不支持异步）；选中项触发全局切换
/// （POST /api/mods/select，配置表/布局/保存目标随之换 mod 根）。
class _ModChip extends StatelessWidget {
  const _ModChip({
    required this.modName,
    required this.onSelect,
    this.enabled = true,
  });

  final String modName;
  final ValueChanged<String> onSelect;

  /// 切换/加载进行中禁用：慢后端下连点会交错两条切换链路，
  /// setMod 与 _tablesData 的最终归属可能不等于所选 Mod。
  final bool enabled;

  Future<void> _openMenu(BuildContext context) async {
    if (!enabled) return;
    // 菜单位置锚点须在 await 前取好，避免跨异步间隙使用 BuildContext
    final button = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    List<ModInfo> mods = [];
    try {
      final r = await ApiClient.instance.get('/api/mods');
      final list = r['mods'];
      if (list is List) {
        mods = [
          for (final m in list)
            if (m is Map) ModInfo.fromJson(Map<String, dynamic>.from(m)),
        ];
      }
    } catch (_) {
      // 拉取失败按空列表处理，菜单内给出提示
    }
    if (!context.mounted) return;
    final items = mods.isEmpty
        ? [
            const PopupMenuItem<String>(
              enabled: false,
              child: Text('没有可用的 Mod', style: TextStyle(fontSize: 12)),
            ),
          ]
        : [
            for (final m in mods)
              PopupMenuItem<String>(
                value: m.name,
                child: Row(
                  children: [
                    Icon(
                      m.name == modName
                          ? Icons.check
                          : Icons.inventory_2_outlined,
                      size: 14,
                      color: m.name == modName
                          ? const Color(0xFF6C5CE7)
                          : palette.textHint,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 220,
                      child: Text(
                        m.manifestTitle.isEmpty
                            ? m.name
                            : '${m.name}（${m.manifestTitle}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ];
    if (button == null) return;
    final selected = await showMenu<String>(
      context: context,
      // 悬浮在画布上：指定不透明底板，避免透出节点/连线
      color: palette.card,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          button.localToGlobal(
            button.size.bottomLeft(Offset.zero),
            ancestor: overlay,
          ),
          button.localToGlobal(
            button.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected != null) onSelect(selected);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openMenu(context),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.bgDeep2.withValues(alpha: 0.55),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.inventory_2_outlined,
                size: 14,
                color: Color(0xFF6C5CE7),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  modName.isEmpty ? '选择 Mod' : modName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: modName.isEmpty
                        ? palette.textHint
                        : palette.textHigh,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down,
                size: 16,
                color: palette.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 剧情图 Inspector：把选中节点的**全字段**摊在右侧浮动面板里。
///
/// 与节点内联卡片共用同一批字段控制器（都由宿主按 `事件|节点|字段` 键持有），
/// 两处读到的是同一个 [TextEditingController]，双向同步不需要任何胶水。本面板
/// **不持有 AppState、不写记录、不自己标脏**：一切落库都走
/// [FlowInspectorPanel.onFieldChanged]，宿主把它包进
/// `setState(() => _markEdited(mergeKey: 'field:$nodeId:$field'))`，
/// 撤销/重做语义才与内联编辑完全一致。
///
/// 四条不可破坏的约定：
/// 1. **Tab 环不出面板**。可见字段按渲染序登记进 [_order]，跳焦用
///    `requestFocus()` 逐项推进并回环。`Actions.invoke(NextFocusIntent())` 与
///    `FocusScope.nextFocus()` 都会走到面板外的另一张节点卡片上、且不回环，
///    一律不用（含纯文本框：它没有补全框那层按键接管，见 [_PlainField]）。
/// 2. **按键路径上绝不发整表请求**。`/api/validate` 一次要上传约 9.8 万行，
///    这里连调都不用；名称回显复用宿主注入的候选源——字典与舞台内引用都在
///    内存里（见 story_flow_suggest.dart 的「名称零请求」约定），且带防抖。
/// 3. **「必填未填」与「写回失败」分开列**。混成一条会让用户把「还没填」读成
///    「填坏了」，两者对应的修法也完全不同。
/// 4. `record` 是舞台里的活记录，只读不写（写只经 [FlowInspectorPanel.onFieldChanged]）。
///
/// [FlowInspectorPanel.metas] 由宿主排好序（常用在前、段内按 schema 声明序），
/// 本面板**不再重排**：Tab 次序与肉眼浏览次序必须同源于宿主的排序。
/// 记录里有、schema 里没有的扩表字段，由宿主以 `editable: false` 的元数据补进
/// metas（见 [FieldMeta.editable]），这里一律按只读展示处理。
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../editor/field_meta.dart';
import '../editor/suggestion_text_field.dart';
import 'story_flow_field_codec.dart';
import 'story_logic.dart';

/// 面板宽度：与 [FlowAssetPanel] 同一档，宿主按此值给 `Positioned` 宽度。
const double kFlowInspectorWidth = 340;

/// 底部小结一行最多列几个字段名，其余折成「等 N 项」，免得长清单把面板顶满。
const int kFlowInspectorListPreview = 4;

/// 名称回显最多解析几个值：多值字段填十几条时不必逐条查。
const int kFlowInspectorEchoTokens = 4;

/// 名称回显防抖：与补全浮层同一节奏，避免逐键重查。
const Duration kFlowInspectorEchoDebounce = Duration(milliseconds: 240);

class FlowInspectorPanel extends StatefulWidget {
  const FlowInspectorPanel({
    super.key,
    required this.nodeId,
    required this.cfgName,
    required this.record,
    required this.metas,
    required this.fieldController,
    required this.fieldFocus,
    required this.onFieldChanged,
    required this.suggestFor,
    required this.fieldInvalid,
    required this.fieldDirty,
    required this.showAdvanced,
    required this.onToggleAdvanced,
    required this.onClose,
  });

  /// 被编辑的节点 id（多选与 missing 节点由宿主**不挂载本面板**表达；
  /// 传空串时面板只出空态，不渲染任何编辑器）。
  final String nodeId;

  /// 节点所属配置表：`'TalkCfg'` | `'OptionCfg'`。
  final String cfgName;

  /// 该节点的舞台记录（可写 Map，本面板只读）。
  final Map<String, dynamic> record;

  /// 全字段元数据，宿主已排好常用/高级。
  final List<FieldMeta> metas;

  /// 字段控制器：与内联卡片同一实例；返回 null = 该字段不渲染。
  final TextEditingController? Function(String nodeId, String field)
  fieldController;

  /// 字段焦点节点（与控制器同键）。返回 null 时面板自造一个兜底，
  /// 只为把 Tab 环关在面板内——不另造一套与宿主并行的键（见类注释）。
  final FocusNode? Function(String nodeId, String field) fieldFocus;

  /// 文本写回：宿主负责解析、落记录、标脏与记撤销步。
  final void Function(String nodeId, String field, String text) onFieldChanged;

  /// 该字段的候选来源；null 表示无候选。
  final SuggestionSource? Function(String cfg, FieldMeta meta) suggestFor;

  /// 该字段此刻是否写回失败（解析被拒）。
  final bool Function(String nodeId, String field) fieldInvalid;

  /// 该字段是否有未保存改动。
  final bool Function(String nodeId, String field) fieldDirty;

  /// 高级段**初始**是否展开（收起态由宿主持久化）。
  ///
  /// 挂载后由用户点段标题驱动，每次变化都回调 [onToggleAdvanced] 让宿主落盘；
  /// 本面板不再回头用这个值改写展开态（与 [fluent.Expander] 的语义一致）。
  final bool showAdvanced;

  /// 高级段展开态变化（宿主负责持久化 + setState）。
  final VoidCallback onToggleAdvanced;

  /// 关闭面板。
  final VoidCallback onClose;

  @override
  State<FlowInspectorPanel> createState() => FlowInspectorPanelState();
}

class FlowInspectorPanelState extends State<FlowInspectorPanel> {
  /// 面板自己的焦点域：Tab 环的外层边界。
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'flowInspectorPanel');

  /// fluent.Expander 会读 PageStorage；面板是浮层，宿主那侧未必有桶，自带一个。
  final PageStorageBucket _bucket = PageStorageBucket();

  /// 可见字段按渲染（= Tab）序登记的焦点节点。折叠段与只读字段不入表，
  /// 所以每次 build 从头攒：列表内容与屏幕上能 Tab 到的框严格一一对应。
  List<FocusNode> _order = <FocusNode>[];

  /// 本帧真正建出编辑器的字段 key：名称回显只服务这些行（折叠段没必要查名）。
  final Set<String> _shownFields = <String>{};

  /// 检测到「与面板外部共用同一 [FocusNode]」的字段（`nodeId|field`）。
  Set<String> _conflicts = <String>{};

  /// 已经告过警的冲突键：一个键只打印一次，免得逐帧刷屏。
  final Set<String> _warned = <String>{};

  /// 宿主给了控制器却没给焦点节点时的兜底节点（随面板一起回收）。
  final Map<String, FocusNode> _fallbacks = <String, FocusNode>{};

  /// 名称回显缓存：`field|token` → 名称（空串 = 查无此名）。
  final Map<String, String> _echo = <String, String>{};

  Timer? _echoTimer;

  /// 常用段展开态（面板内部状态）。
  bool _commonOpen = true;

  /// 高级段展开态：初值取宿主持久化的 [FlowInspectorPanel.showAdvanced]，
  /// 之后由用户点段标题驱动，每次变化都同步回调 [onToggleAdvanced]。
  ///
  /// 之所以由面板持有一份镜像而不是回读 Expander：折叠段**根本不建字段行**，
  /// Tab 环必须与肉眼所见严格一致，而这只有在面板自己知道展开态时才办得到。
  late bool _advancedOpen = widget.showAdvanced;

  /// 本帧的 Tab 环（宿主/测试可用来核对跳焦次序）。
  @visibleForTesting
  List<FocusNode> get focusOrder => List<FocusNode>.unmodifiable(_order);

  /// 与外部（节点内联卡片）共用同一 [FocusNode] 的字段键。
  ///
  /// 焦点键怎么分流是宿主的决定（它同时持有两处调用），面板不自作主张另造
  /// 一套：检测到就记在这里、并在底部提示，两处继续共用同一个节点。
  @visibleForTesting
  Set<String> get focusConflicts => Set<String>.unmodifiable(_conflicts);

  @override
  void initState() {
    super.initState();
    // 外部节点交给 FocusScope 时会连带覆盖它的 onKeyEvent，这里直接挂自己
    // 那份，不依赖 widget 参数（Focus 对外部节点只在首帧应用一次）。
    _scope.onKeyEvent = _onScopeKeyEvent;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resolveEcho());
    });
  }

  @override
  void didUpdateWidget(covariant FlowInspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeId != widget.nodeId || oldWidget.cfgName != widget.cfgName) {
      // 换节点：旧名字与新 ID 对不上，缓存必须整体作废（否则会把上一句的
      // 角色名标在这一句上）。
      _echo.clear();
      _conflicts = <String>{};
      _scheduleEcho();
    }
  }

  @override
  void dispose() {
    _echoTimer?.cancel();
    for (final node in _fallbacks.values) {
      node.dispose();
    }
    _fallbacks.clear();
    _scope.dispose();
    super.dispose();
  }

  // ---------- 焦点环 ----------

  /// 面板内非输入框控件（段标题、关闭键）上的 Tab 也收进环里，
  /// 否则一次 Tab 就跳到画布上另一张卡片的输入框。
  KeyEventResult _onScopeKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    final ring = _visibleRing();
    // 一个可聚焦字段都没有时也把 Tab 吃掉：面板内没有环，但也不许逃出去。
    if (ring.isEmpty) return KeyEventResult.handled;
    final current = FocusManager.instance.primaryFocus;
    final idx = current == null ? -1 : ring.indexOf(current);
    final back = HardwareKeyboard.instance.isShiftPressed;
    final next = idx < 0
        ? (back ? ring.last : ring.first)
        : ring[(idx + (back ? -1 : 1) + ring.length) % ring.length];
    next.requestFocus();
    return KeyEventResult.handled;
  }

  /// [_order] 的实时投影：展开动画期间被 ExcludeFocus 挡住的字段这里再滤一道，
  /// 保证任何时刻焦点都只落在肉眼可见的框上。
  List<FocusNode> _visibleRing() => _order
      .where((n) => n.context != null && n.canRequestFocus)
      .toList();

  /// 无候选时的 Tab：推进到下一个可见字段，末项回环到首项。
  void _advance(FocusNode from) {
    final ring = _visibleRing();
    if (ring.isEmpty) return;
    final idx = ring.indexOf(from);
    final next = ring[(idx + 1) % ring.length];
    next.requestFocus();
  }

  /// 取字段的焦点节点：宿主给的那一个（与内联卡片同一实例才有双向同步）。
  ///
  /// 检测到同一节点已被面板外部挂上时**照旧用它**并记下冲突——另造一个节点
  /// 等于把「两处同步同一字段」这件事悄悄作废，分流键怎么设计归宿主决定。
  ///
  /// 冲突判定要对 `node.context` 做 `findAncestorStateOfType`。FocusNode 卸载
  /// 后并不清除这个 context：内联卡片刚被收起/移除的帧里它指向
  /// deactivated/defunct 的 element，对失效 element 做祖先查找会抛
  /// 「Looking up a deactivated widget's ancestor is unsafe」把整个面板顶成
  /// ErrorWidget（deactivated 的 `mounted` 仍为 true，得用 [Element.debugIsActive]
  /// 挡；release 下它恒为 false——那边没有这条断言，跳过检测也无害）。
  FocusNode _focusFor(FieldMeta meta) {
    final key = '${widget.nodeId}|${meta.key}';
    final node = widget.fieldFocus(widget.nodeId, meta.key);
    if (node == null) {
      return _fallbacks.putIfAbsent(
        key,
        () => FocusNode(debugLabel: 'flowInspector:$key'),
      );
    }
    final owner = node.context;
    if (owner is Element && owner.debugIsActive) {
      if (owner.findAncestorStateOfType<FlowInspectorPanelState>() != this) {
        _conflicts.add(key);
        if (kDebugMode && _warned.add(key)) {
          debugPrint(
            'FlowInspectorPanel：字段 ${meta.key} 的 FocusNode 已被面板外部挂上，'
            '两处将互相抢焦点。请宿主为内联卡片与 Inspector 分配不同焦点键。',
          );
        }
      }
    }
    return node;
  }

  // ---------- 取值与名称回显 ----------

  String? _ctlText(FieldMeta meta) =>
      widget.fieldController(widget.nodeId, meta.key)?.text;

  /// 记录里到底有没有值：空列表/空串/缺键都算「没填」（`0` 是有效数值）。
  bool _hasValue(FieldMeta meta) {
    final v = widget.record[meta.key];
    if (v == null) return false;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return cln(v).isNotEmpty;
  }

  List<String> _tokens(String text) => text
      .split(RegExp(r'[,，、;；\s]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .take(kFlowInspectorEchoTokens)
      .toList();

  String _echoKey(String field, String token) => '$field|$token';

  void _scheduleEcho() {
    _echoTimer?.cancel();
    _echoTimer = Timer(kFlowInspectorEchoDebounce, () {
      if (mounted) unawaited(_resolveEcho());
    });
  }

  /// 名称回显：把 `123` 这样的 ID 翻成「123 → 教室」。
  ///
  /// 只查宿主注入的候选源（字典/舞台内引用都在内存里），固定枚举连查都不用；
  /// 效果码类字段没有「名称」可言，整段跳过。查不到的（空串）不写死缓存——
  /// 引用目标可能刚被建出来，下一轮重查才会翻出名字。
  Future<void> _resolveEcho() async {
    // 先就地能算的（固定枚举）算掉，再把需要查候选源的收成一批。
    final todo = <String, ({FieldMeta meta, String token})>{};
    for (final meta in widget.metas) {
      final rule = meta.rule;
      // 折叠段与只读行不查：既省一次控制器创建，也不给隐形字段回显名字。
      if (rule == null || meta.effectLike || !_shownFields.contains(meta.key)) {
        continue;
      }
      final text =
          _ctlText(meta) ??
          encodeFieldValue(widget.record, meta.key, meta.type);
      final fixed = rule.fixed;
      final source = fixed == null
          ? widget.suggestFor(widget.cfgName, meta)
          : null;
      if (fixed == null && source == null) continue;
      for (final token in _tokens(text)) {
        final key = _echoKey(meta.key, token);
        final cached = _echo[key];
        if (cached != null && cached.isNotEmpty) continue;
        if (fixed != null) {
          _echo[key] = cln(fixed[token]);
          continue;
        }
        todo[key] = (meta: meta, token: token);
      }
    }
    if (todo.isEmpty) return;
    final resolved = <String, String>{};
    for (final entry in todo.entries) {
      final token = entry.value.token;
      final source = widget.suggestFor(widget.cfgName, entry.value.meta);
      var name = '';
      if (source != null) {
        List<Suggestion> found;
        try {
          final query = SuggestionQuery(
            token: token,
            cursor: token.length,
            text: token,
          );
          found = await source(query);
        } catch (_) {
          // 候选源挂了只是没有名字，字段本身照样能编辑。
          found = const <Suggestion>[];
        }
        for (final item in found) {
          // 候选按包含匹配返回，只有整串等于 ID 才是「这一个」。
          if (cln(item.code) == token) {
            name = cln(item.desc);
            break;
          }
        }
      }
      resolved[entry.key] = name;
    }
    if (!mounted) return;
    _echo.addAll(resolved);
    setState(() {});
  }

  /// 该字段的名字回显行；null = 不显示。
  String? _echoLineFor(FieldMeta meta) {
    if (meta.rule == null || meta.effectLike) return null;
    final text = _ctlText(meta) ?? '';
    final parts = <String>[];
    for (final token in _tokens(text)) {
      final name = _echo[_echoKey(meta.key, token)];
      if (name == null) continue; // 还在查：先不显示，别闪一下「未找到」
      parts.add(name.isEmpty ? '$token 未找到' : '$token → $name');
    }
    return parts.isEmpty ? null : parts.join('、');
  }

  // ---------- 单字段 ----------

  /// 字段该给几行：2D 指令的 JSON 一行放不下。
  int _maxLinesOf(FieldMeta meta) => meta.type == '2D Array' ? 3 : 1;

  String? _placeholderOf(FieldMeta meta) {
    switch (meta.type) {
      case '2D Array':
        return '1,2;3,4 或 [[1,2],[3,4]]';
      case '1D Array':
        return '4015,0.5';
      case 'Number':
        return '0';
      default:
        return null;
    }
  }

  Widget _editor(FieldMeta meta, TextEditingController ctl) {
    // 主键与扩表字段：只读展示，永远不给可编辑框。
    if (!meta.editable) {
      return _readValue(
        encodeFieldValue(widget.record, meta.key, meta.type),
      );
    }
    final style = TextStyle(fontSize: 11.5, color: palette.textBody);
    // 效果/条件类与有下拉规则的字段一律走补全框：裸 TextBox 会让全角逗号绕过
    // 校验直接进存档。
    if (meta.effectLike || meta.rule != null) {
      final node = _focusFor(meta);
      _order.add(node);
      return SuggestionTextField(
        controller: ctl,
        focusNode: node,
        source: widget.suggestFor(widget.cfgName, meta),
        onChanged: (v) {
          widget.onFieldChanged(widget.nodeId, meta.key, v);
          _scheduleEcho();
        },
        onTabWithoutCandidates: () => _advance(node),
        multivalued: meta.multivalued,
        replaceWholeOnAccept: meta.replaceWholeOnAccept,
        maxLines: _maxLinesOf(meta),
        placeholder: _placeholderOf(meta),
        style: style,
      );
    }
    final node = _focusFor(meta);
    _order.add(node);
    return _PlainField(
      controller: ctl,
      focusNode: node,
      maxLines: _maxLinesOf(meta),
      placeholder: _placeholderOf(meta),
      style: style,
      onChanged: (v) => widget.onFieldChanged(widget.nodeId, meta.key, v),
      onTab: () => _advance(node),
    );
  }

  Widget _readValue(String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppRadius.m),
        border: Border.all(color: palette.border),
      ),
      child: Text(
        value.isEmpty ? '—' : value,
        style: TextStyle(fontSize: 11.5, color: palette.textMuted),
      ),
    );
  }

  Widget _row(FieldMeta meta) {
    final ctl = widget.fieldController(widget.nodeId, meta.key);
    // 宿主判定该字段不可渲染（例如记录已不在舞台上）。
    if (ctl == null) return const SizedBox.shrink();
    _shownFields.add(meta.key);
    final invalid = widget.fieldInvalid(widget.nodeId, meta.key);
    final dirty = widget.fieldDirty(widget.nodeId, meta.key);
    final requiredEmpty = meta.required && !_hasValue(meta);
    final echo = _echoLineFor(meta);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Column(
        key: ValueKey('inspector-row:${meta.key}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xxs),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    meta.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.badge + 3,
                      fontWeight: FontWeight.w600,
                      color: invalid
                          ? palette.statusDanger
                          : palette.textSecondary,
                    ),
                  ),
                ),
                if (meta.required)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpace.xxs),
                    // 键区分「必填空着」与「必填已填」：两者都挂星号，但只有
                    // 前者需要催填，测试与排查都按这个键取数。
                    child: Text(
                      '＊',
                      key: ValueKey(
                        requiredEmpty
                            ? 'req-missing:${meta.key}'
                            : 'req:${meta.key}',
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.1,
                        color: requiredEmpty
                            ? palette.warning
                            : palette.textHint,
                      ),
                    ),
                  ),
                if (dirty)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpace.xs),
                    child: Tooltip(
                      message: '该字段有未保存改动',
                      child: Text(
                        '●',
                        key: ValueKey('dirty:${meta.key}'),
                        style: TextStyle(
                          fontSize: 8,
                          color: palette.accentLight,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                Text(
                  meta.type.isEmpty ? '未声明' : meta.type,
                  style: TextStyle(fontSize: 9, color: palette.textFaint),
                ),
              ],
            ),
          ),
          _editor(meta, ctl),
          if (echo != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xxs),
              child: Text(
                echo,
                style: TextStyle(
                  fontSize: 9.5,
                  height: 1.3,
                  color: palette.textMuted,
                ),
              ),
            ),
          if (invalid)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xxs),
              child: Text(
                '写回失败：格式无效，记录未被改动',
                key: ValueKey('invalid:${meta.key}'),
                style: TextStyle(fontSize: 9.5, color: palette.statusDanger),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _rows(List<FieldMeta> metas) => [
    for (final meta in metas)
      if (widget.fieldController(widget.nodeId, meta.key) != null)
        _row(meta),
  ];

  // ---------- 分段 ----------

  Widget _section({
    required String title,
    required int count,
    required bool initiallyExpanded,
    required bool open,
    required ValueChanged<bool> onStateChanged,
    required List<Widget> Function() rows,
  }) {
    return fluent.Expander(
      initiallyExpanded: initiallyExpanded,
      onStateChanged: onStateChanged,
      contentPadding: const EdgeInsets.fromLTRB(10, AppSpace.s, 10, AppSpace.xs),
      headerBackgroundColor: WidgetStateColor.resolveWith(
        (states) => palette.panel,
      ),
      contentBackgroundColor: palette.bgAlt,
      header: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppType.title,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Text(
            '$count 项',
            style: TextStyle(fontSize: 9.5, color: palette.textHint),
          ),
        ],
      ),
      content: open
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows(),
            )
          : const SizedBox.shrink(),
    );
  }

  // ---------- 底部小结 ----------

  List<FieldMeta> get _missingRequired => [
    for (final meta in widget.metas)
      if (meta.required && !_hasValue(meta)) meta,
  ];

  List<FieldMeta> get _invalidFields => [
    for (final meta in widget.metas)
      if (widget.fieldInvalid(widget.nodeId, meta.key)) meta,
  ];

  String _labelsOf(List<FieldMeta> metas) {
    final head = metas
        .take(kFlowInspectorListPreview)
        .map((m) => m.label)
        .join('、');
    return metas.length > kFlowInspectorListPreview
        ? '$head 等 ${metas.length} 项'
        : head;
  }

  Widget _summaryLine({
    required String key,
    required String title,
    required String body,
    required Color color,
    required String tip,
  }) {
    return Tooltip(
      message: tip,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpace.xxs),
        child: RichText(
          key: ValueKey<String>(key),
          text: TextSpan(
            style: TextStyle(fontSize: 9.5, height: 1.45, color: color),
            children: [
              TextSpan(text: '$title：', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: body),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary() {
    final missing = _missingRequired;
    final invalid = _invalidFields;
    final conflicts = _conflicts.length;
    return Container(
      key: const ValueKey('inspector-summary'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, AppSpace.xs, 10, AppSpace.s),
      decoration: BoxDecoration(
        color: palette.bgDeep,
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppRadius.xl),
        ),
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (missing.isEmpty && invalid.isEmpty)
            Text(
              '必填项均已填写',
              key: const ValueKey('inspector-ok'),
              style: TextStyle(fontSize: 9.5, color: palette.statusOk),
            )
          else if (missing.isNotEmpty)
            _summaryLine(
              key: 'inspector-missing',
              title: '必填未填 ${missing.length}',
              body: _labelsOf(missing),
              color: palette.statusWarn,
              tip: '这些必填参数在指南里是必须项，记录里还没有值——填上即可，与格式对错无关',
            ),
          if (invalid.isNotEmpty)
            _summaryLine(
              key: 'inspector-invalid',
              title: '写回失败 ${invalid.length}',
              body: _labelsOf(invalid),
              color: palette.statusDanger,
              tip: '这些字段的文本解析不动，记录保持原样未被改动——与「还没填」是两件事',
            ),
          if (conflicts > 0)
            _summaryLine(
              key: 'inspector-focus-conflict',
              title: '焦点冲突 $conflicts',
              body: '与节点卡片共用同一个焦点，Tab 可能停在卡片上',
              color: palette.warning,
              tip: '需要宿主为内联卡片与 Inspector 分配不同的焦点键（面板不自行另造）',
            ),
        ],
      ),
    );
  }

  // ---------- 骨架 ----------

  Widget _header() {
    final title = cln(widget.record['id']);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, AppSpace.s, 4, AppSpace.xs),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
        color: palette.panel,
      ),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 13, color: Color(0xFF6C5CE7)),
          const SizedBox(width: AppSpace.xs),
          Flexible(
            child: Text(
              '节点参数　${widget.cfgName}　$title',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.title,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ),
          fluent.IconButton(
            icon: const Icon(Icons.close, size: 12),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _emptyState(String text) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.l),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: palette.textHint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 每帧从头攒：只渲染可见段，隐形的框既不进环也不占焦点。
    // 冲突同样逐帧重检：失效 context 被跳过（见 _focusFor），旧记录不该残留。
    _order = <FocusNode>[];
    _shownFields.clear();
    _conflicts = <String>{};

    final common = <FieldMeta>[
      for (final meta in widget.metas)
        if (meta.inCommon) meta,
    ];
    final advanced = <FieldMeta>[
      for (final meta in widget.metas)
        if (!meta.inCommon) meta,
    ];
    // 无选中/missing 节点由宿主不挂载来表达；这里再兜一层，避免空 nodeId
    // 或空记录时铺出一屏无主输入框。
    final hasTarget =
        widget.nodeId.isNotEmpty &&
        widget.record.isNotEmpty &&
        widget.metas.isNotEmpty;

    return FocusScope(
      node: _scope,
      child: PageStorage(
        bucket: _bucket,
        child: Container(
          width: kFlowInspectorWidth,
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: palette.border),
            boxShadow: [
              BoxShadow(
                color: palette.bgDeep2.withValues(alpha: 0.55),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              if (!hasTarget)
                Expanded(
                  child: _emptyState(
                    widget.metas.isEmpty
                        ? '没有可编辑的字段（schema 未声明该表）'
                        : '请先单选一个节点（多选与缺失节点不展开参数）',
                  ),
                )
              else
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(10, AppSpace.s, 10, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _section(
                          title: '常用',
                          count: common.length,
                          initiallyExpanded: _commonOpen,
                          open: _commonOpen,
                          onStateChanged: (open) =>
                              setState(() => _commonOpen = open),
                          rows: () => _rows(common),
                        ),
                        if (advanced.isNotEmpty) ...[
                          const SizedBox(height: AppSpace.xs),
                          _section(
                            title: '高级',
                            count: advanced.length,
                            initiallyExpanded: _advancedOpen,
                            open: _advancedOpen,
                            onStateChanged: (open) {
                              setState(() => _advancedOpen = open);
                              if (open != widget.showAdvanced) {
                                widget.onToggleAdvanced();
                              }
                            },
                            rows: () => _rows(advanced),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              if (hasTarget) _summary(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 无候选字段的纯文本框：补全框那层按键接管它没有，Tab 得自己按住，
/// 否则一次 Tab 就顺着系统树序溜到别的节点卡片上。
class _PlainField extends StatefulWidget {
  const _PlainField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onTab,
    this.maxLines = 1,
    this.placeholder,
    this.style,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onTab;
  final int maxLines;
  final String? placeholder;
  final TextStyle? style;

  @override
  State<_PlainField> createState() => _PlainFieldState();
}

class _PlainFieldState extends State<_PlainField> {
  FocusOnKeyEventCallback? _priorOnKeyEvent;
  FocusNode? _handledNode;

  @override
  void initState() {
    super.initState();
    _takeOverKeyHandler();
  }

  /// 与 [SuggestionTextField] 同一手法：fluent.TextBox 不暴露 onKeyEvent，
  /// 只能挂到它使用的 FocusNode 上（按键分发先走节点再走 Actions）。
  void _takeOverKeyHandler() {
    final node = widget.focusNode;
    if (identical(_handledNode, node) && node.onKeyEvent == _handleKeyEvent) {
      return;
    }
    _restoreKeyHandler();
    _priorOnKeyEvent = node.onKeyEvent;
    _handledNode = node;
    node.onKeyEvent = _handleKeyEvent;
  }

  void _restoreKeyHandler() {
    final node = _handledNode;
    if (node == null) return;
    if (node.onKeyEvent == _handleKeyEvent) node.onKeyEvent = _priorOnKeyEvent;
    _handledNode = null;
    _priorOnKeyEvent = null;
  }

  @override
  void didUpdateWidget(covariant _PlainField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      _restoreKeyHandler();
      _takeOverKeyHandler();
    }
  }

  @override
  void dispose() {
    _restoreKeyHandler();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.tab) {
      widget.onTab();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: widget.controller,
      focusNode: widget.focusNode,
      maxLines: widget.maxLines,
      minLines: 1,
      placeholder: widget.placeholder,
      style: widget.style,
      onChanged: widget.onChanged,
    );
  }
}

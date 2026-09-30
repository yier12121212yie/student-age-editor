import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/app_theme.dart';
import '../../core/motion.dart';
import '../files/file_viewer.dart' show ImagePreview;
import '../resources/image_asset_picker.dart';
import 'story_flow_drop.dart';
import 'story_flow_templates.dart'
    show FlowSceneTemplate, kBuiltinSceneTemplates, templateNodeSummaries;

/// 拖拽中的媒体资产引用（kind: tex | aud）已上移到 [FlowDropRef] 协议层
/// （story_flow_drop.dart），本文件只负责三类拖源的 UI。

/// 剧情图画布左侧浮动竖向工具栏：添加节点 / 媒体资产 / AI 侧栏 /
/// 插件 / 设置（后两项为全局页面入口，顶栏标签条不再承载）。
class StoryFlowSideToolbar extends StatefulWidget {
  const StoryFlowSideToolbar({
    super.key,
    required this.enabled,
    required this.flowCards,
    required this.assetsOpen,
    required this.aiOpen,
    required this.onToggleAssets,
    required this.onToggleAi,
    required this.onAddTalk,
    required this.onAddOption,
    required this.onAddCard,
    this.onOpenTemplates,
    this.templatesOpen = false,
    this.onToggleTemplates,
    this.effectsOpen = false,
    this.onToggleEffects,
    required this.onOpenPlugins,
    required this.onOpenSettings,
  });

  /// 未选择事件时添加节点不可用。
  final bool enabled;

  /// 插件流程卡片声明（GET /api/plugins/ui/flow_cards）。
  final List<Map<String, dynamic>> flowCards;
  final bool assetsOpen;
  final bool aiOpen;
  final VoidCallback onToggleAssets;
  final VoidCallback onToggleAi;
  final VoidCallback onAddTalk;
  final VoidCallback onAddOption;
  final void Function(String typeId, String appliesTo) onAddCard;

  /// 场景模板画廊（M6）：null 时不显示该按钮。
  final VoidCallback? onOpenTemplates;

  /// 「模板拖源」「效果拖源」浮动面板的开关状态（M6 深度融合）：
  /// 状态与折叠回调由宿主持有，null 时不显示对应按钮。
  final bool templatesOpen;
  final VoidCallback? onToggleTemplates;
  final bool effectsOpen;
  final VoidCallback? onToggleEffects;

  final VoidCallback onOpenPlugins;
  final VoidCallback onOpenSettings;

  @override
  State<StoryFlowSideToolbar> createState() => _StoryFlowSideToolbarState();
}

class _StoryFlowSideToolbarState extends State<StoryFlowSideToolbar> {
  @override
  Widget build(BuildContext context) {
    final accent = accentColor;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      decoration: BoxDecoration(
        // 悬浮在画布上必须用不透明底板，半透明会让节点/连线透出
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
      // 矮窗口防溢出：按钮加到 9 个后内容可能超出可用高度，
      // 滚动兜底（内容正常高度下与原 Column 视觉一致）。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          // 添加节点：分组弹出菜单（对白/选项 + 内置预设 演出/分支/玩法 + 插件卡）
          Material(
            type: MaterialType.transparency,
            child: PopupMenuButton<String>(
              tooltip: '添加节点',
              enabled: widget.enabled,
              // FluentApp 注入的 Material cardColor 是 Mica 半透明资源色，
              // 悬浮菜单必须指定不透明底板，否则画布内容透出
              color: palette.card,
              onSelected: (v) {
                if (v == 'talk') widget.onAddTalk();
                if (v == 'option') widget.onAddOption();
                if (v.startsWith('card:')) {
                  final parts = v.split(':');
                  if (parts.length >= 3) widget.onAddCard(parts[1], parts[2]);
                }
              },
              itemBuilder: (_) {
                final items = <PopupMenuEntry<String>>[
                  const PopupMenuItem(
                    value: 'talk',
                    child: Row(
                      children: [
                        Icon(Icons.add_comment, size: 14),
                        SizedBox(width: AppSpace.s),
                        Text(
                          '插入新对白（选中对白后）',
                          style: TextStyle(fontSize: AppType.chip),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'option',
                    child: Row(
                      children: [
                        Icon(Icons.alt_route, size: 14),
                        SizedBox(width: AppSpace.s),
                        Text(
                          '为选中对白添加选项',
                          style: TextStyle(fontSize: AppType.chip),
                        ),
                      ],
                    ),
                  ),
                ];
                // 卡型项分组：内置预设按 category（演出/分支/玩法），插件卡独立一组
                final groups = <String, List<Map<String, dynamic>>>{};
                for (final c in widget.flowCards) {
                  final builtin = c['builtin'] == true;
                  final label = builtin
                      ? (c['category']?.toString() ?? '其他').toString()
                      : '插件卡片';
                  (groups[label] ??= []).add(c);
                }
                for (final entry in groups.entries) {
                  if (entry.value.isEmpty) continue;
                  // 该 SDK 无 PopupMenuSection：分隔线 + 禁用项当分组标题
                  items.add(const PopupMenuDivider());
                  items.add(
                    PopupMenuItem<String>(
                      enabled: false,
                      child: Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w600,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  );
                  items.addAll([for (final c in entry.value) _cardItem(c)]);
                }
                return items;
              },
              child: _ToolButton(
                icon: Icons.add,
                label: '添加节点',
                enabled: widget.enabled,
              ),
            ),
          ),
          _divider(),
          if (widget.onOpenTemplates != null) ...[
            _ToolButton(
              icon: Icons.dashboard_customize_outlined,
              label: '场景模板',
              enabled: widget.enabled,
              onTap: widget.onOpenTemplates,
            ),
            _divider(),
          ],
          _ToolButton(
            icon: Icons.image_outlined,
            label: '媒体资产',
            active: widget.assetsOpen,
            onTap: widget.onToggleAssets,
          ),
          _divider(),
          if (widget.onToggleTemplates != null) ...[
            _ToolButton(
              icon: Icons.auto_awesome_motion,
              label: '模板拖源',
              active: widget.templatesOpen,
              onTap: widget.onToggleTemplates,
            ),
            _divider(),
          ],
          if (widget.onToggleEffects != null) ...[
            _ToolButton(
              icon: Icons.bolt,
              label: '效果拖源',
              active: widget.effectsOpen,
              onTap: widget.onToggleEffects,
            ),
            _divider(),
          ],
          _ToolButton(
            icon: Icons.smart_toy_outlined,
            label: 'AI 侧栏',
            active: widget.aiOpen,
            activeColor: accent,
            onTap: widget.onToggleAi,
          ),
          _divider(),
          _ToolButton(
            icon: Icons.extension_outlined,
            label: '插件',
            onTap: widget.onOpenPlugins,
          ),
          _ToolButton(
            icon: Icons.settings_outlined,
            label: '设置',
            onTap: widget.onOpenSettings,
          ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
    width: 22,
    height: 1,
    margin: const EdgeInsets.symmetric(vertical: 3),
    color: palette.border,
  );

  /// 卡型菜单项：色点 + 名称 +（对白/选项）后缀；内置预设与插件卡共用。
  PopupMenuItem<String> _cardItem(Map<String, dynamic> c) {
    final builtin = c['builtin'] == true;
    final desc = (c['description'] ?? '').toString();
    final item = Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color:
                _parseHexColor(c['color']?.toString() ?? '') ??
                (builtin ? palette.textMuted : accentColor),
          ),
        ),
        const SizedBox(width: AppSpace.s),
        Expanded(
          child: Text(
            '${c['name'] ?? c['type_id']}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: AppType.chip),
          ),
        ),
        Text(
          c['applies_to'] == 'talk' ? '对白' : '选项',
          style: TextStyle(fontSize: AppType.body, color: palette.textHint),
        ),
      ],
    );
    final value = 'card:${c['type_id']}:${c['applies_to']}';
    return PopupMenuItem<String>(
      value: value,
      enabled: true,
      child: desc.isEmpty ? item : Tooltip(message: desc, child: item),
    );
  }

  /// #RRGGBB → Color；非法返回 null。
  static Color? _parseHexColor(String s) {
    final hex = s.replaceFirst('#', '');
    if (hex.length != 6) return null;
    final v = int.tryParse(hex, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
}

/// 工具栏图标按钮：悬停放大 + 激活高亮。
class _ToolButton extends StatefulWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.enabled = true,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;
  /// 激活态颜色；缺省跟随调色板的音频分类色。
  final Color? activeColor;

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final color = !widget.enabled
        ? palette.iconDisabled
        : widget.active
        ? (widget.activeColor ?? palette.flowAudio)
        : _hover
        ? palette.textHigh
        : palette.textSecondary;
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedScale(
            duration: AppMotion.fast,
            scale: _hover && enabled ? 1.1 : 1.0,
            child: Container(
              width: 36,
              height: 36,
              margin: const EdgeInsets.symmetric(
                horizontal: AppSpace.xs,
                vertical: AppSpace.xxs,
              ),
              decoration: BoxDecoration(
                color: widget.active
                    ? (widget.activeColor ?? palette.flowAudio)
                        .withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.l),
              ),
              child: Icon(widget.icon, size: 17, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动媒体资产面板：AA 贴图/音频列表，条目可拖拽到对白节点。
class FlowAssetPanel extends StatefulWidget {
  const FlowAssetPanel({super.key, required this.state, this.enabled = true});

  final AppState state;

  /// 只读态（未选事件）：条目不启动拖拽（maxSimultaneousDrags 置 0）。
  final bool enabled;

  @override
  State<FlowAssetPanel> createState() => _FlowAssetPanelState();
}

class _FlowAssetPanelState extends State<FlowAssetPanel> {
  List<String> _tex = [];
  List<String> _aud = [];
  String _tab = 'tex';
  String _filter = '';
  String _error = '';

  /// CG 判定结果：贴图尺寸（key → [w, h]）与是否已按 CG/音乐口径过滤
  /// （false=索引缺尺寸信息，后端回退了全量列表）。
  Map<String, List<int>> _meta = {};
  bool _filtered = true;

  /// 阶段 4c：扫描/轮询相关的瞬时态改为 notifier——
  /// [_scanning] 只驱动头部刷新图标，[_loading]/[_aaStatus] 只驱动列表区；
  /// 索引数据到位（[_tex]/[_aud]/[_meta]/[_error]）仍是整页 setState。
  final ValueNotifier<bool> _scanning = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _loading = ValueNotifier<bool>(true);
  final ValueNotifier<String> _aaStatus = ValueNotifier<String>('idle');

  /// 列表区关心加载中与 AA 状态（空态文案）。
  late final Listenable _listTick =
      Listenable.merge([_loading, _aaStatus]);

  @override
  void initState() {
    super.initState();
    _aaStatus.value = widget.state.aaStatus;
    _loadKeys();
  }

  @override
  void didUpdateWidget(covariant FlowAssetPanel old) {
    super.didUpdateWidget(old);
    // 宿主（资源页/选择器等其他入口）改过全局状态时跟随，避免镜像滞后
    if (widget.state.aaStatus != _aaStatus.value) {
      _aaStatus.value = widget.state.aaStatus;
    }
  }

  @override
  void dispose() {
    _scanning.dispose();
    _loading.dispose();
    _aaStatus.dispose();
    super.dispose();
  }

  /// 状态双写：本地镜像（局部订阅，只刷列表区）+ 全局 [AppState.aaStatus]
  /// （跨页共享；值未变化时其内部去重，不通知）。
  void _setStatus(String status) {
    _aaStatus.value = status;
    widget.state.setAaStatus(status);
  }

  Future<void> _loadKeys() async {
    // 刷新期间的转圈只重建列表区（阶段 4c）
    _loading.value = true;
    try {
      final r = await ApiClient.instance.get(
        '/api/aa/keys',
        query: {'limit': '800', 'scope': 'flow'},
      );
      if (!mounted) return;
      final meta = <String, List<int>>{};
      final rawMeta = r['meta'];
      if (rawMeta is Map) {
        rawMeta.forEach((k, v) {
          if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
            meta[k.toString()] = [(v[0] as num).toInt(), (v[1] as num).toInt()];
          }
        });
      }
      setState(() {
        _tex = ((r['tex'] as List?) ?? const []).cast<String>();
        _aud = ((r['aud'] as List?) ?? const []).cast<String>();
        _meta = meta;
        _filtered = r['flow_filtered'] != false;
        _loading.value = false;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading.value = false;
        _error = '加载资产索引失败: $e';
      });
    }
  }

  /// 扫描游戏资源并轮询状态（与资源页流程一致）。
  ///
  /// 阶段 4c：轮询每秒只写 [_scanning]/[_aaStatus] 两个 notifier，列表与
  /// 搜索框不重建；扫描结束后的索引重载才是结构性变化，走 [_loadKeys] 的
  /// 整页 setState。
  Future<void> _scan() async {
    if (_scanning.value) return;
    _scanning.value = true;
    try {
      var status = await ApiClient.instance
          .post('/api/aa/scan')
          .then((r) => r['status'] as String? ?? 'scanning');
      _setStatus(status);
      if (status == 'scanning') {
        for (var i = 0; i < 300; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          final st = await ApiClient.instance.get('/api/aa/status');
          if (!mounted) return;
          status = st['status'] as String? ?? 'idle';
          _setStatus(status);
          if (status == 'error') break;
          if (status != 'scanning') break;
        }
      }
      if (mounted) await _loadKeys();
    } catch (_) {
      // 扫描失败保持现有列表
    } finally {
      if (mounted) _scanning.value = false;
    }
  }

  /// 当前页签 + 搜索词过滤后的可见 key（列表区局部重建时重算）。
  List<String> _visibleKeys() {
    final q = _filter.trim();
    return (_tab == 'tex' ? _tex : _aud)
        .where((k) => q.isEmpty || k.contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(10, AppSpace.s, 6, 0),
            child: Row(
              children: [
                Text(
                  '媒体资产',
                  style: TextStyle(
                    fontSize: AppType.chip,
                    fontWeight: FontWeight.w600,
                    color: palette.textHigh,
                  ),
                ),
                const Spacer(),
                // 大窗口浏览：打开共享图片选择器（网格画廊 + 单击直接预览）
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openLargePicker(),
                    child: Icon(
                      Icons.open_in_full,
                      size: 14,
                      color: palette.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 轮询中的刷新态只重建这一个图标（阶段 4c）
                ListenableBuilder(
                  listenable: _scanning,
                  builder: (context, _) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _scanning.value ? null : _scan,
                      child: _scanning.value
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.refresh,
                              size: 15,
                              color: palette.textMuted,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              children: [
                _tabBtn('tex', 'CG图片'),
                const SizedBox(width: AppSpace.xs),
                _tabBtn('aud', '音乐'),
              ],
            ),
          ),
          // 索引缺纹理尺寸信息（旧缓存）：后端回退了全量贴图列表
          if (!_filtered && !_loading.value && _error.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(
                '索引未含尺寸信息，暂展示全部贴图；点刷新重扫后仅显示 CG 图片',
                style: TextStyle(fontSize: 10, color: palette.flowCheck),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: fluent.TextBox(
              placeholder: '搜索资源 key',
              prefix: const Icon(Icons.search, size: 13),
              style: const TextStyle(fontSize: AppType.chip),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Divider(height: 1, color: palette.border),
          // 加载态/AA 状态变化只重建这一段列表（阶段 4c）
          Expanded(
            child: ListenableBuilder(
              listenable: _listTick,
              builder: (context, _) => _buildList(_visibleKeys()),
            ),
          ),
          Divider(height: 1, color: palette.border),
          Padding(
            padding: const EdgeInsets.all(AppSpace.s),
            child: Text(
              '拖拽到对白节点：CG图片 → 背景 bg（相册 CG 自动插播放CG），音乐 → audio',
              style: TextStyle(fontSize: AppType.body, color: palette.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<String> list) {
    if (_loading.value) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Text(
          _error,
          style: TextStyle(fontSize: AppType.title, color: palette.textHint),
        ),
      );
    }
    if (list.isEmpty) {
      final idle = _aaStatus.value == 'idle';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.m),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                size: 26,
                color: palette.iconDisabled,
              ),
              const SizedBox(height: AppSpace.s),
              Text(
                idle ? '尚未扫描游戏资源\n点击右上角刷新按钮建立索引' : '没有匹配的资源',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.title,
                  color: palette.textHint,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: AppSpace.xs),
      itemCount: list.length,
      itemBuilder: (context, i) => _item(list[i]),
    );
  }

  Widget _item(String key) {
    final isTex = _tab == 'tex';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Draggable<FlowDropRef>(
        // M6：统一拖放协议——画布 DragTarget<FlowDropRef> 同时接收
        // 资产/模板/效果三类拖源；命中节点走旧资产写字段语义，
        // 空白落点建种子节点。
        data: FlowAssetDropRef(FlowAssetRef(kind: _tab, key: key)),
        maxSimultaneousDrags: widget.enabled ? 1 : 0,
        feedback: _dragFeedback(key, isTex),
        childWhenDragging: Opacity(
          opacity: 0.4,
          child: _itemBody(key, isTex),
        ),
        child: GestureDetector(
          // 单击直接预览大图（拖拽语义不受影响）
          onTap: isTex ? () => _previewAsset(key) : null,
          child: MouseRegion(
            cursor: isTex ? SystemMouseCursors.click : SystemMouseCursors.grab,
            child: _itemBody(key, isTex),
          ),
        ),
      ),
    );
  }

  /// 单击条目 → 大图预览弹窗（免双击）。
  Future<void> _previewAsset(String key) async {
    final bytes = await TexBytesCache.load(key);
    if (!mounted) return;
    if (bytes == null) {
      fluent.displayInfoBar(
        context,
        builder: (_, close) => const fluent.InfoBar(
          title: Text('图片不可用：资源缺失或索引未就绪'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }
    final screen = MediaQuery.sizeOf(context);
    await fluent.showDialog<void>(
      context: context,
      builder: (_) => fluent.ContentDialog(
        title: Text(key,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: math.min(860, screen.width - 80),
          height: math.min(620, screen.height - 120),
          child: ImagePreview(bytes: bytes, name: key),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 头部「放大」按钮 → 共享大窗口图片选择器。
  Future<void> _openLargePicker() async {
    await showImageAssetPicker(context, title: '浏览图片资源');
  }

  Widget _itemBody(String key, bool isTex) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: AppSpace.xs),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(AppRadius.s),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 42,
            child: isTex
                ? TexThumb(
                    keyName: key,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  )
                : Icon(
                    Icons.music_note,
                    size: 15,
                    color: palette.flowAudio,
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.title,
                color: palette.textPrimary,
              ),
            ),
          ),
          if (isTex && _meta[key] != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.xs),
              child: Text(
                '${_meta[key]![0]}×${_meta[key]![1]}',
                style: TextStyle(fontSize: 9, color: palette.textHint),
              ),
            ),
          Icon(Icons.drag_indicator, size: 13, color: palette.textHint),
        ],
      ),
    );
  }

  Widget _dragFeedback(String key, bool isTex) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 190,
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: AppSpace.s,
        ),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: accentColor),
          boxShadow: [
            BoxShadow(
              color: palette.bgDeep2.withValues(alpha: 0.6),
              blurRadius: 12,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              isTex ? Icons.image_outlined : Icons.music_note,
              size: 15,
              color: isTex ? palette.flowBg : palette.flowAudio,
            ),
            const SizedBox(width: AppSpace.s),
            Expanded(
              child: Text(
                key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textHigh,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBtn(String key, String label) {
    final selected = _tab == key;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _tab = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? palette.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppType.chip,
              color: selected ? palette.textHigh : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动「模板」拖源面板（M6）：场景模板卡片，拖到画布空白处以落点为
/// 原点整组创建（入口节点落在落点）；点击「场景模板」画廊按钮的链路不变。
class FlowTemplatePalette extends StatelessWidget {
  const FlowTemplatePalette({
    super.key,
    this.enabled = true,
    this.templates,
  });

  /// 只读态（未选事件）：卡片不启动拖拽。
  final bool enabled;

  /// 展示的模板（宿主可并入「我的模板」；缺省内置库）。
  final List<FlowSceneTemplate>? templates;

  List<FlowSceneTemplate> get _visible => templates ?? kBuiltinSceneTemplates;

  static const panelWidth = 264.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: panelWidth,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(10, AppSpace.s, 10, 6),
            child: Text(
              '模板拖源',
              style: TextStyle(
                fontSize: AppType.chip,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: _visible.isEmpty
                ? Center(
                    child: Text(
                      '还没有模板',
                      style: TextStyle(
                        fontSize: AppType.title,
                        color: palette.textHint,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: AppSpace.xs,
                    ),
                    itemCount: _visible.length,
                    itemBuilder: (context, i) => _card(_visible[i]),
                  ),
          ),
          Divider(height: 1, color: palette.border),
          Padding(
            padding: const EdgeInsets.all(AppSpace.s),
            child: Text(
              '拖到画布空白处：以落点为原点创建整组节点\n（点「场景模板」按钮打开画廊）',
              style: TextStyle(fontSize: AppType.body, color: palette.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(FlowSceneTemplate t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Draggable<FlowDropRef>(
        data: FlowTemplateDropRef(t),
        maxSimultaneousDrags: enabled ? 1 : 0,
        feedback: _feedback(t),
        childWhenDragging: Opacity(opacity: 0.4, child: _body(t)),
        child: _body(t),
      ),
    );
  }

  Widget _body(FlowSceneTemplate t) {
    // 迷你预览：名称 + 节点数 + 首行字段摘要（画廊同源 templateNodeSummaries）。
    final lines = templateNodeSummaries(t);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(AppRadius.s),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(
            Icons.dashboard_customize_outlined,
            size: 15,
            color: accentColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.chip,
                          fontWeight: FontWeight.w600,
                          color: palette.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${t.nodes.length} 节点',
                      style: TextStyle(
                        fontSize: 9,
                        color: palette.textHint,
                      ),
                    ),
                  ],
                ),
                if (lines.isNotEmpty)
                  Text(
                    lines.first.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9.5, color: palette.textMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.drag_indicator, size: 13, color: palette.textHint),
        ],
      ),
    );
  }

  Widget _feedback(FlowSceneTemplate t) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: accentColor),
          boxShadow: [
            BoxShadow(
              color: palette.bgDeep2.withValues(alpha: 0.6),
              blurRadius: 12,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dashboard_customize_outlined,
              size: 14,
              color: accentColor,
            ),
            const SizedBox(width: 6),
            Text(
              t.name,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 浮动「效果」拖源面板（M6）：/api/effect_suggest 码表搜索，候选行可拖——
/// 拖到已有对白追加效果行，拖到空白处新建带效果的对白节点。
class FlowEffectPalette extends StatefulWidget {
  const FlowEffectPalette({super.key, this.enabled = true, this.limit = 10});

  /// 面板宽度（宿主 Positioned 用）。
  static const panelWidth = 264.0;

  /// 只读态（未选事件）：候选行不启动拖拽。
  final bool enabled;

  /// 最多展示的候选条数（「前若干条作为拖源」）。
  final int limit;

  @override
  State<FlowEffectPalette> createState() => _FlowEffectPaletteState();
}

class _FlowEffectPaletteState extends State<FlowEffectPalette> {
  final TextEditingController _q = TextEditingController();
  List<FlowEffectDropRef> _items = const [];
  bool _loading = false;
  String _error = '';

  /// 竞态令牌：连续按键时只采纳最后一次请求的结果。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _fetch('');
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _fetch(String q) async {
    final token = ++_seq;
    setState(() => _loading = true);
    List<FlowEffectDropRef> found = const [];
    var error = '';
    try {
      final r = await ApiClient.instance.get(
        '/api/effect_suggest',
        query: {'q': q, 'mode': 'effect'},
      );
      final list = r['items'];
      if (list is List) {
        found = [
          for (final e in list)
            if (e is Map && (e['code'] ?? '').toString().trim().isNotEmpty)
              FlowEffectDropRef(
                code: e['code'].toString(),
                desc: (e['desc'] ?? '').toString(),
              ),
        ].take(widget.limit).toList();
      }
    } catch (e) {
      // 后端不可达：提示但面板仍可关闭/重试，不炸画布
      error = '效果码表加载失败: $e';
    }
    if (!mounted || token != _seq) return;
    setState(() {
      _items = found;
      _loading = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: FlowEffectPalette.panelWidth,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(10, AppSpace.s, 10, 6),
            child: Text(
              '效果拖源',
              style: TextStyle(
                fontSize: AppType.chip,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: fluent.TextBox(
              controller: _q,
              placeholder: '搜索效果码（描述或代码片段）',
              prefix: const Icon(Icons.search, size: 13),
              style: const TextStyle(fontSize: AppType.chip),
              onChanged: (v) => _fetch(v.trim()),
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(child: Center(child: _listArea())),
          Divider(height: 1, color: palette.border),
          Padding(
            padding: const EdgeInsets.all(AppSpace.s),
            child: Text(
              '拖到对白节点追加效果行；拖到空白处新建带效果的对白',
              style: TextStyle(fontSize: AppType.body, color: palette.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _listArea() {
    if (_loading && _items.isEmpty) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_error.isNotEmpty) {
      return Text(
        _error,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: AppType.title, color: palette.textHint),
      );
    }
    if (_items.isEmpty) {
      return Text(
        _loading ? '' : '没有匹配的效果码',
        style: TextStyle(fontSize: AppType.title, color: palette.textHint),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: AppSpace.xs),
      itemCount: _items.length,
      itemBuilder: (context, i) => _row(_items[i]),
    );
  }

  Widget _row(FlowEffectDropRef d) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Draggable<FlowDropRef>(
        data: d,
        maxSimultaneousDrags: widget.enabled ? 1 : 0,
        feedback: _feedback(d),
        childWhenDragging: Opacity(opacity: 0.4, child: _rowBody(d)),
        child: _rowBody(d),
      ),
    );
  }

  Widget _rowBody(FlowEffectDropRef d) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(AppRadius.s),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 15, color: palette.flowAudio),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  d.desc.isEmpty ? d.code : d.desc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.chip,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
                Text(
                  d.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: palette.textHint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.drag_indicator, size: 13, color: palette.textHint),
        ],
      ),
    );
  }

  /// 拖影显示效果描述（任务口径），desc 为空退回码文本。
  Widget _feedback(FlowEffectDropRef d) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.l),
          border: Border.all(color: accentColor),
          boxShadow: [
            BoxShadow(
              color: palette.bgDeep2.withValues(alpha: 0.6),
              blurRadius: 12,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, size: 14, color: palette.flowAudio),
            const SizedBox(width: 6),
            Text(
              d.desc.isEmpty ? d.code : d.desc,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: palette.textHigh,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

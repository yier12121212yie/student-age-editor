import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/app_theme.dart';
import '../../core/motion.dart';

/// 拖拽中的媒体资产引用（kind: tex | aud）。
class FlowAssetRef {
  const FlowAssetRef({required this.kind, required this.key});
  final String kind;
  final String key;
}

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
  final VoidCallback onOpenPlugins;
  final VoidCallback onOpenSettings;

  @override
  State<StoryFlowSideToolbar> createState() => _StoryFlowSideToolbarState();
}

class _StoryFlowSideToolbarState extends State<StoryFlowSideToolbar> {
  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF6C5CE7);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        // 悬浮在画布上必须用不透明底板，半透明会让节点/连线透出
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
                    child: Row(children: [
                      Icon(Icons.add_comment, size: 14),
                      SizedBox(width: 8),
                      Text('插入新对白（选中对白后）', style: TextStyle(fontSize: 12)),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'option',
                    child: Row(children: [
                      Icon(Icons.alt_route, size: 14),
                      SizedBox(width: 8),
                      Text('为选中对白添加选项', style: TextStyle(fontSize: 12)),
                    ]),
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
                  items.add(PopupMenuItem<String>(
                    enabled: false,
                    child: Text(
                      entry.key,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: palette.textMuted,
                      ),
                    ),
                  ));
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
          _ToolButton(
            icon: Icons.image_outlined,
            label: '媒体资产',
            active: widget.assetsOpen,
            onTap: widget.onToggleAssets,
          ),
          _divider(),
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
            color: _parseHexColor(c['color']?.toString() ?? '') ??
                (builtin ? palette.textMuted : const Color(0xFF6C5CE7)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${c['name'] ?? c['type_id']}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        Text(c['applies_to'] == 'talk' ? '对白' : '选项',
            style: TextStyle(fontSize: 10.5, color: palette.textHint)),
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
    this.activeColor = const Color(0xFF27AE60),
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;
  final Color activeColor;

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
            ? widget.activeColor
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
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: widget.active
                    ? widget.activeColor.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
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
  const FlowAssetPanel({super.key, required this.state});

  final AppState state;

  @override
  State<FlowAssetPanel> createState() => _FlowAssetPanelState();
}

class _FlowAssetPanelState extends State<FlowAssetPanel> {
  List<String> _tex = [];
  List<String> _aud = [];
  String _tab = 'tex';
  String _filter = '';
  bool _loading = true;
  bool _scanning = false;
  String _error = '';

  /// CG 判定结果：贴图尺寸（key → [w, h]）与是否已按 CG/音乐口径过滤
  /// （false=索引缺尺寸信息，后端回退了全量列表）。
  Map<String, List<int>> _meta = {};
  bool _filtered = true;

  /// 贴图缩略图缓存（key → bytes；null=加载中/失败）。
  final Map<String, Uint8List?> _thumbs = {};

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    setState(() => _loading = true);
    try {
      final r = await ApiClient.instance.get('/api/aa/keys',
          query: {'limit': '800', 'scope': 'flow'});
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
        _loading = false;
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载资产索引失败: $e';
      });
    }
  }

  /// 扫描游戏资源并轮询状态（与资源页流程一致）。
  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      var status = await ApiClient.instance
          .post('/api/aa/scan')
          .then((r) => r['status'] as String? ?? 'scanning');
      widget.state.setAaStatus(status);
      if (status == 'scanning') {
        for (var i = 0; i < 300; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          final st = await ApiClient.instance.get('/api/aa/status');
          if (!mounted) return;
          status = st['status'] as String? ?? 'idle';
          widget.state.setAaStatus(status);
          if (status == 'error') break;
          if (status != 'scanning') break;
        }
      }
      if (mounted) await _loadKeys();
    } catch (_) {
      // 扫描失败保持现有列表
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _loadThumb(String key) async {
    if (_thumbs.containsKey(key)) return;
    _thumbs[key] = null;
    try {
      final r = await ApiClient.instance
          .post('/api/aa/preview', body: {'kind': 'tex', 'key': key});
      final b64 = r['data'] as String?;
      if (!mounted) return;
      setState(() => _thumbs[key] = b64 != null ? base64Decode(b64) : null);
    } catch (_) {
      if (mounted) setState(() => _thumbs[key] = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = (_tab == 'tex' ? _tex : _aud)
        .where((k) => _filter.trim().isEmpty || k.contains(_filter.trim()))
        .toList();
    return Container(
      width: 252,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 0),
            child: Row(
              children: [
                Text('媒体资产',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh)),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _scanning ? null : _scan,
                    child: _scanning
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2))
                        : Icon(Icons.refresh,
                            size: 15, color: palette.textMuted),
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
                const SizedBox(width: 4),
                _tabBtn('aud', '音乐'),
              ],
            ),
          ),
          // 索引缺纹理尺寸信息（旧缓存）：后端回退了全量贴图列表
          if (!_filtered && !_loading && _error.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(
                '索引未含尺寸信息，暂展示全部贴图；点刷新重扫后仅显示 CG 图片',
                style: TextStyle(fontSize: 10, color: const Color(0xFFE67E22)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: fluent.TextBox(
              placeholder: '搜索资源 key',
              prefix: const Icon(Icons.search, size: 13),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(child: _buildList(list)),
          Divider(height: 1, color: palette.border),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              '拖拽到对白节点：CG图片 → 背景 bg（相册 CG 自动插播放CG），音乐 → audio',
              style: TextStyle(fontSize: 10.5, color: palette.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<String> list) {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error.isNotEmpty) {
      return Center(
          child: Text(_error,
              style: TextStyle(fontSize: 11, color: palette.textHint)));
    }
    if (list.isEmpty) {
      final idle = widget.state.aaStatus == 'idle';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_not_supported_outlined,
                  size: 26, color: palette.iconDisabled),
              const SizedBox(height: 8),
              Text(
                idle ? '尚未扫描游戏资源\n点击右上角刷新按钮建立索引' : '没有匹配的资源',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: palette.textHint),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      itemCount: list.length,
      itemBuilder: (context, i) => _item(list[i]),
    );
  }

  Widget _item(String key) {
    final isTex = _tab == 'tex';
    Uint8List? thumb;
    if (isTex) {
      _loadThumb(key);
      thumb = _thumbs[key];
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Draggable<FlowAssetRef>(
        data: FlowAssetRef(kind: _tab, key: key),
        feedback: _dragFeedback(key, isTex),
        childWhenDragging: Opacity(opacity: 0.4, child: _itemBody(key, isTex, thumb)),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: _itemBody(key, isTex, thumb),
        ),
      ),
    );
  }

  Widget _itemBody(String key, bool isTex, Uint8List? thumb) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 30,
            child: isTex
                ? (thumb != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Image.memory(thumb,
                            fit: BoxFit.cover,
                            gaplessPlayback: true),
                      )
                    : Icon(Icons.image_outlined,
                        size: 15, color: palette.iconDisabled))
                : Icon(Icons.music_note,
                    size: 15, color: const Color(0xFF27AE60)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.textPrimary),
            ),
          ),
          if (isTex && _meta[key] != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF6C5CE7)),
          boxShadow: [
            BoxShadow(
                color: palette.bgDeep2.withValues(alpha: 0.6),
                blurRadius: 12),
          ],
        ),
        child: Row(
          children: [
            Icon(isTex ? Icons.image_outlined : Icons.music_note,
                size: 15,
                color: isTex
                    ? const Color(0xFF3498DB)
                    : const Color(0xFF27AE60)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh)),
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
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color:
                      selected ? palette.textHigh : palette.textSecondary)),
        ),
      ),
    );
  }
}

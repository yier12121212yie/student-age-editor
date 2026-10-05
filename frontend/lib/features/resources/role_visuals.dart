/// 人物头像 / 立绘的**公共视觉与取图逻辑**。
///
/// 目标：头像不再各自造色块，而是**复用立绘的图片与加载链路**——
///   * [RoleVisualCache]：一次 `GET /api/roles`，缓存 `id → {名称, 立绘 key}`；
///     头像与立绘取的是同一个 key、同一份 [TexBytesCache]。
///   * [RoleAvatar]：人物头像。有立绘时按「顶部对齐 cover」把立绘裁成头像，
///     取不到立绘才退回首字色块（与旧 `_Avatar` 观感兜底一致）。
///   * [RolePortrait]：整张立绘（详情 / 预览）。
///
/// 原先 `social/goals/external/idle` 四个工作台各写一份 `_Avatar`，现统一到这里。
library;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import 'image_asset_picker.dart';

/// 一个人物的展示信息：名称 + 立绘 key（来自 `/api/roles`）。
class RoleVisual {
  const RoleVisual({
    required this.id,
    required this.name,
    required this.portraitKey,
  });

  final String id;
  final String name;

  /// 立绘贴图 key（`/api/roles` 的 `portrait`，中学优先、否则小学）。
  final String portraitKey;
}

/// 人物展示信息的会话级缓存：一次请求，全局复用。
class RoleVisualCache {
  RoleVisualCache._();
  static final RoleVisualCache instance = RoleVisualCache._();

  final Map<String, RoleVisual> _byId = {};
  Future<void>? _inflight;

  RoleVisual? byId(String id) => _byId[id];

  /// 查询某个人物；未加载时先拉一次 `/api/roles`（并发调用共享同一请求）。
  Future<RoleVisual?> lookup(String id) async {
    if (id.isEmpty) return null;
    if (_byId.containsKey(id)) return _byId[id];
    await (_inflight ??= _load());
    return _byId[id];
  }

  Future<void> _load() async {
    try {
      final resp = await ApiClient.instance.get('/api/roles');
      final list = (resp['roles'] as List? ?? const []).cast<Map>();
      for (final r in list) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        _byId[id] = RoleVisual(
          id: id,
          name: r['name']?.toString() ?? '',
          portraitKey: (r['portrait']?.toString() ?? '').trim(),
        );
      }
    } catch (_) {
      // 后端不可达：缓存留空，头像退回首字色块。
    }
  }
}

List<Color> _swatches() => [
      accentColor,
      palette.catTexture,
      palette.catAudio,
      palette.catSprite,
      palette.statusOk,
      palette.statusWarn,
    ];

/// 人物头像：**优先复用立绘图片**（顶部对齐裁切），取不到退回首字色块。
class RoleAvatar extends StatefulWidget {
  const RoleAvatar({
    super.key,
    required this.seed,
    required this.name,
    this.size = 36,
    this.circular = false,
  });

  /// 人物 id（用于查立绘 + 色块取色）。
  final int seed;
  final String name;
  final double size;
  final bool circular;

  @override
  State<RoleAvatar> createState() => _RoleAvatarState();
}

class _RoleAvatarState extends State<RoleAvatar> {
  String _portraitKey = '';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final v = await RoleVisualCache.instance.lookup(widget.seed.toString());
    if (!mounted || v == null || v.portraitKey.isEmpty) return;
    setState(() => _portraitKey = v.portraitKey);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.circular
        ? BorderRadius.circular(widget.size)
        : BorderRadius.circular(widget.size * 0.26);
    final key = _portraitKey;
    if (key.isNotEmpty) {
      return Container(
        width: widget.size,
        height: widget.size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: palette.border),
        ),
        // 复用立绘图片；立绘多为全身，顶部对齐以露出头部。
        child: TexThumb(
          keyName: key,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
      );
    }
    final c = _swatches()[widget.seed.abs() % _swatches().length];
    final ch = widget.name.trim().isEmpty ? '?' : widget.name.trim().substring(0, 1);
    return Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.22),
        borderRadius: radius,
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        ch,
        style: TextStyle(
          fontSize: widget.size * 0.42,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }
}

/// 整张立绘（复用同一取图链路）。
class RolePortrait extends StatelessWidget {
  const RolePortrait({
    super.key,
    required this.portraitKey,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.borderRadius,
  });

  final String portraitKey;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    if (portraitKey.isEmpty) {
      return Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: borderRadius,
          border: Border.all(color: palette.border),
        ),
        child: Icon(FluentIcons.image_24_regular,
            size: 18, color: palette.iconDisabled),
      );
    }
    return TexThumb(
      keyName: portraitKey,
      width: width,
      height: height,
      fit: fit,
      borderRadius: borderRadius,
    );
  }
}

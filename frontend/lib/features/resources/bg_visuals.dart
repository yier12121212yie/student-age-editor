/// 背景（BgCfg）**公共视觉与取图逻辑**，与人物立绘展示 [role_visuals] 同构。
///
/// 目标：背景不再各自拼 key/名称，而是复用**同一份合并元数据与取图链路**——
///   * [BgVisualCache]：一次 `GET /api/preview/meta`，缓存 `bgKeys`（id → tex
///     key）与 `bgs`（id → 展示名）；背景缩略图与立绘取的是同一份
///     [TexBytesCache]（因此对象存储 `url` 回退同样复用）。
///   * [BgThumb]：背景缩略图（默认 16:9 cover）。key 为空时退回首字/图标占位。
///   * [BgGalleryPanel]：全部背景的网格画廊（对齐「人物资源库」的立绘网格）。
///
/// 数据源 `GET /api/preview/meta` 的 `bgKeys` 已是「去 bg/ 前缀后的 tex key」，
/// 直接喂给 `/api/aa/preview`；没有游戏/资源包时由后端背景图片资源扩展回退。
library;

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import 'image_asset_picker.dart';

/// 一张背景的展示信息：BgCfg id + 展示名 + tex key。
class BgVisual {
  const BgVisual({
    required this.id,
    required this.name,
    required this.key,
  });

  final String id;
  final String name;

  /// 背景贴图 tex key（`/api/preview/meta` 的 `bgKeys`，已去 `bg/` 前缀）。
  final String key;
}

/// 背景展示信息的会话级缓存：一次请求，全局复用（与 [RoleVisualCache] 同型）。
class BgVisualCache {
  BgVisualCache._();
  static final BgVisualCache instance = BgVisualCache._();

  List<BgVisual> _items = const [];
  bool _loaded = false;
  Future<void>? _inflight;

  List<BgVisual> get items => _items;

  /// 测试隔离用：清空缓存，下一次 [load] 重新请求。
  void debugReset() {
    _items = const [];
    _loaded = false;
    _inflight = null;
  }

  /// 加载全部背景；已加载直接返回，[force] 强制重拉。
  Future<List<BgVisual>> load({bool force = false}) async {
    if (_loaded && !force) return _items;
    await (_inflight ??= _fetch());
    return _items;
  }

  Future<void> _fetch() async {
    try {
      final resp = await ApiClient.instance.get('/api/preview/meta');
      final bgKeys = resp is Map ? resp['bgKeys'] : null;
      final bgs = resp is Map ? resp['bgs'] : null;
      final names = <String, String>{};
      if (bgs is Map) {
        for (final e in bgs.entries) {
          final v = e.value;
          final s = v is List && v.isNotEmpty ? v.first : v;
          if (s != null && s.toString().isNotEmpty) {
            names[e.key.toString()] = s.toString();
          }
        }
      }
      final out = <BgVisual>[];
      if (bgKeys is Map) {
        bgKeys.forEach((k, v) {
          final id = k.toString();
          final key = (v ?? '').toString().trim();
          if (key.isEmpty) return;
          out.add(BgVisual(id: id, name: names[id] ?? key, key: key));
        });
      }
      _items = out;
      _loaded = true;
    } catch (_) {
      // 后端不可达：缓存留空，画廊给空态。
      _items = const [];
      _loaded = true;
    } finally {
      _inflight = null;
    }
  }
}

/// 背景缩略图：复用 [TexThumb] 的字节 / 对象存储 URL 双通道取图链路。
class BgThumb extends StatelessWidget {
  const BgThumb({
    super.key,
    required this.keyName,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
  });

  final String keyName;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.s);
    if (keyName.trim().isEmpty) {
      return Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.panel,
          borderRadius: radius,
          border: Border.all(color: palette.border),
        ),
        child: Icon(FluentIcons.image_24_regular,
            size: 18, color: palette.iconDisabled),
      );
    }
    return TexThumb(
      keyName: keyName,
      width: width,
      height: height,
      fit: fit,
      borderRadius: radius,
    );
  }
}

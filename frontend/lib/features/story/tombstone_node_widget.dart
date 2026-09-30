import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/save_service.dart';

/// 墓碑节点 UI 组件（P8 Tombstone Semantics）。
///
/// 当 TalkCfg/EvtCfg 的 ID 被删除时，不是硬删除而是写 tombstone：
/// - deleted-talks.json: { "100001": null } (permanent)
/// - or { "100001": ["200099"] } (redirect to new ID)
///
/// 在剧情图模式渲染时，遇到 tombstone ID 就显示灰色方块 + 问号图标，
/// 表示该节点已失效但保持引用完整性。
class TombstoneNodeWidget extends StatelessWidget {
  const TombstoneNodeWidget({
    super.key,
    this.id,
    this.label,
    this.onRestore,
    this.store,
    this.width = 60.0,
    this.height = 40.0,
  });

  /// The original talk/event ID that was deleted.
  final String? id;

  /// Optional custom label (falls back to "Deleted").
  final String? label;

  /// Callback when user clicks to restore (optional).
  final VoidCallback? onRestore;

  /// 阶段 4a：story 级共享墓碑集合。自带删除流程（[onRestore] == null 走
  /// [_handleDelete]）成功后刷新它，否则磁盘墓碑变了而画布仍按旧集合渲染。
  final TombstoneStore? store;

  /// Node width in logical pixels.
  final double width;

  /// Node height in logical pixels.
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: palette.tombstoneFill,
          borderRadius: BorderRadius.circular(4.0),
          border: Border.all(
            color: palette.iconDisabled.withValues(alpha: 0.3),
            width: 1.0,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onRestore ?? (() => _handleDelete(context)),
            borderRadius: BorderRadius.circular(4.0),
            hoverColor: palette.borderHover.withValues(alpha: 0.2),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 16.0,
                    color: palette.textHint,
                  ),
                  const SizedBox(width: 4.0),
                  Text(
                    label ?? 'Deleted',
                    style: TextStyle(
                      fontSize: 11.0,
                      fontWeight: FontWeight.w500,
                      color: palette.textSecondary,
                      fontFamily: 'Segoe UI',
                    ),
                  ),
                  if (id != null) ...[
                    const SizedBox(width: 4.0),
                    Expanded(
                      child: Text(
                        id!,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.0,
                          color: palette.textFaint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Handle deletion click with confirmation dialog
  Future<void> _handleDelete(BuildContext context) async {
    try {
      final success = await SaveService.instance.deleteRecord(
        cfgName: 'TalkCfg', // TODO: Make configurable
        id: id!,
      );

      // 阶段 4a：墓碑落盘了，刷新共享集合（单次拉取，bump 版本 → 卡片重渲染）。
      if (success) store?.reload();

      if (success && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('恢复删除'),
            content: const Text('确定要恢复这个被删除的对话节点吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  onRestore?.call();
                },
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) print('[Tombstone] Failed to delete record: $e');
      // 阶段 2d：失败必须让用户看见——之前只 print，画布与磁盘悄悄分叉。
      if (context.mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: const Text('删除节点失败'),
            content: Text('$e'),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
      }
    }
  }
}

/// P8 墓碑集合的 story 级共享缓存（阶段 4a）。
///
/// 旧实现：每个 talk/option 卡片在 build 时各自
/// `FutureBuilder(future: isDeleted(id))`，一张卡一次
/// GET /api/cfg/deleted_talks——一个 story 几十个节点就是几十次 HTTP。
/// 现在随 story 数据加载**单次**拉取成 `Set<String>`，节点卡片
/// [contains] 同步读、零请求；[version] 只在集合**内容**变化时递增并
/// notifyListeners，宿主（画布 State 订阅 + 卡片缓存签名）据此重渲染
/// 受影响卡片。删除成功 / 保存删行后调用 [reload] 即可刷新。
class TombstoneStore extends ChangeNotifier {
  Set<String> _ids = const {};
  int _version = 0;
  bool _loading = false;
  bool _pendingReload = false;
  bool _disposed = false;

  /// 集合内容版本号：卡片缓存签名的一部分——只有真正变了才作废卡片，
  /// 无变化的刷新不白白重建整批。
  int get version => _version;

  /// 当前被删除（已立墓碑）的记录 id 集合（只读快照）。
  Set<String> get ids => _ids;

  /// 该 id 是否已被删除。同步读取，不发请求。
  bool contains(String id) => _ids.contains(id);

  /// 单次拉取 GET /api/cfg/deleted_talks；内容变化才 bump [version] 并通知。
  ///
  /// 加载在途时重复调用会折叠为结束后再拉一次（删除/保存等多个触发点
  /// 同时打进来时，后端仍只见串行单飞请求）；请求失败保留旧集合，
  /// 只 print 不抛——墓碑显示是增强信息，不该拖垮宿主加载。
  Future<void> reload() async {
    if (_disposed) return;
    if (_loading) {
      _pendingReload = true;
      return;
    }
    _loading = true;
    try {
      do {
        _pendingReload = false;
        try {
          final res = await ApiClient.instance.get('/api/cfg/deleted_talks');
          if (_disposed) return;
          final tombstones =
              (res['tombstones'] as Map?)?.cast<String, dynamic>() ??
              const {};
          final next = tombstones.keys.toSet();
          if (!setEquals(next, _ids)) {
            _ids = next;
            _version++;
            notifyListeners();
          }
        } catch (e) {
          if (kDebugMode) print('[Tombstone] Failed to load tombstones: $e');
        }
      } while (_pendingReload && !_disposed);
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Delete a record using tombstone semantics.
///
/// 阶段 2d：失败向上抛（调用方负责 toast）；此前一律吞成 false，
/// 墓碑删除静默失败后画布仍删了节点，与磁盘状态分叉。revision 现在
/// 随删除响应回传并由 SaveService 采用，不再手动 invalidateCache
/// （清空缓存反而让后续 PUT 不带 revision、跳过冲突校验）。
Future<bool> deleteRecord({
  required String cfgName,
  required String id,
}) async {
  return SaveService.instance.deleteRecord(
    cfgName: cfgName,
    id: id,
  );
}

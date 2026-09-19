import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import '../../core/api_client.dart';
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
    this.width = 60.0,
    this.height = 40.0,
  });

  /// The original talk/event ID that was deleted.
  final String? id;

  /// Optional custom label (falls back to "Deleted").
  final String? label;

  /// Callback when user clicks to restore (optional).
  final VoidCallback? onRestore;

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
          color: Theme.of(context).brightness == Brightness.light
              ? const Color(0xFFE0E0E0) // Light gray for light mode
              : const Color(0xFF424242), // Dark gray for dark mode
          borderRadius: BorderRadius.circular(4.0),
          border: Border.all(
            color: Colors.grey.shade500.withOpacity(0.3),
            width: 1.0,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onRestore ?? (() => _handleDelete(context)),
            borderRadius: BorderRadius.circular(4.0),
            hoverColor: Colors.grey.shade300.withOpacity(0.2),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 16.0,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4.0),
                  Text(
                    label ?? 'Deleted',
                    style: TextStyle(
                      fontSize: 11.0,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade700,
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
                          color: Colors.grey.shade500,
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
      print('[Tombstone] Failed to delete record: $e');
    }
  }
}

/// Check if an ID is a tombstone by looking at deleted-talks.json
/// Returns true if the ID has been deleted via tombstone mechanism
Future<bool> isDeleted(String id) async {
  try {
    // Load deleted talks from workspace
    final res = await ApiClient.instance.get('/api/cfg/deleted_talks');
    
    final tombstones = (res['tombstones'] as Map?)?.cast<String, dynamic>() ?? {};
    return tombstones.containsKey(id);
  } catch (e) {
    print('[Tombstone] Failed to check tombstone status: $e');
    return false;
  }
}

/// Delete a record using tombstone semantics
Future<bool> deleteRecord({
  required String cfgName,
  required String id,
}) async {
  try {
    final result = await SaveService.instance.deleteRecord(
      cfgName: cfgName,
      id: id,
    );
    
    // Invalidate revision cache after successful delete
    SaveService.instance.invalidateCache();
    
    return result;
  } catch (e) {
    print('[Tombstone] Failed to delete: $e');
    return false;
  }
}

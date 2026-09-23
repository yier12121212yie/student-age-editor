/// 保存服务（S3）：封装 PUT/PATCH /api/cfg/<name>的 revision 验证与 conflict 处理。
///
/// 实现 P5 Revision Mechanism:
/// - GET /api/workspace/revision 获取当前 workspace 的内容指纹 (SHA-256[:20])
/// - 所有保存请求携带该 revision，不匹配时返回 409 Conflict + current_revision
/// - 前端收到 409 后刷新 revision 并提示用户冲突详情
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

class SaveResult {
  // 每个命名构造都要初始化全部 final 字段：不适用的字段给默认值。
  SaveResult.success({
    required this.cfg,
    required this.mtimeNs,
    required this.snapshot,
    this.appliedSet = const {},
    this.appliedRemove = const [],
    this.reason,
    this.detail,
    this.currentRevision,
    this.data,
    this.message,
  });

  SaveResult.conflict({
    required this.cfg,
    required this.reason,
    required this.detail,
    required this.currentRevision,
    this.mtimeNs,
    this.data,
    this.appliedSet = const {},
    this.appliedRemove = const [],
    this.snapshot,
    this.message,
  });

  SaveResult.error({
    required this.cfg,
    required this.message,
    this.mtimeNs,
    this.snapshot,
    this.appliedSet = const {},
    this.appliedRemove = const [],
    this.reason,
    this.detail,
    this.currentRevision,
    this.data,
  });

  final String? cfg;
  final int? mtimeNs;
  final String? snapshot;

  // success case
  final Map<String, dynamic> appliedSet;
  final List<dynamic> appliedRemove;

  // conflict case
  final String? reason;
  final String? detail;
  final String? currentRevision;
  final Map<String, dynamic>? data;

  // error case
  final String? message;

  bool get isSuccess => cfg != null && reason == null && message == null;
  bool get isConflict => reason != null;
  bool get isError => message != null;
}

/// Save service with revision-based optimistic locking.
class SaveService {
  SaveService._();
  static final SaveService instance = SaveService._();

  /// Current workspace revision from last GET /api/workspace/revision.
  /// Clients should refresh before each save batch.
  String? _cachedRevision;

  /// Refresh revision from backend (called before batch saves).
  Future<void> refreshRevision() async {
    try {
      final res = await ApiClient.instance.get('/api/workspace/revision');
      _cachedRevision = res['revision'] as String?;
      if (kDebugMode) {
        print('[SaveService] Revision refreshed: ${_cachedRevision?.substring(0, 8)}... '
              '(${res['computed_at_ms']}ms, ${res['files_scanned']} files)');
      }
    } catch (e) {
      if (kDebugMode) print('[SaveService] Failed to refresh revision: $e');
      rethrow;
    }
  }

  /// Get current cached revision without network request.
  String? get currentRevision => _cachedRevision;

  /// Save full table data for a configuration table.
  ///
  /// [cfgName] e.g., "TalkCfg", "EvtCfg"
  /// [data] full table dict {id -> row}
  /// [ifMatch] optional conditional headers (not commonly used)
  ///
  /// Returns SaveResult.success or .conflict or .error
  Future<SaveResult> saveTable({
    required String cfgName,
    required Map<String, dynamic> data,
    Map<String, dynamic>? ifMatch,
  }) async {
    final body = <String, dynamic>{
      'data': data,
    };
    if (_cachedRevision != null && _cachedRevision!.isNotEmpty) {
      body['revision'] = _cachedRevision;
    }
    if (ifMatch != null) {
      body['if_match'] = ifMatch;
    }

    try {
      final res = await ApiClient.instance.put('/api/cfg/$cfgName', body: body);
      
      return SaveResult.success(
        cfg: res['cfg'] as String?,
        mtimeNs: res['mtime_ns'] as int?,
        snapshot: res['snapshot'] as String?,
        // 后端只回计数（数字），不是行对象/数组；形状不匹配时退化成空集合，
        // 绝不能对数字做 as Map? 硬转（那会在保存成功路径上抛 TypeError）。
        appliedSet: res['applied_set'] is Map
            ? (res['applied_set'] as Map).cast<String, dynamic>()
            : const {},
        appliedRemove:
            res['applied_remove'] is List ? (res['applied_remove'] as List) : const [],
      );
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.code == 'conflict') {
        final payload = e.message.contains('current_revision')
            ? jsonDecode(e.message)
            : null;

        return SaveResult.conflict(
          cfg: cfgName,
          reason: payload?['reason'] as String? ?? e.message,
          detail: payload?['detail'] as String? ?? '文件已被外部修改或与其他会话冲突',
          currentRevision: payload?['current_revision'] as String?,
          mtimeNs: payload?['mtime_ns'] as int?,
          data: (payload?['data'] as Map?)?.cast<String, dynamic>(),
        );
      }
      
      return SaveResult.error(
        cfg: cfgName,
        message: e.toString(),
      );
    }
  }

  /// Apply incremental patch to a configuration table.
  ///
  /// Use this instead of full table save when only a few rows changed.
  /// [patchSet] new/updated rows {id -> row}
  /// [patchRemove] IDs to delete ['id1', 'id2', ...]
  Future<SaveResult> applyPatch({
    required String cfgName,
    required Map<String, dynamic> patchSet,
    required List<String> patchRemove,
  }) async {
    final body = <String, dynamic>{
      'patch': {
        'set': patchSet,
        'remove': patchRemove,
      },
    };
    if (_cachedRevision != null && _cachedRevision!.isNotEmpty) {
      body['revision'] = _cachedRevision;
    }

    try {
      final res = await ApiClient.instance.put('/api/cfg/$cfgName', body: body);
      
      return SaveResult.success(
        cfg: res['cfg'] as String?,
        mtimeNs: res['mtime_ns'] as int?,
        snapshot: res['snapshot'] as String?,
        // 后端只回计数（数字），不是行对象/数组；形状不匹配时退化成空集合，
        // 绝不能对数字做 as Map? 硬转（那会在保存成功路径上抛 TypeError）。
        appliedSet: res['applied_set'] is Map
            ? (res['applied_set'] as Map).cast<String, dynamic>()
            : const {},
        appliedRemove:
            res['applied_remove'] is List ? (res['applied_remove'] as List) : const [],
      );
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.code == 'conflict') {
        final payload = e.message.contains('current_revision')
            ? jsonDecode(e.message)
            : null;

        return SaveResult.conflict(
          cfg: cfgName,
          reason: payload?['reason'] as String? ?? e.message,
          detail: payload?['detail'] as String? ?? '文件已被外部修改或与其他会话冲突',
          currentRevision: payload?['current_revision'] as String?,
          mtimeNs: payload?['mtime_ns'] as int?,
          data: (payload?['data'] as Map?)?.cast<String, dynamic>(),
        );
      }
      
      return SaveResult.error(
        cfg: cfgName,
        message: e.toString(),
      );
    }
  }

  /// Delete a record with tombstone semantics (P8 feature).
  ///
  /// Instead of hard-delete, creates tombstone in deleted-talks.json:
  /// - Permanent tombstone (null): placeholder for inert_talk
  /// - Redirect mapping: old_id -> [new_id] for ID rebirth
  Future<bool> deleteRecord({
    required String cfgName,
    required String id,
    Map<String, dynamic>? body,
  }) async {
    // Add revision parameter if available
    final bodyParams = <String, dynamic>{};
    if (_cachedRevision != null && _cachedRevision!.isNotEmpty) {
      bodyParams['revision'] = _cachedRevision!;
    }
    if (body != null) {
      bodyParams.addAll(body);
    }
    
    try {
      final res = await ApiClient.instance.delete('/api/cfg/$cfgName/$id', body: bodyParams.isNotEmpty ? bodyParams : null);
      
      if (res['ok'] == true) {
        if (kDebugMode) {
          print('[SaveService] Deleted $cfgName/$id '
                '(tombstone: ${res['tombstone_created']})');
        }
        return true;
      }
      return false;
    } on ApiException catch (e) {
      if (kDebugMode) {
        print('[SaveService] Failed to delete $cfgName/$id: ${e.message}');
      }
      return false;
    }
  }

  /// Clear the revision cache (called after successful batch save).
  void invalidateCache() {
    _cachedRevision = null;
  }

  /// Pre-load revision before batch operations. Call this once per save session.
  Future<void> prepareForBatchSave() async {
    await refreshRevision();
  }
}

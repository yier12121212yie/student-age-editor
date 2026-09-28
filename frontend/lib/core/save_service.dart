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
      if (kDebugMode && _cachedRevision != null) {
        // 短于 8 字符（后端异常/测试桩）时 substring 会 RangeError。
        final head = _cachedRevision!.length > 8
            ? _cachedRevision!.substring(0, 8)
            : _cachedRevision;
        print('[SaveService] Revision refreshed: $head... '
              '(${res['computed_at_ms']}ms, ${res['files_scanned']} files)');
      }
    } catch (e) {
      if (kDebugMode) print('[SaveService] Failed to refresh revision: $e');
      rethrow;
    }
  }

  /// Get current cached revision without network request.
  String? get currentRevision => _cachedRevision;

  /// 409 → 冲突信封（非冲突返回 null）。阶段 2d 两处修复：
  /// 1) 旧判定 `e.code == 'conflict'` 永不成立（后端信封只有
  ///    error=="conflict"，从无 code 字段），冲突一律掉进 error，
  ///    三选对话框与指纹重试全是死代码；
  /// 2) 错误体非 JSON 时容错：解析失败降级为空信封 + message 文本兜底，
  ///    绝不抛 FormatException。非-utf8 源保护等 409 仍归 error。
  static Map<String, dynamic>? _conflictPayload(ApiException e) {
    if (e.statusCode != 409) return null;
    final body = e.body;
    if (body != null) {
      final err = body['error']?.toString();
      if (err == 'conflict' ||
          e.code == 'conflict' ||
          body.containsKey('current_revision') ||
          body.containsKey('conflicting_keys')) {
        return body;
      }
      return null;
    }
    // 无结构化信封：错误体非 JSON 或被旧链路降级成原文。
    final m = e.message;
    if (m == 'conflict' || m.contains('current_revision') || m.contains('"conflict"')) {
      try {
        final decoded = jsonDecode(m);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } catch (_) {
        // 非 JSON 容错：走空信封
      }
      return const <String, dynamic>{};
    }
    return null;
  }

  Future<SaveResult> _conflictResult(
      String cfgName, ApiException e, Map<String, dynamic> payload) async {
    String? currentRevision = payload['current_revision'] as String?;
    if (currentRevision == null) {
      // 信封没带新指纹：尽力补拉一次，让「覆盖并重试」直接携带。
      try {
        await refreshRevision();
        currentRevision = _cachedRevision;
      } catch (_) {}
    }
    return SaveResult.conflict(
      cfg: cfgName,
      reason: payload['reason'] as String? ?? e.message,
      detail: payload['detail'] as String? ?? '文件已被外部修改或与其他会话冲突',
      currentRevision: currentRevision,
      mtimeNs: payload['mtime_ns'] is int ? payload['mtime_ns'] as int : null,
      data: (payload['data'] as Map?)?.cast<String, dynamic>(),
    );
  }

  /// 写成功后端回传的指纹（阶段 2d 假冲突修复）：写一张表必然改变 workspace
  /// hash，若 _cachedRevision 停在旧值，同批第二张表的 PUT 必被 verify 误拒。
  void _adoptRevision(dynamic res) {
    if (res is Map) {
      final fresh = res['revision'];
      if (fresh is String && fresh.isNotEmpty) _cachedRevision = fresh;
    }
  }

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
      // putRaw：整表 jsonEncode 搬进后台 isolate（性能 P0-3），40MB 表保存
      // 期间 UI 不冻结；返回形状与 put 完全一致，调用方（SaveResult 解析、
      // 409 冲突分支）无需变更。
      final res = await ApiClient.instance.putRaw('/api/cfg/$cfgName', body: body);
      _adoptRevision(res);

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
      final payload = _conflictPayload(e);
      if (payload != null) return _conflictResult(cfgName, e, payload);

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
      // 与 saveTable 一致走 putRaw：patch 里 set 可能带大量整行，编码同样
      // 应离 isolate；返回形状不变。
      final res = await ApiClient.instance.putRaw('/api/cfg/$cfgName', body: body);
      _adoptRevision(res);
      
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
      final payload = _conflictPayload(e);
      if (payload != null) return _conflictResult(cfgName, e, payload);

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
      _adoptRevision(res);

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
      // 阶段 2d：失败不再吞成 false——调用方拿 false 与「成功但无墓碑」无法
      // 区分，静默失败导致画布删了节点、磁盘上记录还在。向上抛给调用方 toast。
      rethrow;
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

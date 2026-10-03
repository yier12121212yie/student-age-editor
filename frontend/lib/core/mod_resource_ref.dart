/// 自托管网页版大资源（贴图/配乐/视频）导入：字节留在 COS，模组只存引用。
///
/// 与 [StagedModImport]（整包导入、落盘）不同，这里走模块 A 的「直传不落盘」
/// 形态：upload/request → PUT 预签名 → `POST /api/mods/add_ref` 把暂存对象钉成
/// 模组引用（status=linked），模组目录只写一条 cos_resources.json 索引。
/// 导出时由服务端把引用资源从 COS 拉回、与本地盘文件拼进 zip。
library;

import 'dart:typed_data';

import 'api_client.dart';
import 'blob_put.dart';

class StagedResourceRef {
  StagedResourceRef._();

  /// web 上超过该阈值的单文件改走「留 COS 只存引用」；小文件继续走
  /// `/api/mod/import_files`（base64 落盘），保证游戏/预览在服务器上能直接
  /// 读盘。阈值与整包导入一致（48 MiB）。
  static const int refThresholdBytes = 48 * 1024 * 1024;

  /// 上传单个资源并登记为模组引用，返回 add_ref 的 saved 条目
  /// （`{name, path, size, cos, file_id, audio_id, audio_error}`）。
  static Future<Map<String, dynamic>> uploadAsRef(
    String name,
    Uint8List bytes, {
    String? dir,
    bool registerAudio = false,
    void Function(String label, double? frac)? onStage,
  }) async {
    onStage?.call('申请直传', null);
    final init = await ApiClient.instance.post(
      '/api/v1/files/upload/request',
      body: <String, dynamic>{'name': name, 'size': bytes.length},
      timeout: const Duration(seconds: 60),
    );
    final initMap = (init as Map).cast<String, dynamic>();
    final fileId = (initMap['file_id'] ?? '').toString();
    final uploadUrl = (initMap['upload_url'] ?? '').toString();
    if (fileId.isEmpty || uploadUrl.isEmpty) {
      throw ApiException(500, 'upload/request 未返回 file_id/upload_url');
    }

    onStage?.call('直传对象存储', 0);
    await putBytesToUrl(bytes, uploadUrl, onProgress: (sent, total) {
      if (total > 0) onStage?.call('直传对象存储', sent / total);
    });

    // 不调 upload/complete：资源留在 COS，由 add_ref 钉成持久引用。
    onStage?.call('登记引用', null);
    final res = await ApiClient.instance.post(
      '/api/mods/add_ref',
      body: <String, dynamic>{
        'file_id': fileId,
        'name': name,
        if (dir != null && dir.isNotEmpty) 'dir': dir,
        'register_audio': registerAudio,
      },
      timeout: const Duration(seconds: 60),
    );
    final rmap = (res as Map).cast<String, dynamic>();
    final errors = rmap['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final msg = first is Map ? (first['error'] ?? '登记引用失败').toString() : '登记引用失败';
      throw ApiException(400, msg);
    }
    final saved = rmap['saved'];
    if (saved is List && saved.isNotEmpty && saved.first is Map) {
      return (saved.first as Map).cast<String, dynamic>();
    }
    throw ApiException(500, 'add_ref 未返回 saved');
  }
}

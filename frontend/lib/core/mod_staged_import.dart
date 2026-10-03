/// 自托管网页版大模组包导入（模块 A 文件流转通道）。
///
/// 带贴图/配乐的模组 zip 动辄数百 MB，超过 base64 通道（`*_upload`）受传输层
/// 请求体上限与浏览器内存的双重限制，自托管导入必失败。这里改走直传链路：
///   1. `POST /api/v1/files/upload/request` 拿 COS 预签名 PUT URL；
///   2. 浏览器 Blob 直传（[putXFileToUrl]，不占 Dart 堆）；
///   3. `POST /api/v1/files/upload/complete` 触发 Worker 内网落盘；
///   4. 轮询 `GET /api/v1/files/{id}` 至 `archived`；
///   5. `POST /api/mods/import_staged {file_id}` 走服务端同管线解压导入。
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'api_client.dart';
import 'blob_put.dart';

class StagedModImport {
  StagedModImport._();

  /// web 上超过该阈值的大包改走直传通道；阈值以下维持 base64 `import_upload`
  /// 既有行为（48 MiB 也避开浏览器整包 base64 的内存放大）。
  static const int directUploadThresholdBytes = 48 * 1024 * 1024;

  /// [onStage] 回报阶段标签与可选进度（0..1，null=不确定）。
  /// 返回与 `/api/mods/import_upload` 相同的信封（`{ok, mod}`）。
  static Future<Map<String, dynamic>> run(
    XFile file, {
    void Function(String label, double? frac)? onStage,
  }) async {
    final int size = await file.length();
    onStage?.call('申请直传', null);
    final init = await ApiClient.instance.post(
      '/api/v1/files/upload/request',
      body: <String, dynamic>{'name': file.name, 'size': size},
      timeout: const Duration(seconds: 60),
    );
    final initMap = (init as Map).cast<String, dynamic>();
    final fileId = (initMap['file_id'] ?? '').toString();
    final uploadUrl = (initMap['upload_url'] ?? '').toString();
    if (fileId.isEmpty || uploadUrl.isEmpty) {
      throw ApiException(500, 'upload/request 未返回 file_id/upload_url');
    }

    onStage?.call('直传对象存储', 0);
    await putXFileToUrl(file, uploadUrl, onProgress: (sent, total) {
      if (total > 0) onStage?.call('直传对象存储', sent / total);
    });

    onStage?.call('服务器落盘', null);
    await ApiClient.instance.post(
      '/api/v1/files/upload/complete',
      body: <String, dynamic>{'file_id': fileId},
      timeout: const Duration(seconds: 30),
    );

    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (true) {
      final rec = await ApiClient.instance.get('/api/v1/files/$fileId');
      final map = rec is Map ? rec.cast<String, dynamic>() : const <String, dynamic>{};
      final status = (map['status'] ?? '').toString();
      if (status == 'archived' || status == 'ready') break;
      if (status == 'failed') {
        throw ApiException(500, '服务器落盘失败：${map['error'] ?? '未知原因'}');
      }
      if (status == 'pending_upload') {
        throw ApiException(409, '上传未完成（直传可能中断），请重试');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw ApiException(504, '等待服务器落盘超时');
      }
      final retry = ((map['retry_after'] as num?)?.toInt() ?? 3).clamp(1, 15);
      await Future<void>.delayed(Duration(seconds: retry));
    }

    onStage?.call('解压导入', null);
    final res = await ApiClient.instance.post(
      '/api/mods/import_staged',
      body: <String, dynamic>{'file_id': fileId},
      timeout: const Duration(minutes: 30),
    );
    return (res as Map).cast<String, dynamic>();
  }
}

/// 自托管网页版大模组包导入（模块 A 文件流转通道）。
///
/// 带贴图/配乐的模组 zip 动辄数百 MB~GB，超过 base64 通道（`*_upload`）受传输
/// 层请求体上限与浏览器内存的双重限制，自托管导入必失败。这里改走直传链路：
///   0. 选路：`GET /api/v1/files/upload/modes` —— 配置了 COS 走 1/2，否则走
///      本地分片（[LocalChunkUpload]，逐片 PUT 给本机后端，免对象存储）；
///   1. 小包：`POST /api/v1/files/upload/request` 拿 COS 预签名 PUT URL，
///      浏览器 Blob 直传（[putXFileToUrl]，不占 Dart 堆）；
///   2. 大包：`POST /api/v1/files/upload/multipart/init` 申请 COS 分片上传，
///      逐片向 `.../multipart/sign` 换取预签名 URL，再把 Blob 的对应区间
///      `slice` 直传（[putXFileRangeToUrl]），最后 `.../multipart/complete`
///      交回各片 ETag 合并——分片流式，单次请求体与内存都被 part_size 兜住；
///   3. `POST /api/v1/files/upload/complete` 触发 Worker 内网落盘（本地分片
///      在 complete 时已落盘，跳过此步）；
///   4. 轮询 `GET /api/v1/files/{id}` 至 `archived`（本地分片已 archived）；
///   5. `POST /api/mods/import_staged {file_id}` 走服务端流式解压导入。
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'api_client.dart';
import 'blob_put.dart';
import 'local_chunk_upload.dart';
import 'long_task_progress.dart';

class StagedModImport {
  StagedModImport._();

  /// web 上超过该阈值的大包改走直传通道；阈值以下维持 base64 `import_upload`
  /// 既有行为（48 MiB 也避开浏览器整包 base64 的内存放大）。
  static const int directUploadThresholdBytes = 48 * 1024 * 1024;

  /// 直传通道里超过该阈值改用 COS 分片上传；以下仍走单次 PUT（更少的后端
  /// 往返）。分片大小由后端按总大小自适应返回（默认 8 MiB）。
  static const int multipartThresholdBytes = 64 * 1024 * 1024;

  /// [onStage] 回报阶段标签与可选进度（0..1，null=不确定）。
  /// [isCancelled] 返回 true 时在下一个检查点抛出 [LongTaskCancelled]（前端层取消）。
  /// 返回与 `/api/mods/import_upload` 相同的信封（`{ok, mod}`）。
  static Future<Map<String, dynamic>> run(
    XFile file, {
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  }) async {
    _checkCancel(isCancelled);
    final int size = await file.length();
    final bool local = await LocalChunkUpload.useLocal();
    _checkCancel(isCancelled);
    final String fileId;
    if (local) {
      fileId = await LocalChunkUpload.uploadXFile(
        file,
        onStage: onStage,
        isCancelled: isCancelled,
      );
    } else {
      fileId = size >= multipartThresholdBytes
          ? await _uploadMultipart(file, size, onStage, isCancelled)
          : await _uploadSingle(file, size, onStage, isCancelled);
    }
    return _finishImport(fileId, onStage, isCancelled, local: local);
  }

  /// 取消检查点：已取消则抛出 [LongTaskCancelled]（调用方静默吞掉）。
  static void _checkCancel(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const LongTaskCancelled();
  }

  /// 单次 PUT 直传（小包）。
  static Future<String> _uploadSingle(
    XFile file,
    int size,
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  ) async {
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
    _checkCancel(isCancelled);
    onStage?.call('直传对象存储', 0);
    await putXFileToUrl(file, uploadUrl, onProgress: (sent, total) {
      if (total > 0) onStage?.call('直传对象存储', sent / total);
    });
    return fileId;
  }

  /// COS 分片上传（大包）：逐片签名 -> 直传 -> 收 ETag -> 合并。
  static Future<String> _uploadMultipart(
    XFile file,
    int size,
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  ) async {
    onStage?.call('申请分片上传', null);
    final init = await ApiClient.instance.post(
      '/api/v1/files/upload/multipart/init',
      body: <String, dynamic>{'name': file.name, 'size': size},
      timeout: const Duration(seconds: 60),
    );
    final initMap = (init as Map).cast<String, dynamic>();
    final fileId = (initMap['file_id'] ?? '').toString();
    final partSize = (initMap['part_size'] as num?)?.toInt() ?? 0;
    final partCount = (initMap['part_count'] as num?)?.toInt() ?? 0;
    if (fileId.isEmpty || partSize <= 0 || partCount <= 0) {
      throw ApiException(500, 'multipart/init 未返回 file_id/part_size/part_count');
    }

    final parts = <Map<String, dynamic>>[];
    for (var i = 1; i <= partCount; i++) {
      // 取消检查点：已取消则中止 multipart，避免在 COS 留下半成品。
      if (isCancelled?.call() ?? false) {
        await _abortMultipart(fileId);
        throw const LongTaskCancelled();
      }
      final offset = (i - 1) * partSize;
      final length = (size - offset) < partSize ? (size - offset) : partSize;
      final base = (i - 1) / partCount;
      final label = '分片直传 $i/$partCount';
      onStage?.call(label, base);

      final sign = await ApiClient.instance.post(
        '/api/v1/files/upload/multipart/sign',
        body: <String, dynamic>{'file_id': fileId, 'part_number': i},
        timeout: const Duration(seconds: 60),
      );
      final signMap = (sign as Map).cast<String, dynamic>();
      final urls = signMap['parts'];
      final partUrl = urls is List && urls.isNotEmpty && urls.first is Map
          ? ((urls.first as Map)['part_url'] ?? '').toString()
          : '';
      if (partUrl.isEmpty) {
        throw ApiException(500, 'multipart/sign 未返回分片 $i 的 part_url');
      }

      String etag;
      try {
        etag = await putXFileRangeToUrl(
          file,
          partUrl,
          offset: offset,
          length: length,
          onProgress: (sent, total) {
            if (total > 0) onStage?.call(label, base + (sent / total) / partCount);
          },
        );
      } catch (e) {
        // 任一片失败：尽力取消本次 multipart，避免在 COS 留下不可见的半成品。
        await _abortMultipart(fileId);
        rethrow;
      }
      if (etag.isEmpty) {
        throw ApiException(
            500, '分片 $i 未返回 ETag（对象存储桶需放行 ExposeHeader ETag 的 CORS）');
      }
      parts.add(<String, dynamic>{'part_number': i, 'etag': etag});
      onStage?.call(label, i / partCount);
    }

    onStage?.call('合并分片', null);
    await ApiClient.instance.post(
      '/api/v1/files/upload/multipart/complete',
      body: <String, dynamic>{'file_id': fileId, 'parts': parts},
      timeout: const Duration(minutes: 10),
    );
    return fileId;
  }

  static Future<void> _abortMultipart(String fileId) async {
    try {
      await ApiClient.instance.post(
        '/api/v1/files/upload/multipart/abort',
        body: <String, dynamic>{'file_id': fileId},
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      // best-effort：失败不影响向调用方抛出原始错误。
    }
  }

  /// 通知落盘 -> 轮询归档 -> 服务端流式解压导入。
  ///
  /// [local] 为 true 时字节已在本地分片 complete 时落盘（status=archived），
  /// 跳过 COS Worker 的 upload/complete 与落盘轮询，直接解压导入。
  static Future<Map<String, dynamic>> _finishImport(
    String fileId,
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled, {
    bool local = false,
  }) async {
    _checkCancel(isCancelled);
    if (!local) {
      onStage?.call('服务器落盘', null);
      await ApiClient.instance.post(
        '/api/v1/files/upload/complete',
        body: <String, dynamic>{'file_id': fileId},
        timeout: const Duration(seconds: 30),
      );

      final deadline = DateTime.now().add(const Duration(minutes: 30));
      while (true) {
        _checkCancel(isCancelled);
        final rec = await ApiClient.instance.get('/api/v1/files/$fileId');
        final map =
            rec is Map ? rec.cast<String, dynamic>() : const <String, dynamic>{};
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

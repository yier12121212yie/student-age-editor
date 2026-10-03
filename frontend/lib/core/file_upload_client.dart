/// 增强版文件上传客户端（支持 S3 直传）
///
/// 替代/扩展 [importLocalAssets] 的上传逻辑，实现智能选择上传模式：
/// - S3 直传：大文件通过预签名 URL 直接 PUT 到对象存储
/// - 服务器上传：小文件使用 base64 POST 到后端
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 上传初始化请求体
class UploadInitiateRequest {
  final String name;
  final int size;
  final String? kind;
  final String? storyId;

  UploadInitiateRequest({
    required this.name,
    required this.size,
    this.kind,
    this.storyId,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'size': size,
        if (kind != null) 'kind': kind!,
        if (storyId != null) 'story_id': storyId!,
      };
}

/// 上传初始化响应体
class UploadInitiateResponse {
  final String fileId;
  final String uploadMode; // "s3_direct" | "server_upload"
  final int thresholdBytes;
  final String? uploadUrl;
  final String? s3Key;
  final String method;
  final int? expiresInSeconds;

  UploadInitiateResponse({
    required this.fileId,
    required this.uploadMode,
    required this.thresholdBytes,
    this.uploadUrl,
    this.s3Key,
    required this.method,
    this.expiresInSeconds,
  });

  factory UploadInitiateResponse.fromJson(Map<String, dynamic> json) {
    return UploadInitiateResponse(
      fileId: json['file_id'] as String,
      uploadMode: json['upload_mode'] as String,
      thresholdBytes: json['threshold_bytes'] as int,
      uploadUrl: json['upload_url'] as String?,
      s3Key: json['s3_key'] as String?,
      method: json['method'] as String,
      expiresInSeconds: json['expires_in'] as int?,
    );
  }
}

/// S3 上传完成通知请求体
class S3CompleteRequest {
  final String fileId;
  final String? etag;

  S3CompleteRequest({required this.fileId, this.etag});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'file_id': fileId,
        if (etag != null) 'etag': etag!,
      };
}

/// 上传进度回调
typedef UploadProgressCallback = void Function(int current, int total);

/// 文件上传器
class FileUploadClient {
  final ApiClient apiClient;

  FileUploadClient(this.apiClient);

  /// 获取上传模式（是否需要 S3 直传）
  Future<UploadInitiateResponse> initiateUpload({
    required String name,
    required int size,
    String? kind,
    String? storyId,
  }) async {
    final body = UploadInitiateRequest(
      name: name,
      size: size,
      kind: kind,
      storyId: storyId,
    ).toJson();

    final response = await apiClient.post(
      '/api/v1/files/upload/initiate',
      body: body,
      timeout: const Duration(seconds: 30),
    );

    return UploadInitiateResponse.fromJson(response as Map<String, dynamic>);
  }

  /// 上传到 S3（PUT 模式）
  Future<String?> uploadToS3({
    required String url,
    required Uint8List data,
    UploadProgressCallback? onProgress,
  }) async {
    try {
      final response = await http.put(
        Uri.parse(url),
        body: data,
        headers: {'Content-Type': 'application/octet-stream'},
      );

      if (response.statusCode == 200 || response.statusCode == 201 || response.statusCode == 204) {
        return response.headers['etag'];
      } else {
        throw Exception('S3 PUT failed: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      throw Exception('S3 upload error: $e');
    }
  }

  /// 通知 S3 上传完成
  Future<void> completeS3Upload({
    required String fileId,
    String? etag,
  }) async {
    final body = S3CompleteRequest(fileId: fileId, etag: etag).toJson();

    await apiClient.post(
      '/api/v1/files/upload/s3-complete',
      body: body,
      timeout: const Duration(seconds: 10),
    );
  }

  /// 服务器上传（base64 POST，用于小文件）
  Future<Map<String, dynamic>> uploadToServer({
    required String fileId,
    required String safeName,
    required String dir,
    required Uint8List data,
  }) async {
    // 使用现有的 /api/mod/import_files 接口
    final body = <String, dynamic>{
      'files': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': safeName,
          'data': base64Encode(data),
          'dir': dir.isNotEmpty ? dir : null,
        },
      ],
      'register_audio': false,
    };

    final result = await apiClient.post(
      '/api/mod/import_files',
      body: body,
      timeout: const Duration(minutes: 5),
    );

    return result as Map<String, dynamic>;
  }

  /// 统一的上传流程（自动选择最佳方式）
  Future<String?> uploadFile({
    required String name,
    required Uint8List data,
    String? kind,
    String? storyId,
    String? initialDir,
    UploadProgressCallback? onProgress,
  }) async {
    // Step 1: 发起上传初始化
    final init = await initiateUpload(
      name: name,
      size: data.length,
      kind: kind,
      storyId: storyId,
    );

    // Step 2: 根据模式执行上传
    if (init.uploadMode == 's3_direct') {
      // S3 直传路径
      if (init.uploadUrl == null) {
        throw Exception('S3 upload URL not provided');
      }

      // 分块上传以显示进度
      String? etag;
      if (onProgress != null) {
        // 上报初始进度（0 / 总字节）
        onProgress(0, data.length);
      }

      etag = await uploadToS3(
        url: init.uploadUrl!,
        data: data,
        onProgress: onProgress,
      );

      // Step 3: 通知完成
      await completeS3Upload(
        fileId: init.fileId,
        etag: etag,
      );

      return etag;
    } else {
      // 服务器上传路径（小文件）
      String dir = initialDir ?? '';
      
      // 根据扩展名推断目录
      if (dir.isEmpty && name.contains('.')) {
        final ext = name.split('.').last.toLowerCase();
        if (['png', 'jpg', 'jpeg', 'webp', 'bmp'].contains(ext)) {
          dir = 'Textures';
        } else if (['wav', 'mp3', 'ogg', 'm4a'].contains(ext)) {
          dir = 'Audios';
        }
      }

      final result = await uploadToServer(
        fileId: init.fileId,
        safeName: name,
        dir: dir,
        data: data,
      );

      // 检查是否有错误
      if (result['errors'] != null && (result['errors'] as List).isNotEmpty) {
        throw Exception((result['errors'] as List)[0]['error'] as String);
      }

      if (result['saved'] != null && (result['saved'] as List).isNotEmpty) {
        return (result['saved'] as List)[0]['path'] as String?;
      }

      throw Exception('Server upload returned no success data');
    }
  }
}

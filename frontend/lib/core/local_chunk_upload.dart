/// 大文件本地分片上传（免对象存储）。
///
/// 自托管服务器未配置 COS 时，大模组包 / 大资源仍然要能导入：浏览器把文件
/// 切成若干片（后端默认 8 MiB，正好落在 httpd 的 raw_body 保留上限内），
/// 逐片 `PUT /api/v1/files/upload/local/{id}/part/{n}`，最后由服务端拼接写
/// 本地大容量盘并落成 `archived` 记录。之后的导入 / 引用流程与 COS 通道
/// 完全一致（[StagedModImport] / [StagedResourceRef]）。
///
/// 选路：先问 `GET /api/v1/files/upload/modes`。配置了 COS 时优先 COS（可
/// 走 CDN / 内网落盘），否则用本地分片。旧后端没有该端点时返回 false，
/// 调用方退回既有 COS 路径，行为不变。
library;

import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'api_client.dart';
import 'long_task_progress.dart';

class LocalChunkUpload {
  LocalChunkUpload._();

  /// modes 不可用 / 未返回 part_size 时的兜底分片大小。
  static const int fallbackPartSize = 8 * 1024 * 1024;

  /// 是否应走本地分片：服务端支持 local 且没有配置 COS。
  ///
  /// 任何异常（旧后端 404、网关未放行）都返回 false —— 让调用方保持既有
  /// COS 路径，不要把一次探测失败升级成导入失败。
  static Future<bool> useLocal() async {
    try {
      final raw = await ApiClient.instance.get('/api/v1/files/upload/modes');
      if (raw is! Map) return false;
      final local = raw['local'] == true;
      final cos = raw['cos'] == true;
      return local && !cos;
    } catch (_) {
      return false;
    }
  }

  /// 上传一个 XFile（文件名取自选择器）。返回服务端的 file_id（已 archived）。
  static Future<String> uploadXFile(
    XFile file, {
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  }) async {
    final size = await file.length();
    return _upload(
      _XFileSource(file, size),
      onStage: onStage,
      isCancelled: isCancelled,
    );
  }

  /// 上传调用方已持有的字节（资源导入）。返回已 archived 的 file_id。
  static Future<String> uploadBytes(
    String name,
    Uint8List bytes, {
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  }) async {
    return _upload(
      _BytesSource(name, bytes),
      onStage: onStage,
      isCancelled: isCancelled,
    );
  }

  static Future<String> _upload(
    _PartSource src, {
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  }) async {
    _checkCancel(isCancelled);
    onStage?.call('申请分片上传', null);
    final init = await ApiClient.instance.post(
      '/api/v1/files/upload/local/init',
      body: <String, dynamic>{'name': src.name, 'size': src.size},
      timeout: const Duration(seconds: 60),
    );
    final initMap = (init as Map).cast<String, dynamic>();
    final fileId = (initMap['file_id'] ?? '').toString();
    final partSize = (initMap['part_size'] as num?)?.toInt() ?? 0;
    final partCount = (initMap['part_count'] as num?)?.toInt() ?? 0;
    if (fileId.isEmpty || partSize <= 0 || partCount <= 0) {
      throw ApiException(500, 'local/init 未返回 file_id/part_size/part_count');
    }

    try {
      for (var i = 1; i <= partCount; i++) {
        _checkCancel(isCancelled);
        final offset = (i - 1) * partSize;
        final length =
            (src.size - offset) < partSize ? (src.size - offset) : partSize;
        final label = '上传分片 $i/$partCount';
        onStage?.call(label, (i - 1) / partCount);
        final bytes = await src.read(offset, length);
        if (bytes.length != length) {
          throw ApiException(
              500, '读取分片 $i 失败：期望 $length 字节，实际 ${bytes.length}');
        }
        _checkCancel(isCancelled);
        await ApiClient.instance.putBytes(
          '/api/v1/files/upload/local/$fileId/part/$i',
          bytes,
          timeout: const Duration(minutes: 10),
        );
        onStage?.call(label, i / partCount);
      }

      onStage?.call('合并分片', null);
      await ApiClient.instance.post(
        '/api/v1/files/upload/local/complete',
        body: <String, dynamic>{'file_id': fileId},
        timeout: const Duration(minutes: 30),
      );
      return fileId;
    } catch (_) {
      // 任一片失败 / 取消：删掉服务端暂存分片，避免半成品占盘。
      await _abort(fileId);
      rethrow;
    }
  }

  static void _checkCancel(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const LongTaskCancelled();
  }

  static Future<void> _abort(String fileId) async {
    try {
      await ApiClient.instance.post(
        '/api/v1/files/upload/local/abort',
        body: <String, dynamic>{'file_id': fileId},
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      // best-effort：失败不影响向调用方抛出原始错误。
    }
  }
}

/// 分片读取抽象：XFile 走 Blob/文件区间读取，字节走零拷贝视图。
abstract class _PartSource {
  String get name;
  int get size;
  Future<Uint8List> read(int offset, int length);
}

class _XFileSource implements _PartSource {
  _XFileSource(this.file, this.size);

  final XFile file;

  @override
  final int size;

  @override
  String get name => file.name;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final builder = BytesBuilder(copy: false);
    // openRead 的 end 是排他的；Web 实现内部只把 Blob 的该区间转成字节，
    // 不会把整包读进 Dart 堆。
    await for (final chunk in file.openRead(offset, offset + length)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

class _BytesSource implements _PartSource {
  _BytesSource(this.name, this.bytes);

  @override
  final String name;

  final Uint8List bytes;

  @override
  int get size => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);
}

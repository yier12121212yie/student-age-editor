/// 自托管网页版模组导出（模块 A）：服务端把「本地盘文件 + COS 引用资源」流式
/// 拼成 zip 并登记为流转产物（archived），客户端经预签名直链带进度下载。
///
/// 与导入侧（[StagedModImport]）对称：base64 的 `POST /api/mods/export` 在带
/// 资源的大模组上会撑爆响应体与浏览器内存，这里改走直链。
library;

import 'dart:async';
import 'dart:typed_data';

import 'api_client.dart';
import 'blob_put.dart';
import 'long_task_progress.dart';

class StagedModExport {
  StagedModExport._();

  /// 返回 `(filename, bytes, url)`；[onStage] 的阶段与进度（0..1，null=不确定）。
  ///
  /// 字节能取回时 `bytes` 非空（带页内进度）；对象存储/CDN 未放行 CORS 时退回
  /// 浏览器原生下载（`bytes == null`，调用方用 [downloadUrlNative] 触发），
  /// 不再因跨域把整个导出链路判失败。
  static Future<({String filename, Uint8List? bytes, String url})> run(
    String? name, {
    void Function(String label, double? frac)? onStage,
    bool Function()? isCancelled,
  }) async {
    _checkCancel(isCancelled);
    onStage?.call('服务端打包', null);
    final raw = await ApiClient.instance.runLongTask(
      '/api/mods/export_staged',
      body: <String, dynamic>{if (name != null && name.isNotEmpty) 'name': name},
      timeout: const Duration(minutes: 30),
      maxWait: const Duration(minutes: 60),
    );
    final map = (raw as Map).cast<String, dynamic>();
    final fileId = (map['file_id'] ?? '').toString();
    final filename = (map['filename'] ?? 'mod.zip').toString();
    if (fileId.isEmpty) throw ApiException(500, 'export_staged 未返回 file_id');

    onStage?.call('等待分发就绪', null);
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    String url = '';
    bool local = false;
    while (true) {
      _checkCancel(isCancelled);
      final rec = await ApiClient.instance.get('/api/v1/files/$fileId/download');
      final m = rec is Map ? rec.cast<String, dynamic>() : const <String, dynamic>{};
      final status = (m['status'] ?? '').toString();
      final got = (m['url'] ?? '').toString();
      if (status == 'ready' || status == 'linked' || status == 's3_uploaded') {
        if (got.isNotEmpty) {
          url = got;
          local = m['local'] == true;
          break;
        }
      }
      if (status == 'failed') {
        throw ApiException(500, '服务端打包失败：${m['error'] ?? '未知原因'}');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw ApiException(504, '等待分发就绪超时');
      }
      final retry = ((m['retry_after'] as num?)?.toInt() ?? 3).clamp(1, 15);
      await Future<void>.delayed(Duration(seconds: retry));
    }

    _checkCancel(isCancelled);
    onStage?.call('下载中', 0);
    // 本地记录（未配置 COS 的部署）走 /api/v1/files/{id}/raw：必须带鉴权，
    // 浏览器原生下载拿不到 Bearer，所以这里只能取字节（仍带进度）。
    final source = _absolute(url);
    try {
      final bytes = local
          ? await getBytesFromUrlWithHeaders(
              source,
              headers: ApiClient.instance.authHeaders(),
              onProgress: (received, total) {
                if (total > 0) onStage?.call('下载中', received / total);
              },
            )
          : await getBytesFromUrl(source, onProgress: (received, total) {
              if (total > 0) onStage?.call('下载中', received / total);
            });
      return (filename: filename, bytes: bytes, url: source);
    } catch (_) {
      // 本地通道失败没有「无鉴权直链」可退回，如实上抛让用户重试。
      if (local) rethrow;
      // 对象存储/CDN 未放行 CORS（或直链读取失败）：退回浏览器原生下载。
      onStage?.call('浏览器下载', null);
      return (filename: filename, bytes: null, url: source);
    }
  }

  /// 本地下载接口返回站内相对路径（`/api/v1/files/{id}/raw`）。
  static String _absolute(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = ApiClient.instance.baseUrl;
    if (base.endsWith('/') && url.startsWith('/')) {
      return '${base.substring(0, base.length - 1)}$url';
    }
    return '$base$url';
  }

  /// 取消检查点：已取消则抛出 [LongTaskCancelled]（调用方静默吞掉）。
  static void _checkCancel(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const LongTaskCancelled();
  }
}

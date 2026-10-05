/// 直传 PUT / 直链下载（Web）：Blob 级透传，不进 Dart 堆。
///
/// - [putXFileToUrl]：XFile（file_selector/cross_file 的 web 实现）的 `path` 是
///   浏览器 object URL；先用一次本地 XHR（responseType=blob）把 File 重水化成
///   Blob，再 PUT 到预签名 URL。浏览器对 blob: 取回与 XHR.send(Blob) 都是内部
///   引用传递，849MB 的模组包也不会出现 Dart 端整包拷贝。
/// - [putBytesToUrl]：调用方已经持有字节（资源选择器读出的贴图/配乐/视频）时
///   直接用 JSUint8Array 发送，零额外拷贝。
/// - [getBytesFromUrl]：按预签名直链取回字节（带进度），用于导出下载。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:web/web.dart' as web;

Future<void> putXFileToUrl(
  XFile file,
  String url, {
  void Function(int sent, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  final blob = await _rehydrateBlob(file.path);
  await _putBody(blob, url, onProgress: onProgress, timeout: timeout);
}

Future<void> putBytesToUrl(
  Uint8List bytes,
  String url, {
  void Function(int sent, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) {
  onProgress?.call(0, bytes.length);
  return _putBody(bytes.toJS, url, onProgress: onProgress, timeout: timeout);
}

/// 预签名直链 GET（带进度）。对象存储需为站点来源放行 GET 的 CORS；未配置时
/// 浏览器报 0/网络错误，调用方可退回锚点直开下载。
Future<Uint8List> getBytesFromUrl(
  String url, {
  void Function(int received, int total)? onProgress,
  Duration timeout = const Duration(minutes: 60),
}) async {
  final xhr = web.XMLHttpRequest();
  xhr.open('GET', url);
  xhr.responseType = 'arraybuffer';
  xhr.timeout = timeout.inMilliseconds;
  final done = Completer<Uint8List>();
  if (onProgress != null) {
    xhr.addEventListener(
      'progress',
      ((web.ProgressEvent e) => onProgress(e.loaded.toInt(), e.total.toInt())).toJS,
    );
  }
  xhr.addEventListener(
    'loadend',
    ((web.Event _) {
      if (done.isCompleted) return;
      final status = xhr.status;
      if (status >= 200 && status < 300) {
        final resp = xhr.response;
        if (resp == null) {
          done.completeError(Exception('下载失败：响应为空'));
        } else {
          done.complete((resp as JSArrayBuffer).toDart.asUint8List());
        }
      } else {
        done.completeError(Exception('下载失败：HTTP $status'));
      }
    }).toJS,
  );
  xhr.addEventListener(
    'error',
    ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(Exception('下载失败：网络错误（预签名直链可能未放行 CORS）'));
      }
    }).toJS,
  );
  xhr.addEventListener(
    'timeout',
    ((web.Event _) {
      if (!done.isCompleted) done.completeError(Exception('下载超时'));
    }).toJS,
  );
  xhr.send();
  return done.future;
}

/// 浏览器原生下载：用隐藏 `<a>` 触发下载，不读字节、不经过 XHR，因此**无需**
/// 对象存储 / CDN 放行 CORS，也不会把整包读进 Dart 堆（大 zip 更稳）。
///
/// 跨域时浏览器可能忽略 `download` 建议名（以 URL 末段为准）——预签名下载
/// 直链末段即安全文件名（`safe_name`），因此落地名仍然正确。
Future<void> downloadUrlNative(String url, {String? filename}) {
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor
    ..href = url
    ..style.display = 'none';
  if (filename != null && filename.isNotEmpty) anchor.download = filename;
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  return Future<void>.value();
}

Future<void> _putBody(
  JSAny? body,
  String url, {
  void Function(int sent, int total)? onProgress,
  required Duration timeout,
}) async {
  final xhr = web.XMLHttpRequest();
  xhr.open('PUT', url);
  xhr.timeout = timeout.inMilliseconds;
  final done = Completer<void>();
  if (onProgress != null) {
    xhr.upload.addEventListener(
      'progress',
      ((web.ProgressEvent e) => onProgress(e.loaded.toInt(), e.total.toInt())).toJS,
    );
  }
  xhr.addEventListener(
    'loadend',
    ((web.Event _) {
      if (done.isCompleted) return;
      final status = xhr.status;
      if (status == 200 || status == 201 || status == 204) {
        done.complete();
      } else {
        final hint =
            status == 0 ? '（多为对象存储未配置 CORS：需允许来源站点 PUT 与 * 请求头）' : '';
        done.completeError(
          Exception('对象存储直传失败：HTTP $status$hint ${xhr.responseText}'),
        );
      }
    }).toJS,
  );
  xhr.addEventListener(
    'error',
    ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(Exception('对象存储直传失败：网络错误（预签名直链可能未放行 CORS）'));
      }
    }).toJS,
  );
  xhr.addEventListener(
    'timeout',
    ((web.Event _) {
      if (!done.isCompleted) done.completeError(Exception('对象直传超时'));
    }).toJS,
  );
  xhr.send(body);
  await done.future;
}

/// 把 object URL 指向的文件在浏览器内部转成 Blob（不产生 Dart 字节拷贝）。
Future<web.Blob> _rehydrateBlob(String objectUrl) async {
  final xhr = web.XMLHttpRequest();
  xhr.open('GET', objectUrl);
  xhr.responseType = 'blob';
  final done = Completer<web.Blob>();
  xhr.addEventListener(
    'loadend',
    ((web.Event _) {
      if (done.isCompleted) return;
      final resp = xhr.response;
      if (resp == null) {
        done.completeError(Exception('无法读取所选文件（浏览器 Blob 不可用）'));
      } else {
        done.complete(resp as web.Blob);
      }
    }).toJS,
  );
  xhr.addEventListener(
    'error',
    ((web.Event _) {
      if (!done.isCompleted) done.completeError(Exception('无法读取所选文件'));
    }).toJS,
  );
  xhr.send();
  return done.future;
}

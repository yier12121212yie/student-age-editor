// 错误文案人性化（C3）。
//
// 背景：`ApiException.toString()` 返回 `API 409: …`，全项目约 68 处
// `失败：$e` 把这类技术串原样丢给用户。本文件提供单一入口 [humanizeError]，
// 把常见异常映射成「能读懂、能行动」的一句话，同时把技术细节保留在
// [HumanizedError.detail]（折叠进「复制详情」，排查时不丢失）。
//
// 设计：
// - [humanizeError] 纯函数、表驱动，便于单测覆盖每种异常；
// - 连接级失败复用 [isBackendConnectionError]（与断线自愈同一判定口径）；
// - 超时文案可带「已等待 N 秒」（调用方传入 [timeout]；拿不到就省略）。
library;

import 'dart:async';

import 'api_client.dart';
import 'backend_retry.dart';

/// 人性化后的错误：用户可见的一句话 + 可选技术细节。
class HumanizedError {
  const HumanizedError(this.message, {this.detail, this.retryable = false});

  /// 用户可见的一句话（不含堆栈/状态码等噪声）。
  final String message;

  /// 技术细节（异常原文），折叠进「复制详情」；无则 null。
  final String? detail;

  /// 是否建议提供「重试」按钮（连接级失败 / 超时等可自愈的错误）。
  final bool retryable;

  @override
  String toString() => message;
}

/// 把任意异常映射为 [HumanizedError]。
///
/// [timeout] 为可选：当异常是超时且调用方知道本次等待上限时传入，
/// 文案会显示「已等待 N 秒」。
HumanizedError humanizeError(Object? e, {Duration? timeout}) {
  if (e == null) {
    return const HumanizedError('操作失败，请稍后重试');
  }
  final raw = e.toString();

  // 1) 后端业务错误（HTTP 4xx/5xx）。
  if (e is ApiException) {
    final code = e.statusCode;
    if (code == 409) {
      return HumanizedError('文件已被其他位置修改，请刷新后重试',
          detail: raw);
    }
    if (code == 401) {
      return HumanizedError('登录已过期，请重新登录', detail: raw);
    }
    if (code == 403) {
      return HumanizedError('没有权限执行该操作', detail: raw);
    }
    if (code == 404) {
      return HumanizedError('请求的内容不存在，可能已被删除', detail: raw);
    }
    if (code == 400 || code == 422) {
      return HumanizedError(
          e.message.isEmpty ? '请求参数有误，请检查后重试' : e.message,
          detail: raw);
    }
    if (code >= 500) {
      return HumanizedError('后端服务出错，请稍后重试',
          detail: raw, retryable: true);
    }
    return HumanizedError('请求失败（HTTP $code）', detail: raw);
  }

  // 2) 超时。
  if (e is TimeoutException) {
    final secs = timeout?.inSeconds;
    return HumanizedError(
      (secs != null && secs > 0) ? '后端响应超时（已等待 $secs 秒）' : '后端响应超时，请重试',
      detail: raw,
      retryable: true,
    );
  }

  // 3) 连接级失败（后端未启动 / 中途被回收）。
  if (isBackendConnectionError(e)) {
    return HumanizedError('无法连接本地服务，请确认后端已启动',
        detail: raw, retryable: true);
  }

  // 4) 其余常见异常。
  if (e is FormatException) {
    return HumanizedError('数据格式错误，无法解析', detail: raw);
  }

  return HumanizedError('操作失败，请稍后重试', detail: raw);
}

/// 便捷：只取用户可见文案。
String humanizeErrorMessage(Object? e, {Duration? timeout}) =>
    humanizeError(e, timeout: timeout).message;

/// 便捷：只取技术细节。
String? humanizeErrorDetail(Object? e) => humanizeError(e).detail;

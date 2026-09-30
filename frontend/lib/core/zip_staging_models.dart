/// zip 安装/导入的载荷模型（网页版 M0.5，两份平台实现共用）。
library;

/// 一次 zip 安装/导入的提交方式：端点 + 请求体 + 清理回调。
///
/// - 桌面/Android：[StagedZip.endpoint] 为 `*_path` 端点，body 携带本机
///   临时目录里的 zip 路径（绕过 base64 与体积上限，维持既有行为），
///   [StagedZip.cleanup] 删除该临时目录；
/// - Web：端点为 `*_upload`，body 携带 `{filename, data_base64}`，
///   [StagedZip.cleanup] 为空操作。
class StagedZip {
  const StagedZip(this.endpoint, this.body, this.cleanup);

  final String endpoint;
  final Map<String, dynamic> body;
  final Future<void> Function() cleanup;
}

/// [stageZipForInstall] 的端点/前缀参数（调用方各页不一样）。
class ZipStageOptions {
  const ZipStageOptions({
    required this.pathEndpoint,
    required this.uploadEndpoint,
    required this.tempPrefix,
  });

  /// 桌面路径提交端点（/api/plugins/install_path 等）。
  final String pathEndpoint;

  /// Web base64 上传端点（/api/plugins/install_upload 等）。
  final String uploadEndpoint;

  /// 临时目录前缀（io 实现使用）。
  final String tempPrefix;
}

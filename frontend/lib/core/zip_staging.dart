/// zip 安装/导入暂存条件导出（网页版 M0.5）：
/// - 有 dart:io 的平台：临时目录拷贝 + `*_path` 端点（既有行为零改动）；
/// - Web：读字节转 base64 + `*_upload` 端点（后端 `upload_staging.h` 同管线）。
///
/// 两份实现暴露同一公共 API（[stageZipForInstall] / [StagedZip] /
/// [ZipStageOptions]）。
library;

export 'zip_staging_models.dart';
export 'zip_staging_stub.dart' if (dart.library.io) 'zip_staging_io.dart';

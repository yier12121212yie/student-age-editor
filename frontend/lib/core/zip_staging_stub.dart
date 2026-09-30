/// zip 暂存（Web）：XFile 没有本机路径，读字节转 base64 走 `*_upload`
/// 端点（后端落临时文件后与路径端点同管线；解码上限 100MB）。
library;

import 'dart:convert';

import 'package:file_selector/file_selector.dart';

import 'zip_staging_models.dart';

Future<StagedZip> stageZipForInstall(XFile file, ZipStageOptions options) async {
  final bytes = await file.readAsBytes();
  return StagedZip(
    options.uploadEndpoint,
    {'filename': file.name, 'data_base64': base64Encode(bytes)},
    () async {},
  );
}

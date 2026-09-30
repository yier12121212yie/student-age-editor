/// zip 暂存（io 平台）：拷贝到应用可写临时目录后按路径提交——绕过 base64
/// 与体积上限，行为与网页版引入前的桌面流程逐句一致。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'zip_staging_models.dart';

Future<StagedZip> stageZipForInstall(XFile file, ZipStageOptions options) async {
  final tmpDir = await Directory.systemTemp.createTemp(options.tempPrefix);
  final dest = '${tmpDir.path}${Platform.pathSeparator}${file.name}';
  await File(file.path).copy(dest);
  return StagedZip(options.pathEndpoint, {'path': dest, 'filename': file.name},
      () async {
    // 后端已读完 zip，临时目录不再需要（失败也一并清理）。
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });
}

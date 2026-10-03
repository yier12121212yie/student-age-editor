/// 「从本地电脑导入」共享工具（M3）。
///
/// 把系统文件选择器 + `POST /api/mod/import_files` 的链路收在一处，供三类
/// 入口复用：
/// - [ImageAssetPickerDialog] 的「导入本地图片…」（`kind: 'image'`）；
/// - 资源面板顶栏「导入本地…」（贴图 → image；音频 → audio + 自动登记）；
/// - 音频字段的「导入」按钮（由 schema 侧接线，见下方调用示例）。
///
/// 后端契约（已锁定）：
/// ```
/// POST /api/mod/import_files
///   {"files":[{"name":"a.png","data":"<base64>","dir":"Textures"?}],
///    "register_audio": false}
///   -> 200 {"saved":[{"name","path","size","audio_id","audio_error"}],
///            "errors":[{"name","error"}]}
///   -> 400 {"error":"未选择模组"}
/// ```
/// 目录推断、文件名净化、重名后缀（`name_1.ext`）与 AudioCfg 登记都在后端做，
/// 前端只负责「选文件 → base64 → 提交 → 展示结果」，因此**必须原样透传**
/// 后端返回的 `path`（重名时它是 `Textures/name_1.png` 而不是原名）。
///
/// 调用示例（音频字段，主会话接线用）：
/// ```dart
/// final saved = await importLocalAssets(
///   context, kind: 'audio', registerAudio: true);
/// if (saved.isNotEmpty) {
///   // saved.first['audio_id'] -> 直接写回字段值；path 形如 Audios/x.mp3
///   final id = saved.first['audio_id'] as int?;
///   if (id != null) controller.text = '$id';
/// }
/// ```
library;

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/api_client.dart';
import '../../core/file_upload_client.dart';
import '../../core/mod_resource_ref.dart';
import 'image_asset_picker.dart' show TexBytesCache;

// ---------------- 扩展名白名单 ----------------

/// 图片白名单，与后端目录推断口径一致（png/jpg/jpeg/webp/bmp → Textures）。
/// 注意不含 gif：AA 索引按静态图处理，gif 走导入容易拿到空缩略图。
const List<String> kLocalImageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'bmp'];

/// 音频白名单，与后端目录推断口径一致（wav/mp3/ogg/m4a → Audios）。
const List<String> kLocalAudioExtensions = ['wav', 'mp3', 'ogg', 'm4a'];

/// 视频白名单，与后端目录推断口径一致（mp4/webm/mov/mkv → Videos）。
const List<String> kLocalVideoExtensions = ['mp4', 'webm', 'mov', 'mkv'];

// ---------------- 可注入的文件读取 ----------------

/// 已选到手的本地文件：`name` 只含文件名（不含路径），`bytes` 是原始字节。
typedef PickedLocalFile = ({String name, Uint8List bytes});

/// 文件选取实现。默认走 `file_selector`，测试里注入桩
/// （`file_selector` 在 flutter test 环境没有平台通道实现）。
typedef LocalFilePicker = Future<List<PickedLocalFile>> Function(String kind);

/// 全局测试注入点：非空时 [importLocalAssets] 用它替代系统选择器。
/// 适合「按钮在深层 widget 里、没法透传 picker」的集成测试。
@visibleForTesting
LocalFilePicker? debugLocalFilePicker;

/// 用系统多选对话框挑文件并读成字节。
///
/// 走 `file_selector` 的 `openFiles`（本仓库既有做法见 `ai_chat_controller`
/// 与 `pack_manager_page` 的 `XTypeGroup(label:, extensions:)`）：桌面/安卓
/// 用扩展名白名单过滤，web 用 `webWildCards`。
Future<List<PickedLocalFile>> pickLocalFilesByKind(String kind) async {
  final audio = kind == 'audio';
  final video = kind == 'video';
  final group = XTypeGroup(
    label: video ? '视频文件' : (audio ? '音频文件' : '图片文件'),
    extensions: video
        ? kLocalVideoExtensions
        : (audio ? kLocalAudioExtensions : kLocalImageExtensions),
    webWildCards: video
        ? const ['video/*']
        : (audio ? const ['audio/*'] : const ['image/*']),
  );
  final picked = await openFiles(acceptedTypeGroups: [group]);
  final out = <PickedLocalFile>[];
  for (final f in picked) {
    // XFile.name 已是 basename；某些平台仍可能带回斜杠路径，兜底裁一次。
    final name = f.name.split(RegExp(r'[\\/]')).last;
    if (name.isEmpty) continue;
    out.add((name: name, bytes: await f.readAsBytes()));
  }
  return out;
}

// ---------------- 纯网络层（可直接在测试里断言请求形状） ----------------

/// `/api/mod/import_files` 的解析结果。
class ImportFilesResult {
  const ImportFilesResult({required this.saved, required this.errors});

  /// 成功落盘项：`{name, path, size, audio_id, audio_error}`（后端原文）。
  final List<Map<String, dynamic>> saved;

  /// 失败项：`{name, error}`。
  final List<Map<String, dynamic>> errors;

  bool get isEmpty => saved.isEmpty && errors.isEmpty;
}

/// 把 [files] 打包成契约请求体并 POST，返回结构化结果。
///
/// 不碰 UI、不碰缓存——给单测与任意自定义流程（如以后支持拖拽导入）复用。
/// 网络/后端错误以 [ApiException] 抛出，由调用方决定怎么提示。
Future<ImportFilesResult> importFiles(
  List<PickedLocalFile> files, {
  bool registerAudio = false,

  /// 显式目标目录（如 `Textures`）。留 null 让后端按扩展名推断。
  String? dir,
}) async {
  final body = <String, dynamic>{
    'files': [
      for (final f in files)
        <String, dynamic>{
          'name': f.name,
          'data': base64Encode(f.bytes),
          if (dir != null && dir.isNotEmpty) 'dir': dir,
        },
    ],
    'register_audio': registerAudio,
  };
  // 一批原图可能几十 MB：用比默认 120s 更宽的超时，避免大图导入卡在超时上。
  final r = await ApiClient.instance.post(
    '/api/mod/import_files',
    body: body,
    timeout: const Duration(minutes: 5),
  );
  return ImportFilesResult(
    saved: _mapList(r, 'saved'),
    errors: _mapList(r, 'errors'),
  );
}

List<Map<String, dynamic>> _mapList(dynamic payload, String field) {
  if (payload is! Map) return const [];
  final raw = payload[field];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

// ---------------- UI 层 ----------------

/// 从本地电脑导入资源，返回后端 `saved` 列表（取消/失败返回空表）。
///
/// - [kind]：`'image'`（图片 → Textures）或 `'audio'`（音频 → Audios）；
///   只影响选择器的扩展名白名单与提示文案，目录仍由后端推断。
/// - [registerAudio]：音频导入时让后端顺带登记 AudioCfg 并回 `audio_id`。
/// - [picker]：注入文件读取（测试用）。缺省为系统选择器，其次
///   [debugLocalFilePicker]。
///
/// 反馈一律用 fluent [fluent.displayInfoBar]（仓库既有做法）：空选中、后端
/// 报错、`errors` 数组逐条、以及音频登记失败（`audio_error`）都会成条显示。
/// 图片导入成功后失效 [TexBytesCache]——否则同名 key 仍显示旧字节。
Future<List<Map<String, dynamic>>> importLocalAssets(
  BuildContext context, {
  required String kind,
  bool registerAudio = false,
  LocalFilePicker? picker,
}) async {
  final isImage = kind == 'image';
  final pick = picker ?? debugLocalFilePicker ?? pickLocalFilesByKind;

  List<PickedLocalFile> picked;
  try {
    picked = await pick(kind);
  } catch (e) {
    if (context.mounted) {
      _bar(context,
          title: '打开文件选择器失败',
          lines: [_detailOf(e)],
          severity: fluent.InfoBarSeverity.error);
    }
    return const [];
  }
  if (picked.isEmpty) {
    // 用户按「取消」——不算错误，用 warning 提示一下即可。
    if (context.mounted) {
      _bar(context,
          title: '未选择文件',
          lines: const ['已取消导入，未改动任何资源。'],
          severity: fluent.InfoBarSeverity.warning);
    }
    return const [];
  }

  // web 上超过阈值的单文件改走「留 COS 只存引用」（不落盘）：贴图/配乐/视频
  // 动辄几百 MB，base64 通道必被网关请求体上限拒杀。小文件仍走 import_files
  // 落盘，游戏/预览照常读盘；导出时两类来源由服务端合并拼包。
  final refs = <Map<String, dynamic>>[];
  final refProblems = <String>[];
  final toUpload = <PickedLocalFile>[];
  for (final f in picked) {
    if (kIsWeb && f.bytes.length > StagedResourceRef.refThresholdBytes) {
      try {
        refs.add(await StagedResourceRef.uploadAsRef(
          f.name,
          f.bytes,
          registerAudio: registerAudio && kind == 'audio',
        ));
      } catch (e) {
        refProblems.add('${f.name}：${_detailOf(e)}');
      }
    } else {
      toUpload.add(f);
    }
  }

  ImportFilesResult result;
  if (toUpload.isEmpty) {
    result = const ImportFilesResult(saved: [], errors: []);
  } else {
    try {
      result = await importFiles(toUpload, registerAudio: registerAudio);
    } catch (e) {
      if (context.mounted) {
        _bar(context,
            title: '导入失败',
            lines: [_detailOf(e)],
            severity: fluent.InfoBarSeverity.error);
      }
      return const [];
    }
  }

  final savedAll = <Map<String, dynamic>>[...result.saved, ...refs];

  // 逐条收集需要露出的问题：整体失败项 + 音频登记失败项 + 引用上传失败项。
  final problems = <String>[
    ...refProblems,
    for (final e in result.errors)
      '${e['name'] ?? '?'}：${e['error'] ?? '未知错误'}',
    for (final s in savedAll)
      if (s['audio_error'] != null)
        '${s['name'] ?? '?'}：已存盘但音频登记失败（${s['audio_error']}）',
  ];

  if (savedAll.isEmpty) {
    if (context.mounted) {
      _bar(context,
          title: '导入失败',
          lines: problems.isEmpty ? ['后端未返回任何成功项。'] : problems,
          severity: fluent.InfoBarSeverity.error);
    }
    return const [];
  }

  // 图片字节有进程级缓存：不清的话新导入的同名图仍然显示旧内容。
  if (isImage) TexBytesCache.clear();

  if (context.mounted) {
    _bar(
      context,
      title: '已导入 ${savedAll.length} 个文件'
          '${problems.isNotEmpty ? '（${problems.length} 项有问题）' : ''}',
      lines: [
        for (final s in savedAll)
          '${s['path']?.toString() ?? ''}${s['cos'] == true ? '（存于对象存储）' : ''}',
        ...problems,
      ].where((l) => l.isNotEmpty).toList(),
      severity: problems.isEmpty
          ? fluent.InfoBarSeverity.success
          : fluent.InfoBarSeverity.warning,
    );
  }
  return savedAll;
}

/// 后端信封里的 `detail` 常带可执行修复指引，优先展示它（与资源面板一致）。
String _detailOf(Object e) {
  if (e is ApiException) return e.message;
  return e.toString();
}

const int _maxBarLines = 6;

void _bar(
  BuildContext context, {
  required String title,
  List<String> lines = const [],
  fluent.InfoBarSeverity severity = fluent.InfoBarSeverity.info,
}) {
  if (!context.mounted) return;
  final shown = lines.length > _maxBarLines
      ? [...lines.take(_maxBarLines - 1), '…… 另有 ${lines.length - _maxBarLines + 1} 条']
      : lines;
  fluent.displayInfoBar(
    context,
    // 错误细节要来得及读完：比 fluent 默认 3s 宽一些。
    duration: const Duration(seconds: 6),
    builder: (ctx, close) => fluent.InfoBar(
      severity: severity,
      title: Text(title, style: const TextStyle(fontSize: 12.5)),
      content: shown.isEmpty
          ? null
          : Text(shown.join('\n'),
              style: const TextStyle(fontSize: 11.5, height: 1.45)),
      action: fluent.Button(onPressed: close, child: const Text('关闭')),
    ),
  );
}

// ---------------- S3 直传支持（可选） ----------------

/// 从本地导入资源（S3 直传优化版），返回后端 `saved` 列表。
/// 
/// - 使用 [FileUploadClient] 智能选择上传方式：
///   - > threshold: S3 直传（PUT 到预签名 URL）
///   - <= threshold: 服务器上传（base64 POST）
/// - [storyId] 可选，用于将文件归类到特定故事
Future<List<Map<String, dynamic>>> importLocalAssetsWithS3Support(
  BuildContext context, {
  required String kind,
  bool registerAudio = false,
  LocalFilePicker? picker,
  String? storyId,
}) async {
  final isImage = kind == 'image';
  final pick = picker ?? debugLocalFilePicker ?? pickLocalFilesByKind;

  List<PickedLocalFile> picked;
  try {
    picked = await pick(kind);
  } catch (e) {
    if (context.mounted) {
      _bar(context,
          title: '打开文件选择器失败',
          lines: [_detailOf(e)],
          severity: fluent.InfoBarSeverity.error);
    }
    return const [];
  }
  if (picked.isEmpty) {
    if (context.mounted) {
      _bar(context,
          title: '未选择文件',
          lines: const ['已取消导入，未改动任何资源。'],
          severity: fluent.InfoBarSeverity.warning);
    }
    return const [];
  }

  // 使用 FileUploadClient 进行智能上传
  final uploader = FileUploadClient(ApiClient.instance);
  final savedResults = <Map<String, dynamic>>[];
  final errors = <Map<String, dynamic>>[];

  for (final file in picked) {
    try {
      final uploadPath = await uploader.uploadFile(
        name: file.name,
        data: file.bytes,
        kind: kind,
        storyId: storyId,
        onProgress: null, // 可在 UI 层实现进度回调
      );

      if (uploadPath != null) {
        // 根据模式构建结果
        savedResults.add({
          'name': file.name,
          'path': uploadPath,
          'size': file.bytes.length,
          if (kind == 'audio') ...{
            'audio_id': null, // TODO: 需要时调用 registerAudio 逻辑
            'audio_error': null,
          },
        });
      } else {
        throw Exception('上传成功但未返回路径');
      }
    } catch (e) {
      errors.add({
        'name': file.name,
        'error': _detailOf(e),
      });
    }
  }

  // 清理图片缓存
  if (isImage && savedResults.isNotEmpty) {
    TexBytesCache.clear();
  }

  // 收集问题信息
  final problems = <String>[
    for (final e in errors) '${e['name'] ?? '?'}：${e['error']}',
  ];

  if (savedResults.isEmpty && errors.isEmpty) {
    if (context.mounted) {
      _bar(context,
          title: '导入失败',
          lines: ['无有效操作。'],
          severity: fluent.InfoBarSeverity.error);
    }
    return const [];
  }

  if (context.mounted) {
    _bar(
      context,
      title: '已导入 ${savedResults.length} 个文件${problems.isNotEmpty ? '（${errors.length} 项有问题）' : ''}',
      lines: [
        for (final s in savedResults) s['path']?.toString() ?? '',
        ...problems,
      ].where((l) => l.isNotEmpty).toList(),
      severity: problems.isEmpty
          ? fluent.InfoBarSeverity.success
          : fluent.InfoBarSeverity.warning,
    );
  }

  return savedResults;
}

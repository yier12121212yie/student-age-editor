/// 浏览器标签页标题的拼装规则（纯函数，便于测试）。
///
/// 目标：同时开多个标签页（不同模组/文档）时能一眼分清。
/// 形如 `人物资料 · 我的模组 — 学生时代模组编辑器`，没选模组时退回基础标题。
library;

const String kBaseAppTitle = '学生时代模组编辑器';

/// [modName] 后端选中的模组目录名；[modDisplayName] 展示名（manifest 标题优先，
/// 通常会回落到目录名）；[docTitle] 当前打开的文档标题（可为空）。
String composeAppTitle({
  required String modName,
  required String modDisplayName,
  String? docTitle,
}) {
  final doc = (docTitle ?? '').trim();
  final rawMod = modName.trim();
  final display = modDisplayName.trim();
  // 展示名为空时回落到目录名：宁可显示 `my_mod`，也不要只剩「— 编辑器」。
  final mod = rawMod.isEmpty ? '' : (display.isEmpty ? rawMod : display);
  final parts = <String>[
    if (doc.isNotEmpty) doc,
    if (mod.isNotEmpty && mod != doc) mod,
  ];
  if (parts.isEmpty) return kBaseAppTitle;
  return '${parts.join(' · ')} — $kBaseAppTitle';
}

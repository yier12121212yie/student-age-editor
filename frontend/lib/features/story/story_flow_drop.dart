/// M6「剧情图深度融合」拖放协议层：画布唯一 `DragTarget<FlowDropRef>` 的
/// 联合载荷模型。
///
/// 画布此前只认 [FlowAssetRef]（媒体资产 → 命中节点写字段），空白落点
/// 一律丢弃。本文件把三类拖源收进一个 sealed 联合：
/// - [FlowAssetDropRef] 媒体资产：命中节点写字段（旧语义不变）；
///   空白落点新建种子对白节点再走同一匹配链路写字段；
/// - [FlowTemplateDropRef] 场景模板（工具栏「模板拖源」面板）：
///   以落点世界坐标为原点实例化整组节点；
/// - [FlowEffectDropRef] 效果行（工具栏「效果拖源」面板的
///   /api/effect_suggest 候选）：命中节点追加效果行；空白落点新建
///   带该效果的对白节点。
///
/// 纯模型层：不依赖画布与工作区，[FlowEffectDropRef.parseRow] 可离线单测。
library;

import 'story_flow_templates.dart';

/// 拖拽中的媒体资产引用（kind: tex | aud）。
class FlowAssetRef {
  const FlowAssetRef({required this.kind, required this.key});
  final String kind;
  final String key;
}

/// 画布拖放的联合载荷：命中节点与空白落点共用同一 DragTarget，
/// 按 variant 分派（见 workspace 的统一接受逻辑）。
sealed class FlowDropRef {
  const FlowDropRef();
}

/// 媒体资产拖源（媒体面板条目）。
class FlowAssetDropRef extends FlowDropRef {
  const FlowAssetDropRef(this.asset);
  final FlowAssetRef asset;
}

/// 场景模板拖源（模板面板卡片 / 画廊卡片）。
class FlowTemplateDropRef extends FlowDropRef {
  const FlowTemplateDropRef(this.template);
  final FlowSceneTemplate template;
}

/// 效果行拖源：[code] 为后端返回的候选码文本（如 `[1, 1, 3, 5]`），
/// [desc] 为人读描述（拖影与 toast 展示用）。
class FlowEffectDropRef extends FlowDropRef {
  const FlowEffectDropRef({required this.code, required this.desc});
  final String code;
  final String desc;

  /// 把效果码文本解析成效果字段（2D 数组）里的单行。
  ///
  /// 后端候选的 code 形如 `[1, 1, @ATTR@, 0]` / `[9, 9]` / `4015`：
  /// 去括号按逗号切分，数值槽转 num；未填槽（@ATTR@ 等占位）保留原文本，
  /// 由用户在展开节点里补全（与模板库「槽留 0 待补」同一哲学）。解析不出
  /// 任何元素返回 null，调用方应 toast 拒写而不是塞进空行。
  List<dynamic>? parseRow() {
    var t = code.trim();
    if (t.startsWith('[')) t = t.substring(1);
    if (t.endsWith(']')) t = t.substring(0, t.length - 1);
    final parts = t
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    return [for (final p in parts) num.tryParse(p) ?? p];
  }
}

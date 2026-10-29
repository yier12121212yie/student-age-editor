// D9 守护：12 个工作台 × 简易模式（noCodeMode）覆盖核对。
//
// spike 结论（固化为断言，防回归）：
//   1) 12 个工作台源码里**没有任何手写效果 / 条件 / 指令码的文本通道**——
//      既不构造 `EffectHintField`（效果补全框），也不构造 `SuggestionTextField`
//      （代码 / ID 补全框）；
//   2) 带码字段的工作台一律经 `showBlockLibrary`（积木库）进入；配合
//      `ValueCodec.decode` 现在能正确还原括号码（含 998 嵌套），写回不再碎串；
//   3) 审计 #9（`social` / `messages`）：`effect` / `condition` 只做「条数」展示与
//      默认空数组，**没有编辑通道** —— 不是缺陷。
//
// 已知例外（按设计，不在断言内）：`json` 工作台以「整行 JSON」文本框编辑记录，
// 码字段因此以 JSON 文本呈现；它是显式的「原始」工具，不是码字段专用的文本入口。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 12 个工作台（与 `ux_roadmap_r2.md` A3/B3 的表一致）→ 源码路径（相对仓库）。
const _workbenches = <String, String>{
  '社交': 'lib/features/social/social_workbench.dart',
  '目标': 'lib/features/goals/goals_workbench.dart',
  '消息': 'lib/features/messages/messages_workbench.dart',
  '闲聊': 'lib/features/chats/idle_chat_workbench.dart',
  '事件': 'lib/features/events/event_workbench.dart',
  '小游戏': 'lib/features/minigames/minigames_workbench.dart',
  '外部对话': 'lib/features/external/external_dialogues_workbench.dart',
  '仓库': 'lib/features/warehouse/warehouse_workbench.dart',
  '人物': 'lib/features/person/person_workbench.dart',
  '空间': 'lib/features/space/space_workbench.dart',
  'JSON': 'lib/features/json/json_workbench.dart',
  '积木库': 'lib/features/blocks/blocks_workbench.dart',
};

/// 带码字段编辑入口的工作台（其余 7 个不编辑码字段）：走积木库。
const _codeBearingWorkbenches = <String>['闲聊', '事件', '小游戏', '外部对话', '仓库'];

String _read(String rel) {
  for (final base in ['', '../', 'frontend/']) {
    final f = File('$base$rel');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $rel（cwd=${Directory.current.path}）');
}

void main() {
  group('D9 工作台 × 简易模式覆盖核对', () {
    test('12 个工作台都不构造手写码文本通道（EffectHintField / SuggestionTextField）', () {
      for (final e in _workbenches.entries) {
        final src = _read(e.value);
        expect(src.contains('EffectHintField('), isFalse,
            reason: '${e.key}（${e.value}）仍构造效果补全框');
        expect(src.contains('SuggestionTextField('), isFalse,
            reason: '${e.key}（${e.value}）仍构造代码/ID 补全框');
      }
    });

    test('带码字段的工作台一律经 showBlockLibrary 进入', () {
      for (final name in _codeBearingWorkbenches) {
        final src = _read(_workbenches[name]!);
        expect(src.contains('showBlockLibrary('), isTrue,
            reason: '$name 编辑码字段却未走积木库');
      }
    });

    test('审计 #9：social / messages 的 effect / condition 只展示不编辑', () {
      for (final name in ['社交', '消息']) {
        final src = _read(_workbenches[name]!);
        // 只计数展示（_lenOf / length），不接编辑回调。
        expect(src.contains('showBlockLibrary('), isFalse,
            reason: '$name 不应有码编辑入口');
        expect(src.contains('EffectBlockEditor('), isFalse,
            reason: '$name 不应内嵌积木编辑器');
      }
    });
  });
}

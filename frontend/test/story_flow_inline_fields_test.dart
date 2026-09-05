// 内联参数编辑区回归：字段清单必须等于 kFlowInline* 常量（新增字段要显式
// 决定进不进内联，不能靠 schema 顺序自动漏进来），展开态卡片足迹必须仍是
// kFlowTalkExpandedH / kFlowOptionExpandedH —— 那两个常量被命中矩形、展开箭头、
// 端口锚点和连线 painter 五处共用，按字段数动态算高会让连线集体错位。
// 还有一条安全线：效果/条件类字段一律走带校验的补全框，绝不允许裸文本框，
// 否则全角逗号能绕过校验直接进存档。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/suggestion_text_field.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';

const _evt = '1000001';
const _talk = '1000001000';
const _opt = '1000001010';

/// 与后端 game_schema.py 的 TalkCfg / OptionCfg 字段全集同形。
const _schema = <String, dynamic>{
  'TalkCfg': {
    'audio': 'Number',
    'bg': 'Number',
    'check': '2D Array',
    'content': 'String',
    'effect': '2D Array',
    'effect2': '2D Array',
    'highlights': '1D Array',
    'id': 'Number',
    'maxoptions': 'Number',
    'miniGame': '1D Array',
    'nextTalk': '1D Array',
    'nextTalk2': '1D Array',
    'option': '1D Array',
    'replace': '1D Array',
    'roleIds': '1D Array',
    'roleName': 'String',
    'roles': '2D Array',
    'screenEffect': '1D Array',
    'showTxt': 'String',
    'time': 'Number',
    'vocals': '1D Array',
  },
  'OptionCfg': {
    'check': '2D Array',
    'content': 'String',
    'effect': '2D Array',
    'effect2': '2D Array',
    'id': 'Number',
    'miniGame': '1D Array',
    'nextEvtId': 'Number',
    'precondition': '2D Array',
    'pressure': '2D Array',
    'showTxt': 'String',
    'stateCond': '2D Array',
    'tag': 'String',
    'talkId': '1D Array',
    'talkId2': '1D Array',
  },
};

void main() {
  late AppState state;

  Map<String, dynamic> talks() => {
    _talk: {
      'id': int.parse(_talk),
      'roleName': '旁白',
      'content': '甲',
      'bg': 12,
      'check': [
        [1, 2],
      ],
      'nextTalk': [_opt],
    },
  };

  Map<String, dynamic> opts() => {
    _opt: {
      'id': int.parse(_opt),
      'content': '去教室',
      'talkId': <int>[],
    },
  };

  setUp(() {
    state = AppState()
      ..modName = 'Inline'
      ..modRoot = r'C:\mods\inline'
      ..gameSchema = _schema
      ..keyMaps = {
        'TalkCfg': {'screenEffect': '屏幕画面特效', 'check': '前提判定'},
        'OptionCfg': {'content': '选项文本'},
      }
      ..gameDicts = {
        'bgs': {'12': '教室'},
        'audios': {'30': '上课铃'},
        'roles': {'100': '小明'},
      };
    ApiClient.instance.client = MockClient((request) async {
      final path = request.url.path;
      var data = <String, dynamic>{};
      if (path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        if (name == 'EvtCfg') {
          data = {
            _evt: {
              'id': int.parse(_evt),
              'title': '内联事件',
              'talkId': [_talk],
            },
          };
        }
        if (name == 'TalkCfg') data = talks();
        if (name == 'OptionCfg') data = opts();
        return http.Response(
          jsonEncode({
            'cfg': name,
            'data': data,
            'keys': data.keys.toList(),
            'exists': true,
            'mtime_ns': 1,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"ok": true, "flow_cards": [], "items": []}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      fluent.FluentApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: StoryFlowWorkspace(
              state: state,
              onPreview: (_) {},
              onOpenPlugins: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<StoryFlowGraph> expand(WidgetTester tester, String id) async {
    final w = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
    w.onToggleExpand(id);
    await tester.pumpAndSettle();
    return tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
  }

  /// 展开态卡片足迹：`_FlowNodeCard` 返回 `Positioned(height: _h)`。
  /// 命中这个常量即证明高度仍钉死在 kFlowTalkExpandedH，没改成按字段数算。
  Finder expandedCardFootprint() => find.descendant(
    of: find.byType(StoryFlowGraph),
    matching: find.byWidgetPredicate(
      (w) => w is Positioned && w.height == kFlowTalkExpandedH,
    ),
  );

  group('字段清单契约', () {
    test('flowInlineFields 就是 kFlowInline* 常量本身', () {
      expect(flowInlineFields(false), same(kFlowInlineTalk));
      expect(flowInlineFields(true), same(kFlowInlineOption));
    });

    test('内联清单里的字段都能在 schema 里找到（防手滑写错 key）', () {
      final talkFields = (_schema['TalkCfg'] as Map).cast<String, String>();
      final optFields = (_schema['OptionCfg'] as Map).cast<String, String>();
      for (final k in kFlowInlineTalk) {
        expect(talkFields.containsKey(k), isTrue, reason: 'TalkCfg 无此字段：$k');
      }
      for (final k in kFlowInlineOption) {
        expect(optFields.containsKey(k), isTrue, reason: 'OptionCfg 无此字段：$k');
      }
    });

    test('必填项（仅 content）要么在内联、至少在 Inspector 常用段', () {
      for (final req in kGuideTalkRequired) {
        final covered =
            kFlowInlineTalk.contains(req) || kFlowCommonTalk.contains(req);
        expect(covered, isTrue, reason: '对白必选字段 $req 无处可填');
      }
      for (final req in kGuideOptionRequired) {
        final covered =
            kFlowInlineOption.contains(req) || kFlowCommonOption.contains(req);
        expect(covered, isTrue, reason: '选项必选字段 $req 无处可填');
      }
    });

    test('效果/条件类字段不得是裸文本框（全角逗号会绕过校验进存档）', () {
      final metas = {
        for (final cfg in ['TalkCfg', 'OptionCfg'])
          for (final m in flowFieldMetas(state, cfg)) '$cfg:${m.key}': m,
      };
      for (final m in metas.values) {
        final mustGuard = m.effectLike || m.type == '2D Array';
        if (!mustGuard) continue;
        expect(
          m.rule?.fixed == null && m.rule?.dictName == null || m.effectLike,
          isTrue,
          reason: '${m.key} 是 ${m.type} 指令字段，必须走带校验的补全框',
        );
      }
      // 直接点名本期新补的三条：stateCond 曾被命名猜测漏掉。
      expect(metas['OptionCfg:stateCond']!.effectLike, isTrue);
      expect(metas['OptionCfg:precondition']!.effectLike, isTrue);
      expect(metas['TalkCfg:screenEffect']!.effectLike, isTrue);
    });

    test('主键 id 只读，vocals 归高级段', () {
      for (final cfg in ['TalkCfg', 'OptionCfg']) {
        final byKey = {for (final m in flowFieldMetas(state, cfg)) m.key: m};
        expect(byKey['id']!.editable, isFalse, reason: '$cfg.id 可写会毁掉主键');
      }
      final talk = {
        for (final m in flowFieldMetas(state, 'TalkCfg')) m.key: m,
      };
      expect(talk['vocals']!.inCommon, isFalse, reason: '遗留字段不该占常用位');
    });
  });

  group('展开态卡片', () {
    testWidgets('对白卡片渲染出全部内联字段且撑破固定高度也不溢出', (tester) async {
      await mount(tester);
      await expand(tester, _talk);

      final suggestions = find.descendant(
        of: find.byType(StoryFlowGraph),
        matching: find.byType(SuggestionTextField),
      );
      final allBoxes = find.descendant(
        of: find.byType(StoryFlowGraph),
        matching: find.byType(fluent.TextBox),
      );
      final boxesInSuggest = find.descendant(
        of: find.byType(SuggestionTextField),
        matching: find.byType(fluent.TextBox),
      );
      // 6 个带候选/校验（check screenEffect bg audio highlights nextTalk）
      // + 3 个裸文本（roleName content time）= kFlowInlineTalk.length
      expect(suggestions.evaluate().length, 6);
      expect(
        allBoxes.evaluate().length - boxesInSuggest.evaluate().length,
        kFlowInlineTalk.length - 6,
        reason: '补全框内部也含一个 TextBox，直接数会连它一起数进去',
      );
      // 字段变多只能靠编辑区自身的滚动消化，不许改卡片高度常量。
      expect(
        find.descendant(
          of: find.byType(StoryFlowGraph),
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
    });

    testWidgets('展开态足迹仍钉在 kFlowTalkExpandedH（不按字段数算高）', (
      tester,
    ) async {
      await mount(tester);
      await expand(tester, _talk);

      expect(
        expandedCardFootprint(),
        findsWidgets,
        reason: '展开高度不再钉在常量上 → 命中矩形/箭头/端口/连线会集体错位',
      );
    });

    testWidgets('收起后恢复折叠足迹', (tester) async {
      await mount(tester);
      await expand(tester, _talk);
      final w = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
      w.onToggleExpand(_talk);
      await tester.pumpAndSettle();

      expect(expandedCardFootprint(), findsNothing);
    });

    testWidgets('红字只标失败的那个字段', (tester) async {
      await mount(tester);
      var w = await expand(tester, _talk);

      final checkCtl = w.fieldController(_talk, 'check')!;
      checkCtl.text = '[[1,2';
      w.onFieldChanged(_talk, 'check', '[[1,2');
      await tester.pumpAndSettle();

      expect(w.fieldInvalid(_talk, 'check'), isTrue);
      expect(w.fieldInvalid(_talk, 'screenEffect'), isFalse);
      expect(
        find.descendant(
          of: find.byType(StoryFlowGraph),
          matching: find.text('解析失败，未写入存档'),
        ),
        findsOneWidget,
        reason: '红字按字段计数：整卡一起变红等于没告诉用户哪儿错了',
      );
      // 解析失败不得改写记录：旧实现会 rec.remove，坏数据直接跟着保存落盘。
      // 用 hasCheck 作可观察代理——check 被抹掉时检定端口/徽章会一起消失。
      final node = tester
          .widget<StoryFlowGraph>(find.byType(StoryFlowGraph))
          .graph
          .nodes
          .firstWhere((n) => n.id == _talk);
      expect(node.hasCheck, isTrue, reason: '非法输入把 check 抹掉了');
      expect(
        checkCtl.text,
        '[[1,2',
        reason: '文本被回退成上一个合法值 → 用户觉得「字段永远打不进去」',
      );
    });
  });
}

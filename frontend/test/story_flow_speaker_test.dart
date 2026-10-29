// 剧情图卡片说话人（标题输入）回归。
//
// 卡片标题现在是说话人输入框：`_submitSpeaker` 把用户输入解析成
// `roleIds`（人物 id）或 `roleName`（自定义/旁白）。这里锁住四条分支：
//   · 精确名称 / 精确 ID → 写 roleIds、清 roleName，输入框回填人物名；
//   · 「旁白」 → 写 roleName='旁白'、清 roleIds；
//   · 空串 → 两者皆清（无名）；
//   · 相近但不精确 / 完全找不到 → 弹窗列候选，取消后保留为自定义 roleName
//     （绝不静默丢弃用户输入）。
//
// 可观测性说明：`_speakerDisplay` 对「roleIds 解析出的人物名」与「roleName
// 自定义名」都回填到同一个输入框，单看输入框分不清走了哪条分支；因此
// 断言都成对出现——输入框文案 + 图节点 roleName（后者只读 talk['roleName']），
// 两者组合即可唯一定位分支。
//
// 驱动方式与 test/story_flow_undo_test.dart 一致：起真宿主 StoryFlowWorkspace，
// 通过画布暴露的 onSpeakerSubmitted 注入用户动作。
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/story/story_flow_graph.dart';
import 'package:student_age_editor/features/story/story_flow_models.dart';
import 'package:student_age_editor/features/story/story_flow_workspace.dart';

const _evt = '1000001';
const _evtTitle = '说话人事件';
const _t1 = '1000001000';
const _t2 = '1000001001';

/// 人物 id → 展示名。10=主角、102=小明、103=小明强：
/// 让「小明」能精确命中，而「小」会同时模糊命中两个 → 走弹窗分支。
const _roles = <String, dynamic>{
  '10': ['主角'],
  '102': ['小明'],
  '103': ['小明强'],
};

void main() {
  late AppState state;

  setUp(() {
    state = AppState()
      ..modName = 'Speaker'
      ..modRoot = r'C:\mods\speaker'
      ..gameDicts = {'roles': _roles};
    state.gameSchema = {
      'TalkCfg': {
        'id': 'Number',
        'roleName': 'String',
        'roleIds': '1D Array',
        'content': 'String',
        'nextTalk': '1D Array',
      },
      'OptionCfg': {
        'id': 'Number',
        'content': 'String',
        'talkId': '1D Array',
      },
    };
    ApiClient.instance.client = MockClient((request) async {
      final path = request.url.path;
      if (path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        var data = <String, dynamic>{};
        if (name == 'EvtCfg') {
          data = {
            _evt: {
              'id': int.parse(_evt),
              'title': _evtTitle,
              'talkId': [_t1],
            },
          };
        }
        if (name == 'TalkCfg') {
          data = {
            _t1: {
              'id': int.parse(_t1),
              'content': '甲',
              'nextTalk': [_t2],
            },
            _t2: {'id': int.parse(_t2), 'content': '乙', 'nextTalk': <String>[]},
          };
        }
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
      if (path == '/api/plugins/ui/flow_cards') {
        return http.Response(
          '{"flow_cards": []}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/api/tools/read') {
        return http.Response(
          '{"error": "not a file"}',
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"ok": true}',
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
    expect(find.byType(StoryFlowGraph), findsOneWidget);
  }

  StoryFlowGraph canvasOf(WidgetTester tester) =>
      tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));

  /// 卡片标题说话人输入框当前文案。
  String speakerText(WidgetTester tester, String id) =>
      canvasOf(tester).speakerController(id)!.text;

  FlowNode? nodeOf(WidgetTester tester, String id) {
    for (final n in canvasOf(tester).graph.nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 布局回写防抖 800ms + 普通动画收尾，避免残留 pending timer。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
  }

  /// displayInfoBar 自动关闭是 3s 定时器（外加进出场动画），pumpAndSettle 排不掉，
  /// 必须把假时间推过去，否则测试结尾报「Timer is still pending」。
  /// 先 pump 一帧让 InfoBar 挂上（此时才注册 250ms/3s 两个 Future.delayed），
  /// 再 elapse 把这两个定时器烧掉，最后收尾退场动画。
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('精确名称：写 roleIds、清 roleName，输入框回填人物名', (tester) async {
    await mount(tester);
    expect(
      speakerText(tester, _t1),
      '',
      reason: '前置：甲初始没有说话人',
    );

    canvasOf(tester).onSpeakerSubmitted(_t1, '小明');
    await drainToast(tester);

    expect(
      speakerText(tester, _t1),
      '小明',
      reason: '输入框应从 roleIds 解析回填人物名（而非停留在原始输入）',
    );
    expect(
      nodeOf(tester, _t1)!.roleName,
      '',
      reason: '精确命中必须写 roleIds 而不是把名称当自定义 roleName',
    );
  });

  testWidgets('精确 ID：写 roleIds、清 roleName', (tester) async {
    await mount(tester);

    canvasOf(tester).onSpeakerSubmitted(_t1, '102');
    await drainToast(tester);

    expect(speakerText(tester, _t1), '小明');
    expect(nodeOf(tester, _t1)!.roleName, '');
  });

  testWidgets('「旁白」：写 roleName、清 roleIds', (tester) async {
    await mount(tester);

    canvasOf(tester).onSpeakerSubmitted(_t1, '旁白');
    await settle(tester);

    expect(speakerText(tester, _t1), '旁白');
    expect(
      nodeOf(tester, _t1)!.roleName,
      '旁白',
      reason: '旁白应落成 roleName，卡片标签才显示「旁白」',
    );
  });

  testWidgets('空串：清空说话人（roleName 与 roleIds 都不留）', (tester) async {
    await mount(tester);
    // 先设成 小明，再清空，确保是「从有到无」而不是本来就没设。
    canvasOf(tester).onSpeakerSubmitted(_t1, '小明');
    await drainToast(tester);
    expect(speakerText(tester, _t1), '小明');

    canvasOf(tester).onSpeakerSubmitted(_t1, '');
    await settle(tester);

    expect(speakerText(tester, _t1), '');
    expect(nodeOf(tester, _t1)!.roleName, '');
  });

  testWidgets('模糊命中：弹窗列候选，取消则保留为自定义 roleName', (tester) async {
    await mount(tester);

    // 「小」同时命中 小明 / 小明强，不精确 → 弹窗。
    canvasOf(tester).onSpeakerSubmitted(_t1, '小');
    await tester.pumpAndSettle();

    expect(
      find.textContaining('未精确匹配'),
      findsOneWidget,
      reason: '相近但非精确应当弹窗让人选，而不是静默取第一个',
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settle(tester);

    expect(
      speakerText(tester, _t1),
      '小',
      reason: '取消后输入必须原样保留为 roleName',
    );
    expect(
      nodeOf(tester, _t1)!.roleName,
      '小',
      reason: '取消 = 记为自定义名字，不能丢用户输入',
    );
  });

  testWidgets('完全找不到：弹「未找到人物」弹窗，取消同样保留自定义名', (tester) async {
    await mount(tester);

    canvasOf(tester).onSpeakerSubmitted(_t1, '小白');
    await tester.pumpAndSettle();

    expect(find.textContaining('未找到人物「小白」'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await settle(tester);

    expect(speakerText(tester, _t1), '小白');
    expect(nodeOf(tester, _t1)!.roleName, '小白');
  });
}

// 阶段 4a 验收：墓碑集合 story 级共享、单次拉取。
//
// 旧实现：每张 talk/option 卡片 build 时各自
//   `FutureBuilder(future: isDeleted(id))`，一个 story 几十个节点 =
//   几十次 GET /api/cfg/deleted_talks。
// 现在：随 story 数据加载**单次**拉取成 Set<String>（TombstoneStore），
//   卡片同步读；删除成功/保存删行后 reload 刷新（内容变化才 bump 版本）。
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
import 'package:student_age_editor/features/story/tombstone_node_widget.dart';

const _evt = '1000001';
const _t1 = '1000001000';
const _t2 = '1000001001';
const _t3 = '1000001002';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('TombstoneStore：单次拉取 + 版本号只在内容变化时 bump', () {
    tearDown(() {
      ApiClient.instance.client = http.Client();
    });

    test('加载一次成 Set；重拉同内容不 bump，内容变化才 bump+通知', () async {
      var gets = 0;
      Map<String, dynamic>? payload = {_t1: null, _t2: ['9']};
      ApiClient.instance.client = MockClient((request) async {
        gets++;
        return _json({'cfg': 'deleted_talks', 'tombstones': payload});
      });
      final store = TombstoneStore();
      addTearDown(store.dispose);
      var notified = 0;
      store.addListener(() => notified++);

      expect(store.contains(_t1), isFalse, reason: '未加载前恒 false');
      await store.reload();
      expect(gets, 1);
      expect(store.contains(_t1), isTrue);
      expect(store.contains(_t2), isTrue, reason: 'redirect 形态的墓碑也算');
      expect(store.contains(_t3), isFalse);
      expect(store.version, 1);
      expect(notified, 1);

      // 同内容重拉：请求照发，但版本不动、不通知（不白白作废整批卡片）。
      await store.reload();
      expect(gets, 2);
      expect(store.version, 1);
      expect(notified, 1);

      // 内容变化：_t2 没了、_t3 多了。
      payload = {_t1: null, _t3: null};
      await store.reload();
      expect(store.version, 2);
      expect(notified, 2);
      expect(store.contains(_t2), isFalse);
    });

    test('拉取失败：保留旧集合、不 bump、不抛（不拖垮宿主）', () async {
      ApiClient.instance.client = MockClient((request) async {
        return _json({'tombstones': {_t1: null}});
      });
      final store = TombstoneStore();
      addTearDown(store.dispose);
      await store.reload();
      expect(store.version, 1);

      ApiClient.instance.client = MockClient(
        (request) async => throw http.ClientException('boom'),
      );
      await store.reload(); // 不应抛出
      expect(store.contains(_t1), isTrue, reason: '失败保留旧集合');
      expect(store.version, 1);
    });

    test('在途并发 reload 折叠为单飞 + 结束后补拉一次', () async {
      var gets = 0;
      ApiClient.instance.client = MockClient((request) async {
        gets++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _json({'tombstones': {}});
      });
      final store = TombstoneStore();
      addTearDown(store.dispose);
      // 注意：不能用 Future.wait——handler 里 await delayed 走的是真实计时器，
      // test()（非 FakeAsync）下没问题，但要等两轮各 10ms。
      final a = store.reload();
      final b = store.reload(); // 在途 → 只标记 pending，不另发请求
      await a;
      await b;
      await store.reload(); // 等折叠出的补拉结束
      expect(gets, greaterThanOrEqualTo(2));
      expect(gets, lessThan(4), reason: '并发调用不得演变成每调用一次一请求');
    });
  });

  group('工作区接线：每 story 一次 GET /api/cfg/deleted_talks', () {
    late AppState state;
    late Map<String, dynamic> tombstones;
    late List<int> gets;

    Map<String, dynamic> talks() => {
      _t1: {
        'id': int.parse(_t1),
        'content': '甲',
        'nextTalk': [_t2],
      },
      _t2: {'id': int.parse(_t2), 'content': '乙', 'nextTalk': <String>[]},
      _t3: {'id': int.parse(_t3), 'content': '丙', 'nextTalk': <String>[]},
    };

    setUp(() {
      state = AppState()
        ..modName = 'Tomb'
        ..modRoot = r'C:\mods\tomb';
      state.gameSchema = {
        'TalkCfg': {
          'id': 'Number',
          'content': 'String',
          'nextTalk': '1D Array',
        },
        'OptionCfg': {
          'id': 'Number',
          'content': 'String',
          'talkId': '1D Array',
          'nextEvtId': 'Number',
        },
      };
      final evtCfg = <String, dynamic>{
        _evt: {
          'id': int.parse(_evt),
          'title': '墓碑事件',
          'talkId': [_t1],
        },
      };
      tombstones = {_t2: null}; // 乙已被删除：图上应渲染占位方块
      gets = [0];
      ApiClient.instance.client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'DELETE' && path.startsWith('/api/cfg/')) {
          final id = path.split('/').last;
          tombstones[id] = null; // 后端语义：删除即立墓碑
          return _json({'ok': true, 'tombstone_created': true});
        }
        // deleted_talks 必须排在通用 /api/cfg/ 分支前。
        if (path == '/api/cfg/deleted_talks') {
          gets[0]++;
          return _json({
            'cfg': 'deleted_talks',
            'tombstones': tombstones,
            'data': {},
            'keys': <String>[],
            'exists': true,
            'mtime_ns': 1,
          });
        }
        if (path.startsWith('/api/cfg/')) {
          final name = path.split('/').last;
          var data = <String, dynamic>{};
          if (name == 'EvtCfg') data = evtCfg;
          if (name == 'TalkCfg') data = talks();
          return _json({
            'cfg': name,
            'data': data,
            'keys': data.keys.toList(),
            'exists': true,
            'mtime_ns': 1,
          });
        }
        if (path == '/api/plugins/ui/flow_cards') {
          return _json({'flow_cards': []});
        }
        if (path == '/api/tools/read') {
          return http.Response(
            '{"error": "not a file"}',
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        return _json({'ok': true});
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

    Finder nodeText(String s) => find.descendant(
      of: find.byType(StoryFlowGraph),
      matching: find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains(s),
      ),
    );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
    }

    testWidgets('3 张 talk 卡片：加载只发 1 次 deleted_talks；重建不再发', (tester) async {
      await mount(tester);
      expect(
        gets[0],
        1,
        reason: '共享集合应随 story 数据只拉一次（旧实现=每卡片一次）',
      );
      // 墓碑节点渲染占位方块，普通节点不受影响。
      expect(find.byType(TombstoneNodeWidget), findsOneWidget);
      expect(nodeText('乙'), findsNothing);
      expect(nodeText('甲'), findsOneWidget);
      expect(nodeText('丙'), findsOneWidget);

      // 画布重建（选中、拖拽、宿主重泵）都不得再各发一次请求。
      final w = tester.widget<StoryFlowGraph>(find.byType(StoryFlowGraph));
      w.onSelectionChanged(FlowSelection.ofNode(_t1));
      await tester.pump();
      tester
          .widget<StoryFlowGraph>(find.byType(StoryFlowGraph))
          .onMoveNode(_t1, const Offset(320, 320));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(gets[0], 1, reason: '卡片必须同步读共享集合，不再各自发请求');
    });

    testWidgets('点墓碑删除落盘：集合刷新只补 1 次请求，节点摘除', (tester) async {
      await mount(tester);
      expect(gets[0], 1);

      await tester.tap(find.byType(TombstoneNodeWidget));
      await settle(tester);

      expect(
        gets[0],
        2,
        reason: 'deleteRecord 成功后刷新一次（一次，不是每张卡片一次）',
      );
      expect(find.byType(TombstoneNodeWidget), findsNothing);
      expect(nodeText('乙'), findsNothing);
      expect(nodeText('甲'), findsOneWidget);
    });
  });
}

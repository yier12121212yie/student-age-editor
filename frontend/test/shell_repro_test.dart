// 复现：真实 EditorShell 完整环境（含 AiPanel 默认打开 + 编辑标签页）
// 语义启用时是否触发 parentDataDirty 断言。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/editor_controller.dart';
import 'package:student_age_editor/features/shell/editor_area.dart';

void main() {
  testWidgets('完整 EditorShell + 编辑标签页 + 语义启用不触发 parentDataDirty',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = AppState()
      ..gameSchema = {
        'EvtCfg': {
          'id': 'Number', 'title': 'String', 'type': 'Number',
          'talkId': '1D Array', 'npc': 'Number', 'effect': '2D Array',
          'condition': '2D Array', 'content': 'String', 'weight': 'Number',
        },
        'PersonCfg': {
          'id': 'Number', 'name': 'String', 'type': 'Number', 'desc': 'String',
        },
        'TalkCfg': {
          'id': 'Number', 'roleIds': '1D Array', 'content': 'String',
          'nextTalk': '1D Array', 'option': '1D Array', 'bg': 'Number',
        },
      }
      ..gameDicts = {
        'roles': {'100': '角色A', '101': '角色B'},
        'evt_types': {'0': '类型0', '1': '类型1'},
      }
      ..keyMaps = {
        'EvtCfg': {'title': '标题', 'type': '类型'},
      };
    ApiClient.instance.client = MockClient((req) async {
      final path = req.url.path;
      if (req.method == 'GET' && path.startsWith('/api/cfg/')) {
        final name = path.split('/').last;
        final data = <String, dynamic>{};
        if (name == 'EvtCfg') {
          data['1'] = {'id': 1, 'title': '事件一', 'type': 1, 'npc': 100,
              'talkId': <dynamic>[10001], 'effect': <dynamic>[], 'content': '内容'};
          data['2'] = {'id': 2, 'title': '事件二', 'type': 0, 'npc': 101,
              'talkId': <dynamic>[10002], 'effect': <dynamic>[], 'content': '内容2'};
        } else if (name == 'PersonCfg') {
          data['100'] = {'id': 100, 'name': '角色A', 'type': 1, 'desc': '描述A'};
          data['101'] = {'id': 101, 'name': '角色B', 'type': 0, 'desc': '描述B'};
        } else if (name == 'TalkCfg') {
          data['10001'] = {'id': 10001, 'roleIds': <dynamic>[100],
              'content': '对白一', 'bg': 0, 'nextTalk': <dynamic>[], 'option': <dynamic>[]};
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'data': data, 'exists': true})),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.method == 'GET' && path == '/api/state') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'workspace_root': 'C:/mods', 'mod_root': 'C:/mods/test',
            'mod_name': 'test', 'aa_status': 'idle',
            'mods': <dynamic>[],
          })),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'error': 'mock 404'})),
        404,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(() {
      ApiClient.instance.client = http.Client();
    });

    final controller = EditorController();
    // 打开三个编辑标签页（对应截图：故事、人物、事件）
    controller.open(OpenDoc.page(pageId: 'story', title: '故事'));
    controller.open(OpenDoc.page(pageId: 'person', title: '人物'));
    controller.open(OpenDoc.page(pageId: 'evt', title: '事件'));

    await tester.pumpWidget(fluent.FluentApp(
      home: Scaffold(
        body: SizedBox(
          width: 1600,
          height: 1000,
          child: EditorArea(state: state, controller: controller),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '三个编辑标签页渲染不应异常');

    // 切换到故事页（StoryDirectorView）
    await tester.tap(find.text('故事'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '故事页渲染不应异常');

    // 切换到人物页（SchemaEditorView: PersonCfg）
    await tester.tap(find.text('人物'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '人物页渲染不应异常');

    // 切换到事件页
    await tester.tap(find.text('事件'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '事件页渲染不应异常');

    // 编辑输入（触发 onChanged → setState → 重建）
    final boxes = find.byType(fluent.TextBox);
    if (boxes.evaluate().isNotEmpty) {
      await tester.ensureVisible(boxes.first);
      await tester.enterText(boxes.first, '修改内容');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: '编辑输入不应异常');
    }

    // 打开 ComboBox 下拉
    final combos = find.byType(fluent.ComboBox<String>);
    if (combos.evaluate().isNotEmpty) {
      await tester.tap(combos.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '打开下拉不应异常');
    }

    semanticsHandle.dispose();
  });
}

// 经典布局编辑区（SchemaEditorView classic 模式）冒烟测试：
// 📚 条目列表卡 + ✏️ 字段编辑卡 + 💾 保存按钮渲染。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

AppState _state() => AppState()
  ..gameSchema = {
    'EvtCfg': {
      'id': 'Number',
      'title': 'String',
      'type': 'Number',
      'content': 'String',
    },
  }
  ..keyMaps = {
    'EvtCfg': {'title': '标题', 'type': '类型'},
  }
  ..gameDicts = {};

void main() {
  testWidgets('经典编辑区：列表卡 + 字段卡 + 保存按钮渲染', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async {
      if (req.url.path == '/api/cfg/EvtCfg') {
        return http.Response(
          '{"data":{"1":{"id":1,"title":"事件一","type":0,"content":"内容"}'
          ',"2":{"id":2,"title":"事件二","type":1,"content":"内容2"}},"exists":true}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"ok":true}', 200,
          headers: {'content-type': 'application/json'});
    });

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SchemaEditorView(state: _state(), cfgName: 'EvtCfg', classic: true),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull, reason: '经典编辑区渲染不应异常');

    // 卡片标题
    expect(find.text('📚 EvtCfg 条目列表'), findsOneWidget);
    expect(find.text('📝 字段编辑'), findsOneWidget);
    // 列表上方工具按钮
    expect(find.text('➕ 新建条目'), findsOneWidget);
    expect(find.text('🗑️ 删除选中'), findsOneWidget);
    // 底部保存大按钮
    expect(find.text('💾 保存修改至 EvtCfg'), findsOneWidget);
    // 两列表格表头
    expect(find.text('属性名称'), findsOneWidget);
    expect(find.text('属性值'), findsOneWidget);
    // 条目列表已加载（列表项 + 右侧表单回显）
    expect(find.text('事件一'), findsWidgets);
    expect(find.text('事件二'), findsOneWidget);
    // 字段表单（标题字段值）
    expect(find.text('标题'), findsWidgets);
  });

  testWidgets('创作模式编辑区不受影响（无卡片标题）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiClient.instance.client = MockClient((req) async => http.Response(
        '{"data":{"1":{"id":1,"title":"事件一"}},"exists":true}',
        200,
        headers: {'content-type': 'application/json'}));

    await tester.pumpWidget(fluent.FluentApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SchemaEditorView(state: _state(), cfgName: 'EvtCfg'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('📚 EvtCfg 条目列表'), findsNothing);
    expect(find.text('📝 字段编辑'), findsNothing);
  });
}
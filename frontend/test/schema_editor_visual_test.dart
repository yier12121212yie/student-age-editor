// M1 接线冒烟：SchemaEditorView（经典布局）按 fieldVisualFor 分发新控件——
// 步进/滑杆、跳转浏览对话框、chips 移序/移除、音频试听请求链路。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/editor/visual_fields.dart';

/// 通用 JSON 响应头
http.Response _json(Object body, [int code = 200]) => http.Response(
      jsonEncode(body), code,
      headers: {'content-type': 'application/json'},
    );

AppState _st(Map<String, dynamic> schema, Map<String, dynamic> dicts) =>
    AppState()
      ..gameSchema = schema
      ..keyMaps = {}
      ..gameDicts = dicts;

Future<void> _mount(
  WidgetTester tester,
  AppState state,
  String cfg,
  List<String> requests, {
  Size size = const Size(1400, 900),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  ApiClient.instance.client = MockClient((req) async {
    requests.add('${req.method} ${req.url.path}');
    final p = req.url.path;
    if (p.startsWith('/api/cfg/') && !p.startsWith('/api/cfg_ids')) {
      final cfgName = p.split('/').last;
      return _json({'data': _tables[cfgName] ?? {}, 'exists': true});
    }
    if (p == '/api/cfg_ids') {
      return _json({'items': _idItems[req.url.queryParameters['name']] ?? []});
    }
    if (p == '/api/aa/preview') {
      return _json({'error': '资源包未解码'}, 422);
    }
    if (p == '/api/tools/read') {
      return _json({'base64': base64Encode([1, 2, 3])});
    }
    return _json({'ok': true});
  });
  await tester.pumpWidget(fluent.FluentApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SchemaEditorView(state: state, cfgName: cfg, classic: true),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 各表的数据 fixture（id 形态按 /api/cfg/<name> 的 {id: record} 约定）
final Map<String, Map<String, dynamic>> _tables = {
  'RelationCfg': {
    '7': {'id': 7, 'name': '恋人', 'condition': 90, 'socialCapacity': 1},
  },
  'EvtCfg': {
    '1200001': {
      'id': 1200001,
      'title': '开学',
      'talkId': [32010101],
    },
  },
  'TalkCfg': {
    '32010101': {
      'id': 32010101,
      'content': '你来了',
      'audio': 4,
      'roleIds': [101, 102],
    },
  },
  'AudioCfg': {
    '4': {'id': 4, 'name': '主题BGM', 'url': 'Audio/4.wav', 'type': 1},
  },
};

final Map<String, List<Map<String, dynamic>>> _idItems = {
  'TalkCfg': [
    {'id': '32010101', 'preview': '你来了'},
    {'id': '32010102', 'preview': '快进去吧'},
    {'id': '32010199', 'preview': '另一句'},
  ],
  'AudioCfg': [
    {'id': '4', 'preview': '主题BGM'},
  ],
};

void main() {
  testWidgets('Number 字段：步进框接管，无规则字段不再有裸文本框', (tester) async {
    final reqs = <String>[];
    await _mount(
      tester,
      _st({
        'RelationCfg': {
          'id': 'Number',
          'name': 'String',
          'condition': 'Number',
          'socialCapacity': 'Number',
        },
      }, {}),
      'RelationCfg',
      reqs,
    );
    expect(tester.takeException(), isNull);
    // id/condition/socialCapacity 都渲染 NumberBox；condition（±999）与
    // socialCapacity（0~50）各自命中 kFieldNumericHints，两根滑杆。
    expect(find.byType(fluent.NumberBox), findsNWidgets(3));
    expect(find.byType(fluent.Slider), findsNWidgets(2));
  });

  testWidgets('跳转目标：浏览对话框（有序多选写回）', (tester) async {
    final reqs = <String>[];
    await _mount(
      tester,
      _st({
        'EvtCfg': {
          'id': 'Number',
          'title': 'String',
          'talkId': '1D Array',
        },
      }, {}),
      'EvtCfg',
      reqs,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('浏览跳转目标'), findsOneWidget);
    await tester.tap(find.text('浏览跳转目标'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 对话框渲染 ID·预览；勾选第三项后按序确定。
    expect(find.text('32010199 · 另一句'), findsOneWidget);
    await tester.tap(find.text('32010199 · 另一句'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 写回：原值在前、新选追加（有序）。
    expect(find.text('32010101, 32010199'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('音频字段：ComboBox + 试听按钮；试听走 aa 回落 tools/read', (tester) async {
    final reqs = <String>[];
    await _mount(
      tester,
      _st({
        'TalkCfg': {
          'id': 'Number',
          'content': 'String',
          'audio': 'Number',
        },
      }, {
        'audios': {'4': '主题BGM'},
      }),
      'TalkCfg',
      reqs,
    );
    expect(tester.takeException(), isNull);
    // ComboBox（audios 字典候选）+ 试听 + 浏览三件套并存。
    expect(find.byType(AudioAuditionButton), findsOneWidget);
    expect(find.text('浏览'), findsOneWidget);
    await tester.tap(find.byType(AudioAuditionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 解析链：AudioCfg 表 → aa 预览（422）→ mod 文件兜底。
    expect(reqs, contains('GET /api/cfg/AudioCfg'));
    expect(reqs, contains('POST /api/aa/preview'));
    expect(reqs, contains('GET /api/tools/read'));
    // 平台播放器在测试环境不可用，异常已被按钮吞掉。
    expect(tester.takeException(), isNull);
  });

  testWidgets('多值 ID 引用：chips 按序显示，可移除', (tester) async {
    final reqs = <String>[];
    await _mount(
      tester,
      _st({
        'TalkCfg': {
          'id': 'Number',
          'roleIds': '1D Array',
        },
      }, {
        'roles': {'101': '小明', '102': '小红'},
      }),
      'TalkCfg',
      reqs,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('101 · 小明'), findsOneWidget);
    expect(find.text('102 · 小红'), findsOneWidget);
    // 移除首项：文本与值同步为 '102'
    await tester.tap(find.text('✕').first);
    await tester.pump();
    expect(find.text('101 · 小明'), findsNothing);
    expect(find.text('102 · 小红'), findsOneWidget);
    expect(find.text('102'), findsWidgets);
  });

  testWidgets('窄屏加固：窄视口下音频行不 RenderFlex 溢出', (tester) async {
    final reqs = <String>[];
    await _mount(
      tester,
      _st({
        'TalkCfg': {
          'id': 'Number',
          'content': 'String',
          'audio': 'Number',
        },
      }, {
        'audios': {'4': '主题BGM'},
      }),
      'TalkCfg',
      reqs,
      size: const Size(500, 1000),
    );
    expect(tester.takeException(), isNull,
        reason: '窄视口下任何 RenderFlex overflow 都会以异常浮现');
    // ComboBox + 试听/导入/浏览三件套在窄屏折行后仍然齐全。
    expect(find.byType(AudioAuditionButton), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('浏览'), findsOneWidget);
  });

  testWidgets('窄屏加固：窄视口下跳转目标行不 RenderFlex 溢出', (tester) async {
    final reqs = <String>[];
    await _mount(
      tester,
      _st({
        'EvtCfg': {
          'id': 'Number',
          'title': 'String',
          'talkId': '1D Array',
        },
      }, {}),
      'EvtCfg',
      reqs,
      size: const Size(500, 1000),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('浏览跳转目标'), findsOneWidget);
  });
}

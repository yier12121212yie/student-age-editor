// 编辑页「查找字段」：模糊匹配纯函数 + SchemaEditorView 接线冒烟。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/field_search.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';

void main() {
  group('fuzzyScore', () {
    test('空查询返回 0，无命中返回 null', () {
      expect(fuzzyScore('', 'name'), 0);
      expect(fuzzyScore('zz', 'name'), isNull);
    });

    test('完全相等 > 前缀 > 子串', () {
      final exact = fuzzyScore('name', 'name')!;
      final prefix = fuzzyScore('na', 'name')!;
      final inner = fuzzyScore('am', 'name')!;
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(inner));
      expect(inner, greaterThan(0));
    });

    test('忽略大小写', () {
      expect(fuzzyScore('NAME', 'name'), isNotNull);
      expect(fuzzyScore('name', 'NAME'), isNotNull);
    });

    test('子序列：允许跳字连打', () {
      expect(fuzzyScore('nm', 'name'), isNotNull);
      expect(fuzzyScore('cntnt', 'content'), isNotNull);
      // 顺序不对不算子序列
      expect(fuzzyScore('mn', 'name'), isNull);
    });
  });

  group('fuzzyFieldScore', () {
    test('标签命中（中文）', () {
      final s = fuzzyFieldScore(query: '名称', label: '名称', key: 'name');
      expect(s, isNotNull);
      expect(s, greaterThan(0));
    });

    test('键命中（英文）', () {
      expect(
        fuzzyFieldScore(query: 'name', label: '名称', key: 'name'),
        isNotNull,
      );
    });

    test('多词查询要求全部命中', () {
      expect(
        fuzzyFieldScore(
          query: '名称 name',
          label: '名称',
          key: 'name',
        ),
        isNotNull,
      );
      expect(
        fuzzyFieldScore(
          query: '名称 zzz',
          label: '名称',
          key: 'name',
        ),
        isNull,
      );
    });

    test('帮助文案命中（低权重但可见）', () {
      expect(
        fuzzyFieldScore(
          query: '主键',
          label: '编号',
          key: 'id',
          help: '记录编号（主键）：新建时自动分配',
        ),
        isNotNull,
      );
    });
  });

  group('fuzzyMatchRanges', () {
    test('子串返回单区间', () {
      expect(fuzzyMatchRanges('name', 'name'), [(0, 4)]);
      expect(fuzzyMatchRanges('am', 'name'), [(1, 3)]);
    });

    test('子序列返回逐字区间', () {
      expect(fuzzyMatchRanges('nm', 'name'), [(0, 1), (2, 3)]);
    });

    test('多词取并集并合并连续区间', () {
      expect(fuzzyMatchRanges('na me', 'name'), [(0, 4)]);
    });

    test('空查询/空目标返回空', () {
      expect(fuzzyMatchRanges('', 'name'), isEmpty);
      expect(fuzzyMatchRanges('name', ''), isEmpty);
    });
  });

  group('SchemaEditorView 字段查找接线', () {
    AppState state() => AppState()
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

    Future<void> mount(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      ApiClient.instance.client = MockClient((req) async {
        if (req.url.path == '/api/cfg/EvtCfg') {
          return http.Response(
            '{"data":{"1":{"id":1,"title":"事件一","type":0,"content":"内容"}},'
            '"exists":true}',
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
          body: SchemaEditorView(
            state: state(),
            cfgName: 'EvtCfg',
            classic: true,
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    final findFieldSearch = find.byWidgetPredicate(
      (w) => w is fluent.TextBox && (w.placeholder?.contains('查找') ?? false),
    );

    testWidgets('查找框渲染，输入后按模糊匹配过滤字段', (tester) async {
      await mount(tester);
      expect(tester.takeException(), isNull);
      expect(findFieldSearch, findsOneWidget);

      // 初始展示全部字段（卡内 4 个字段的标签）。
      expect(find.text('类型'), findsOneWidget);

      // 输入「标题」：非命中的「类型」字段消失，命中项高亮渲染（Text.rich）。
      await tester.enterText(findFieldSearch, '标题');
      await tester.pump();
      expect(find.text('类型'), findsNothing);
      expect(
        find.textContaining('标题', findRichText: true),
        findsWidgets,
      );
      // 命中计数：x / 4。
      expect(find.textContaining('/ 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无命中显示占位，清除后恢复全部字段', (tester) async {
      await mount(tester);
      await tester.enterText(findFieldSearch, '不存在的字段xyz');
      await tester.pump();
      expect(find.textContaining('没有匹配'), findsOneWidget);

      await tester.tap(find.text('清除查找'));
      await tester.pump();
      // fluent.Button 的 onTapUp 延迟 100ms 复位按压态；等它结束以免测试结束
      // 时残留 pending timer。
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('没有匹配'), findsNothing);
      expect(find.text('类型'), findsOneWidget);
      expect(find.text('标题'), findsOneWidget);
    });

    testWidgets('英文键模糊搜索命中字段', (tester) async {
      await mount(tester);
      await tester.enterText(findFieldSearch, 'cont');
      await tester.pump();
      // content 字段标签为 content（无 keyMap），命中后以高亮 rich 渲染。
      expect(find.text('类型'), findsNothing);
      expect(find.textContaining('content', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}

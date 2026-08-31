import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import 'package:student_age_editor/features/story/story_flow_node_presets.dart';
import 'package:student_age_editor/features/story/story_flow_side_toolbar.dart';

/// 左侧工具栏「添加节点」分组菜单：内置预设（演出/分支/玩法）+ 插件卡，
/// 点击回调携带 (typeId, appliesTo)；未选事件时菜单不可打开。
void main() {
  final pluginCard = <String, dynamic>{
    'type_id': 'phone',
    'name': '打电话',
    'applies_to': 'talk',
    'color': '#3498DB',
  };

  late List<(String, String)> added;
  late int talkCalls;

  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    added = [];
    talkCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: fluent.FluentTheme(
        data: fluent.FluentThemeData(brightness: Brightness.dark),
        child: Scaffold(
          body: Center(
            child: StoryFlowSideToolbar(
              enabled: enabled,
              flowCards: [...builtinFlowCardSpecs(), pluginCard],
              assetsOpen: false,
              aiOpen: false,
              onToggleAssets: () {},
              onToggleAi: () {},
              onAddTalk: () => talkCalls++,
              onAddOption: () {},
              onAddCard: (id, applies) => added.add((id, applies)),
              onOpenPlugins: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('添加节点分组菜单', () {
    testWidgets('分组标题与内置预设/插件卡渲染', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('演出'), findsOneWidget);
      expect(find.text('分支'), findsOneWidget);
      expect(find.text('玩法'), findsOneWidget);
      expect(find.text('插件卡片'), findsOneWidget);
      expect(find.text('播放CG'), findsOneWidget);
      expect(find.text('转场特效'), findsOneWidget);
      expect(find.text('事件跳转'), findsOneWidget);
      expect(find.text('条件选项'), findsOneWidget);
      expect(find.text('打电话'), findsOneWidget);
      // 基础项恒在
      expect(find.textContaining('插入新对白'), findsOneWidget);
    });

    testWidgets('点击内置预设回调 (typeId, appliesTo)', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放CG'));
      await tester.pumpAndSettle();
      expect(added, [('cg_play', 'talk')]);
    });

    testWidgets('选项载体预设回调 appliesTo=option', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('事件跳转'));
      await tester.pumpAndSettle();
      expect(added, [('evt_goto', 'option')]);
    });

    testWidgets('插件卡回调仍走 card 路径', (tester) async {
      await pump(tester);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      // 插件卡在菜单尾部，可能超出弹窗可视区：先滚动到可见
      await tester.ensureVisible(find.text('打电话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打电话'));
      await tester.pumpAndSettle();
      expect(added, [('phone', 'talk')]);
    });

    testWidgets('未选事件（enabled=false）菜单不可打开', (tester) async {
      await pump(tester, enabled: false);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('播放CG'), findsNothing);
      expect(talkCalls, 0);
    });
  });
}

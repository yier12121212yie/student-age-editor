// 新增编辑页冒烟测试：用真实 schema.json / dicts.json 构造假后端，
// 逐页（含并入新表的旧页）渲染 EditorPageView，验证不抛异常、
// 默认表渲染出 SchemaEditorView、字段带中文标签（key_maps 生效）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/schema_editor_view.dart';
import 'package:student_age_editor/features/pages/page_view.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';

File _resolveAsset(String name) {
  for (final base in ['../native/assets', 'native/assets']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f;
  }
  throw StateError('找不到 native/assets/$name（cwd=${Directory.current.path}）');
}

void main() {
  final schema = jsonDecode(_resolveAsset('schema.json').readAsStringSync())
      as Map<String, dynamic>;
  final dicts = jsonDecode(_resolveAsset('dicts.json').readAsStringSync())
      as Map<String, dynamic>;

  late AppState state;

  setUp(() {
    state = AppState()
      ..gameSchema = schema
      ..keyMaps = dicts['key_maps'] as Map<String, dynamic>
      ..gameDicts = (dicts['game_dicts'] ?? {}) as Map<String, dynamic>;
    // 任意表返回一条占位条目（只有 id，其余字段留空），让字段表单真正渲染；
    // 未知端点同样回 {}，补全/校验失败均不阻塞渲染。
    ApiClient.instance.client = MockClient((req) async {
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {'1': {'id': 1}},
          'exists': true,
          'mtime_ns': 0,
        })),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  // story 页走剧情导演、official 页有专用卡片，均非本次新增；
  // 这里覆盖 17 个以 SchemaEditorView 呈现的页面（含并入新表的旧页）。
  final pagesToTest = editorPages
      .where((p) => p.id != 'story' && p.id != 'official')
      .toList();

  for (final page in pagesToTest) {
    testWidgets('页面 ${page.id} 渲染新表不异常', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(fluent.FluentApp(
        home: Scaffold(
          body: SizedBox(
            width: 1600,
            height: 1000,
            child: EditorPageView(state: state, page: page),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '${page.id} 渲染异常');

      // 默认表应出现（配置表下拉含 primaryCfg 文本），且 schema 编辑器挂载。
      expect(
        find.text(page.defaultCfg),
        findsWidgets,
        reason: '${page.id} 顶部下拉应含默认表',
      );
      expect(
        find.byType(SchemaEditorView),
        findsOneWidget,
        reason: '${page.id} 应渲染 SchemaEditorView',
      );
    });
  }

  testWidgets('新增表逐张挂载可渲染且首字段有中文标签', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 本次纳入的全部新表（与 pages_catalog 同步，拼写错会在这里暴露）。
    const newTables = {
      'news': ['NewsCfg', 'NewsCommentCfg', 'NewsTypeCfg'],
      'fishing': ['FishCfg', 'FishBaitCfg', 'FishTypeCfg', 'FishDiffCfg'],
      'travel': ['TripSpotCfg', 'TripTypeCfg', 'TripLevelCfg', 'TripEffectCfg'],
      'anime': [
        'AnimationCfg', 'AnimeConCfg', 'AnimationTypeCfg', 'AnimationWifeCfg',
        'AnimationRankCfg', 'AnimationCostCfg', 'AnimeConExpCfg',
        'AnimeKzoneContentCfg', 'AnimeMarkCntCfg', 'TalkAnimeCfg',
      ],
      'expo': ['ExpoSiteCfg', 'ExpoAttrCfg', 'ExpoEvtCfg'],
      'club': [
        'ClubActivityCfg', 'ClubMemberCfg', 'ClubDepartmentCfg', 'ClubDailyCfg',
        'ClueRumorCfg', 'ClubMemeberCntCfg', 'ClubFundsCfg',
      ],
      'crafts': ['DIYCfg', 'DIYRankCfg', 'HandicraftMiniGameCfg'],
      'birthday': [
        'BirthdayPaintCfg', 'LineMatchMinigameCfg', 'BirthdayPaintGuessCfg',
        'BirthdayRewardCfg', 'BirthdayLvCfg', 'BirthdayScoreCfg',
      ],
      'negotiation': [
        'NegotiationPlayerCfg', 'NegotiationTeamCfg', 'NegotiationTeammateCfg',
        'NegotiationTopicCfg', 'NegotiationCfg', 'NegotiationTalkCfg',
        'NegotiationChatCfg', 'NegotiationInvolvedCfg',
        'NegotiationMiniGameCardCfg', 'NegotiationUniqueCardCfg',
        'NegotiationMiniGameCardTypeCfg', 'NegotiationSkillCfg',
        'NegotiationBuffCfg', 'NegotiationMiniGameCfg', 'MomPowerCfg',
      ],
      // 并入旧页的新表
      'social': [
        'KZoneAvatarCfg', 'RenshengguanMemoryCfg', 'FriendRequestCfg',
      ],
      'person': ['ModFaceCfg'],
      'gift': ['PaperCfg'],
      'love': ['EndingDatingCfg'],
      'function': ['IntentCfg', 'ToggleCfg', 'TextCfg', 'ExploreCfg', 'JobUnlockCfg'],
      'evt': ['InteractCfg'],
    };

    for (final entry in newTables.entries) {
      final page = pageById(entry.key)!;
      for (final table in entry.value) {
        expect(page.cfgNames, contains(table),
            reason: '$table 应挂在 ${page.id} 页');
        expect(schema[table], isA<Map>(), reason: '$table 应有 schema');

        // 每个 schema 字段都应有中文标签，否则表单会吐英文原名。
        final keyMap = (state.keyMaps[table] as Map?) ?? const {};
        final fields = (schema[table] as Map).cast<String, dynamic>();
        final unlabeled =
            fields.keys.where((f) => (keyMap[f] as String?)?.isEmpty ?? true);
        expect(unlabeled, isEmpty, reason: '$table 字段缺中文标签：$unlabeled');
      }
    }
  });
}

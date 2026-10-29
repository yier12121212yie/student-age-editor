// 通用实体浏览面板的纯逻辑：字段规则 → 实体种类映射、零请求字典候选
// （数字序 / List 值取首元素）、MOD 名覆盖、以及后端不可达时的字典回退。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/nocode/entity_picker.dart';
import 'package:student_age_editor/features/resources/image_asset_picker.dart'
    show TexBytesCache, TexThumb, debugResetMergedMetaCache, refreshBgIdKeyMap;

http.Response _roles(List<Map<String, dynamic>> roles) => http.Response(
      jsonEncode({'roles': roles}),
      200,
      headers: {'content-type': 'application/json'},
    );

/// 模拟后端不可达：任何请求都抛连接异常（loadRoles 必须吞掉并退回字典）。
void _offline() {
  ApiClient.instance.client = MockClient(
    (req) async => throw http.ClientException('connection refused'),
  );
}

void main() {
  group('entityKindForRule', () {
    test('字典名 → 实体种类', () {
      expect(entityKindForRule(const FieldRule(dictName: 'roles')),
          EntityKind.roles);
      expect(entityKindForRule(const FieldRule(dictName: 'items')),
          EntityKind.items);
      expect(entityKindForRule(const FieldRule(dictName: 'bgs')),
          EntityKind.bgs);
      expect(entityKindForRule(const FieldRule(dictName: 'maps')),
          EntityKind.maps);
      expect(entityKindForRule(const FieldRule(dictName: 'attrs')),
          EntityKind.attrs);
      expect(entityKindForRule(const FieldRule(dictName: 'jobs')),
          EntityKind.jobs);
      expect(entityKindForRule(const FieldRule(dictName: 'relations')),
          EntityKind.relations);
      expect(entityKindForRule(const FieldRule(dictName: 'turns')),
          EntityKind.turns);
      expect(entityKindForRule(const FieldRule(dictName: 'evt_types')),
          EntityKind.evtTypes);
    });

    test('ID 引用表 → 实体种类', () {
      expect(entityKindForRule(const FieldRule(idRefCfg: 'PersonCfg')),
          EntityKind.roles);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'ItemCfg')),
          EntityKind.items);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'BgCfg')),
          EntityKind.bgs);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'MapCfg')),
          EntityKind.maps);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'AttrCfg')),
          EntityKind.attrs);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'JobCfg')),
          EntityKind.jobs);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'RelationCfg')),
          EntityKind.relations);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'EvtTypeCfg')),
          EntityKind.evtTypes);
    });

    test('没有字典池的引用返回 null（交回既有浏览/补全通道）', () {
      // TalkCfg / EvtCfg 的行活在舞台内存表里，game_dicts 没有对应池；
      // 'actions' 由 /api/effect_suggest(mode=action) 供给。
      expect(entityKindForRule(const FieldRule(idRefCfg: 'TalkCfg')), isNull);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'EvtCfg')), isNull);
      expect(entityKindForRule(const FieldRule(dictName: 'actions')), isNull);
      expect(entityKindForRule(const FieldRule(idRefCfg: 'AudioCfg')), isNull);
      expect(entityKindForRule(null), isNull);
    });

    test('field_meta 真源上的落点', () {
      expect(entityKindForRule(fieldRuleFor('TalkCfg', 'roleIds')),
          EntityKind.roles);
      expect(entityKindForRule(fieldRuleFor('TalkCfg', 'bg')), EntityKind.bgs);
      expect(entityKindForRule(fieldRuleFor('EvtCfg', 'talkId')), isNull);
    });
  });

  group('EntityKindMeta', () {
    test('字典名 / 中文标签 / 缩略图 / 上报白名单', () {
      expect(EntityKind.roles.dictName, 'roles');
      expect(EntityKind.evtTypes.dictName, 'evt_types');
      expect(EntityKind.turns.label, '学期');
      expect(EntityKind.roles.hasThumb, isTrue);
      expect(EntityKind.bgs.hasThumb, isTrue);
      expect(EntityKind.items.hasThumb, isFalse);
      // /api/usage 白名单只有 kind=role，其余种类一律不上报。
      expect(EntityKind.roles.usageKind, 'role');
      expect(EntityKind.items.usageKind, isNull);
    });
  });

  group('loadEntities 字典回退（零请求）', () {
    final dicts = <String, dynamic>{
      'items': {
        '101': '面包',
        '20': '牛奶',
        '7': ['旧物', '备注'],
      },
      'roles': {'10': '林晓', '-1': '旁白'},
    };

    test('后端不可达 → 用 gameDicts 兜底，数字 id 按数值序', () async {
      _offline();
      final items = await loadEntities(EntityKind.items, gameDicts: dicts);
      expect(items.map((e) => e.id).toList(), ['7', '20', '101']);
      // List 值取首元素当显示名（与 schema 编辑器候选同一口径）。
      expect(items.first.name, '旧物');
    });

    test('关键字过滤同时匹配 id 与名称', () async {
      _offline();
      final byName = await loadEntities(EntityKind.items, q: '牛', gameDicts: dicts);
      expect(byName.single.id, '20');
      final byId = await loadEntities(EntityKind.items, q: '10', gameDicts: dicts);
      expect(byId.single.name, '面包');
    });

    test('MOD 记录覆盖同 id 的名称', () async {
      _offline();
      final items = await loadEntities(
        EntityKind.items,
        gameDicts: dicts,
        modRecords: {
          '101': {'name': '法棍'},
        },
      );
      expect(items.firstWhere((e) => e.id == '101').name, '法棍');
    });

    test('人物优先走后端 /api/roles（带立绘 key）', () async {
      ApiClient.instance.client = MockClient((req) async {
        expect(req.url.path, '/api/roles');
        return _roles([
          {'id': 10, 'name': '林晓', 'portrait': 'role_10'},
        ]);
      });
      final roles = await loadEntities(EntityKind.roles, gameDicts: dicts);
      expect(roles.single.id, '10');
      expect(roles.single.thumbKey, 'role_10');
    });

    test('字典缺失 → 空表（面板出空态，不崩）', () async {
      _offline();
      expect(await loadEntities(EntityKind.maps, gameDicts: const {}), isEmpty);
    });
  });

  group('loadRoles 兜底', () {
    test('后端不可达返回空表（不抛）', () async {
      _offline();
      expect(await loadRoles(''), isEmpty);
    });

    test('RoleEntry 容忍字符串 id 与缺字段', () {
      final r = RoleEntry.fromJson(const {'id': '-1', 'gender': 2, 'portrait': 'p'});
      expect(r.id, '-1');
      expect(r.name, '');
      expect(r.gender, 2);
      expect(r.portrait, 'p');
    });
  });

  group('人物立绘候选链（首屏不加载立绘回归）', () {
    final dicts = <String, dynamic>{
      'roles': {'10': '林晓', '-1': '旁白'},
    };

    tearDown(() {
      ApiClient.instance.client = http.Client();
      debugResetMergedMetaCache();
    });

    test('portrait2 → portrait1 → portrait；别名 00 / 000 回退主角 0', () async {
      ApiClient.instance.client = MockClient((req) async {
        expect(req.url.path, '/api/roles');
        return _roles([
          {'id': '0', 'name': '白雨', 'portrait': 'role_0', 'portrait2': 'role_0b'},
          {
            'id': '10',
            'name': '主角',
            'portrait': 'role_10',
            'portrait1': 'role_10a',
            'portrait2': 'role_10b',
          },
          {'id': '00', 'name': '主角(别名)'},
        ]);
      });
      final roles = await loadEntities(EntityKind.roles, gameDicts: dicts);
      final r10 = roles.firstWhere((e) => e.id == '10');
      expect(r10.thumbCandidates, ['role_10b', 'role_10a', 'role_10']);
      expect(r10.thumbKey, 'role_10b', reason: '变体优先，thumbKey 取候选链首项');
      final alias = roles.firstWhere((e) => e.id == '00');
      expect(alias.thumbCandidates, ['role_0b', 'role_0'],
          reason: '别名无独立立绘时应复用主角 0 的候选');
    });

    test('后端不可达：MOD 记录 url2/url 兜底出候选', () async {
      _offline();
      final roles = await loadEntities(
        EntityKind.roles,
        gameDicts: dicts,
        modRecords: {
          '10': {'name': '林晓', 'url2': 'role_10b', 'url': 'role_10a'},
        },
      );
      final r10 = roles.firstWhere((e) => e.id == '10');
      expect(r10.thumbCandidates, ['role_10b', 'role_10a']);
      expect(r10.thumbKey, 'role_10b');
    });

    test('后端不可达：合并元数据 charKeys（base2/base）兜底出候选', () async {
      debugResetMergedMetaCache();
      ApiClient.instance.client = MockClient((req) async {
        if (req.url.path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({
              'bgKeys': {'100': 'bg_x'},
              'charKeys': {
                '10': {'base2': 'role_10b', 'base': 'role_10a'},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        throw http.ClientException('connection refused'); // /api/roles 不可达
      });
      await refreshBgIdKeyMap(); // 填充 charKeys 缓存
      final roles = await loadEntities(EntityKind.roles, gameDicts: dicts);
      final r10 = roles.firstWhere((e) => e.id == '10');
      expect(r10.thumbCandidates, ['role_10b', 'role_10a']);
    });
  });

  group('人物网格首屏立绘', () {
    tearDown(() {
      ApiClient.instance.client = http.Client();
      debugResetMergedMetaCache();
      TexBytesCache.clear();
    });

    testWidgets('打开人物选择器：首屏卡片即挂载 TexThumb，不退化为占位人形图标', (tester) async {
      debugResetMergedMetaCache();
      TexBytesCache.clear();
      ApiClient.instance.client = MockClient((req) async {
        if (req.url.path == '/api/roles') {
          return _roles([
            for (var i = 0; i < 24; i++)
              {'id': '$i', 'name': '角色$i', 'portrait': 'role_$i'},
          ]);
        }
        if (req.url.path == '/api/preview/meta') {
          return http.Response(
            jsonEncode({'bgKeys': {'100': 'bg_x'}, 'charKeys': <String, dynamic>{}}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });

      await tester.pumpWidget(fluent.FluentApp(
        theme: fluent.FluentThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: fluent.Button(
                child: const Text('open'),
                onPressed: () =>
                    showEntityPicker(ctx, kind: EntityKind.roles, multi: false),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(TexThumb), findsWidgets,
          reason: '首屏卡片应直接挂载 TexThumb（无需滚动触发重建）');
      expect(find.byIcon(Icons.person_outline), findsNothing,
          reason: '有立绘的卡片不应退化为占位人形图标');
      expect(tester.takeException(), isNull);
      // 排空贴图请求可能残留的定时器。
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
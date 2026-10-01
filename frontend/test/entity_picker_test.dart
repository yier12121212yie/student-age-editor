// 通用实体浏览面板的纯逻辑：字段规则 → 实体种类映射、零请求字典候选
// （数字序 / List 值取首元素）、MOD 名覆盖、以及后端不可达时的字典回退。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/nocode/entity_picker.dart';

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
}
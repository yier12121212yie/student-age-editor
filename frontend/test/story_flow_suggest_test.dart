/// 剧情图字段候选来源的纯函数回归。
///
/// 这个文件要钉住的是「候选从哪来」——三条都会静默出错的路径：
/// 名称走网络（离线就没候选）、舞台内引用去查 `/api/cfg_ids`（该接口硬截断
/// 500 行，而原版 TalkCfg 约 9.8 万行，结果就是下一句查无候选）、
/// 以及 effectLike 字段漏传 mode（拿到一整列不对味的候选）。
/// 全部不起 Widget：来源本身是注入依赖上的纯函数。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/core/models.dart';
import 'package:student_age_editor/features/editor/field_meta.dart';
import 'package:student_age_editor/features/editor/suggestion_text_field.dart';
import 'package:student_age_editor/features/story/story_flow_suggest.dart';

/// 与 workspace 一致的元数据取法：规则由 field_meta 单一真源给，测试不手搓规则。
FieldMeta metaFor(String cfg, String key, String type) {
  final effectLike = isEffectLikeField(cfg, key, type);
  return FieldMeta(
    key: key,
    type: type,
    label: key,
    section: 'common',
    effectLike: effectLike,
    suggestMode: effectLike ? effectSuggestMode(key) : null,
    multivalued: type == '1D Array' || type == '2D Array',
    rule: fieldRuleFor(cfg, key),
  );
}

SuggestionQuery q(String token) =>
    SuggestionQuery(token: token, cursor: token.length, text: token);

/// Suggestion 是值语义但没重载 ==，断言一律拆成 code / desc 两列。
List<String> codes(List<Suggestion> got) => got.map((s) => s.code).toList();
List<String> descs(List<Suggestion> got) => got.map((s) => s.desc).toList();

void main() {
  late AppState state;
  late List<String> offStageCalls;
  late List<String> httpCalls;
  late List<Map<String, dynamic>> stageTalks;
  late List<Map<String, dynamic>> stageOpts;
  late Map<String, Map<String, dynamic>> modTables;
  late List<(String, String)> offStageResult;
  late bool offStageThrows;

  /// 一次 sourceForField 的公共脚手架：舞台内表与舞台外加载器都可观测。
  FlowSuggestDeps deps() => FlowSuggestDeps(
    state: state,
    stageTalks: () => stageTalks,
    stageOptions: () => stageOpts,
    offStageIds: (cfg) async {
      offStageCalls.add(cfg);
      if (offStageThrows) throw Exception('离线');
      return offStageResult;
    },
    modTable: (cfg) => modTables[cfg],
  );

  /// 默认桩：任何打到网络的请求都记进 [httpCalls] 并报 500，
  /// 本地来源「一次都不该碰网络」因此可断言。
  void stubOfflineBackend() {
    ApiClient.instance.client = MockClient((request) async {
      httpCalls.add(request.url.path);
      return http.Response(
        jsonEncode({'error': 'unexpected ${request.url.path}'}),
        500,
        headers: {'content-type': 'application/json'},
      );
    });
  }

  /// 换上一个只回 effect_suggest 的桩，并把 query 参数暴露给断言。
  void stubEffect(
    Map<String, dynamic>? Function(Map<String, String> query) items,
  ) {
    ApiClient.instance.client = MockClient((request) async {
      httpCalls.add(request.url.path);
      final body = items(request.url.queryParameters);
      return http.Response(
        jsonEncode(body ?? {'items': []}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }

  setUp(() {
    state = AppState()..modName = 'Suggest';
    offStageCalls = [];
    httpCalls = [];
    stageTalks = [];
    stageOpts = [];
    modTables = {};
    offStageResult = const [];
    offStageThrows = false;
    stubOfflineBackend();
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  group('本地名称字典（零请求）', () {
    test('Mod 记录覆盖原版同名 id，并补上原版没有的新条目', () async {
      state.gameDicts = {
        'roles': {'1': '张三', '2': '李四', '0': '无'},
      };
      modTables['PersonCfg'] = {
        '1': {'name': '张三（Mod 改名）'},
        '20': {'name': '新角色'},
      };
      final src = sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'roleIds', '1D Array'),
        deps(),
      );
      expect(src, isNotNull);
      final got = await src!(q(''));
      expect(codes(got), ['1', '2', '20']);
      expect(
        got.first.desc,
        '张三（Mod 改名）',
        reason: '合并次序先原版后 Mod：Mod 记录赢（同 story_director 的 _allRoles）',
      );
      expect(
        codes(got),
        isNot(contains('0')),
        reason: '原版 roles 的「无角色」哨兵不是可选对象',
      );
      expect(httpCalls, isEmpty, reason: '名称一律读缓存字典，不许为补全发请求');
      expect(offStageCalls, isEmpty);
    });

    test('字典值可能是 List，首元素才是展示名', () async {
      state.gameDicts = {
        'roles': {
          '7': ['王五', 'face_7.png'],
        },
      };
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'roleIds', '1D Array'),
        deps(),
      )!(q('王'));
      expect(got.single.desc, '王五');
    });

    test('缺名的 Mod 角色退回「角色 N」，且不覆盖原版已有名', () {
      state.gameDicts = {
        'roles': {'1': '张三'},
      };
      final merged = mergeNameDict(
        state: state,
        dictName: 'roles',
        modRecords: {
          '1': {'name': ''},
          '9': {'title': '只有 title'},
        },
      );
      expect(merged['1'], '张三', reason: 'Mod 记录没名字时不能把原版名擦掉');
      expect(merged['9'], '角色 9');
    });

    test('bg / audio 各映射到对应 Mod 表做覆盖，且不再打舞台外加载器', () async {
      state.gameDicts = {
        'bgs': {'11': '教室'},
        'audios': {'21': '钢琴曲'},
      };
      modTables['BgCfg'] = {
        '11': {'name': '教室（改）'},
      };
      modTables['AudioCfg'] = {
        '21': {'name': '钢琴曲（改）'},
      };
      final bg = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'bg', 'String'),
        deps(),
      )!(q(''));
      final audio = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'audio', '1D Array'),
        deps(),
      )!(q(''));
      expect(bg.single.desc, '教室（改）');
      expect(audio.single.desc, '钢琴曲（改）');
      expect(
        offStageCalls,
        isEmpty,
        reason: 'audio 同时带 idRefCfg:AudioCfg，字典已含全量 id→名称，再打加载器是多余请求',
      );
      expect(httpCalls, isEmpty);
    });

    test('宿主没给 modTable 时仍能用原版字典（可选依赖不炸）', () async {
      state.gameDicts = {
        'maps': {'3': '学校'},
      };
      final bare = FlowSuggestDeps(
        state: state,
        stageTalks: () => const [],
        stageOptions: () => const [],
        offStageIds: (_) async => const [],
      );
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'map', 'Number'),
        bare,
      )!(q(''));
      expect(codes(got), ['3']);
    });
  });

  group('舞台内 ID 引用：只扫内存', () {
    test('nextTalk 候选来自注入的舞台对白，且不碰网络与 cfg_ids', () async {
      stageTalks = [
        {'id': 1000001000, 'content': '甲'},
        {'id': 1000001001, 'content': '乙'},
        {'id': 1000001002}, // 无名记录
      ];
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'nextTalk', '1D Array'),
        deps(),
      )!(q(''));
      expect(codes(got), ['1000001000', '1000001001', '1000001002']);
      expect(got[0].desc, '甲');
      expect(got[2].desc, '', reason: 'entryName 的 `#id` 不是预览文本，还原成空');
      expect(httpCalls, isEmpty);
      expect(offStageCalls, isEmpty, reason: '舞台内引用走 /api/cfg_ids 会被 500 行截断');
    });

    test('/api/cfg_ids 的 500 行截断在舞台内不适用：第 600 条仍可选', () async {
      stageTalks = [
        for (var i = 0; i < 600; i++) {'id': 1000001000 + i, 'content': '台词$i'},
      ];
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'nextTalk', '1D Array'),
        deps(),
      )!(q('1000001599'));
      expect(codes(got), ['1000001599']);
      expect(got.single.desc, '台词599');
    });

    test('option 字段扫舞台内选项表，而不是对白表', () async {
      stageTalks = [
        {'id': 1000001000, 'content': '甲'},
      ];
      stageOpts = [
        {'id': 1000001500, 'content': '去小卖部'},
      ];
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'option', '1D Array'),
        deps(),
      )!(q('去'));
      expect(codes(got), ['1000001500']);
    });

    test('预览按 name>title>content 取值并截到 20 字（同后端 cfg_ids 规则）', () async {
      stageTalks = [
        {'id': 1, 'name': '有名', 'content': '忽略'},
        {'id': 2, 'title': '有题'},
        {'id': 3, 'content': '一二三四五六七八九十一二三四五六七八九十一二三'},
      ];
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'nextTalk', '1D Array'),
        deps(),
      )!(q(''));
      expect(descs(got), ['有名', '有题', '一二三四五六七八九十一二三四五六七八九十']);
    });

    test('中文按 desc 命中、数字按 code 命中', () async {
      stageTalks = [
        {'id': 12345, 'content': '张三的台词'},
        {'id': 999, 'content': '旁白'},
      ];
      final src = sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'nextTalk', '1D Array'),
        deps(),
      )!;
      expect(codes(await src(q('张三'))), ['12345']);
      expect(codes(await src(q('123'))), ['12345']);
      expect(codes(await src(q('99'))), ['999']);
    });

    test('本地候选有上限，浮层不被上万行塞满', () async {
      stageTalks = [
        for (var i = 0; i < 200; i++) {'id': 1000 + i, 'content': '台词'},
      ];
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'nextTalk', '1D Array'),
        deps(),
      )!(q('台词'));
      expect(got.length, kFlowSuggestLimit);
    });
  });

  group('舞台外 ID 引用', () {
    test('nextEvtId 走 offStageIds("EvtCfg")，候选为 (id, preview)', () async {
      offStageResult = const [('3001', '雨天事件'), ('3002', '考试事件')];
      final got = await sourceForField(
        'OptionCfg',
        metaFor('OptionCfg', 'nextEvtId', 'Number'),
        deps(),
      )!(q('雨天'));
      expect(offStageCalls, ['EvtCfg']);
      expect(codes(got), ['3001']);
      expect(got.single.desc, '雨天事件');
    });

    test('talkId2 仍属舞台内，不该去问 offStageIds', () async {
      stageTalks = [
        {'id': 1000001000, 'content': '甲'},
      ];
      final got = await sourceForField(
        'OptionCfg',
        metaFor('OptionCfg', 'talkId2', 'Number'),
        deps(),
      )!(q('甲'));
      expect(offStageCalls, isEmpty);
      expect(codes(got), ['1000001000']);
    });

    test('miniGame 走 offStageIds("MinigameCfg")', () async {
      offStageResult = const [('9', '拍苍蝇')];
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'miniGame', 'Number'),
        deps(),
      )!(q('9'));
      expect(offStageCalls, ['MinigameCfg']);
      expect(codes(got), ['9']);
    });

    test('加载器抛错时退化为空候选，不把异常抛进浮层', () async {
      offStageThrows = true;
      final got = await sourceForField(
        'OptionCfg',
        metaFor('OptionCfg', 'nextEvtId', 'Number'),
        deps(),
      )!(q('3'));
      expect(got, isEmpty);
    });
  });

  group('effectLike 字段走后端码表', () {
    test('check 透传 mode=condition，token 原样当 q', () async {
      Map<String, String>? query;
      stubEffect((params) {
        query = params;
        return {
          'items': [
            {'desc': '金钱大于', 'code': '1,2'},
            {'desc': '缺码项应被丢掉', 'code': ''},
            '不是对象也应被丢掉',
          ],
        };
      });
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'check', '2D Array'),
        deps(),
      )!(q('金钱大于'));
      expect(query, {'q': '金钱大于', 'mode': 'condition'});
      expect(codes(got), ['1,2']);
      expect(descs(got), ['金钱大于']);
    });

    test('screenEffect → mode=screen，roles → mode=action', () async {
      final modes = <String?>[];
      stubEffect((query) {
        modes.add(query['mode']);
        return {'items': []};
      });
      await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'screenEffect', '1D Array'),
        deps(),
      )!(q('抖动'));
      await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'roles', '2D Array'),
        deps(),
      )!(q('走路'));
      expect(modes, ['screen', 'action']);
    });

    test('后端报错时返回空候选，不抛', () async {
      final got = await sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'effect', '2D Array'),
        deps(),
      )!(q('加钱'));
      expect(got, isEmpty);
      expect(httpCalls, ['/api/effect_suggest'], reason: '确实打了一次码表，且失败被吞');
    });

    test('actions 字典不在 game_dicts 里，改走码表 mode=action', () async {
      final modes = <String?>[];
      stubEffect((query) {
        modes.add(query['mode']);
        return {'items': []};
      });
      final src = sourceForField(
        'TalkCfg',
        metaFor('TalkCfg', 'action', '1D Array'),
        deps(),
      );
      expect(src, isNotNull);
      await src!(q('走路'));
      expect(modes, ['action']);
    });
  });

  group('取舍与合并', () {
    test('普通 String / Number 字段返回 null（退化成普通输入框）', () {
      expect(
        sourceForField(
          'TalkCfg',
          metaFor('TalkCfg', 'content', 'String'),
          deps(),
        ),
        isNull,
      );
      expect(
        sourceForField('TalkCfg', metaFor('TalkCfg', 'time', 'Number'), deps()),
        isNull,
      );
      expect(
        sourceForField(
          'TalkCfg',
          metaFor('TalkCfg', 'roleName', 'String'),
          deps(),
        ),
        isNull,
      );
      expect(httpCalls, isEmpty);
      expect(offStageCalls, isEmpty);
    });

    test('既没规则也没被判 effectLike 的 2D 指令字段仍走码表，不退化成裸文本框', () async {
      final modes = <String?>[];
      stubEffect((query) {
        modes.add(query['mode']);
        return {'items': []};
      });
      // 手搓一条 field_meta 目前认不出来的指令字段：兜底路径不依赖 isEffectLikeField
      // 的 key 清单（那张清单归 field_meta 管，随时会加长）。
      const meta = FieldMeta(
        key: 'stateCondX',
        type: '2D Array',
        label: '状态要求X',
        section: 'advanced',
      );
      expect(meta.effectLike, isFalse);
      expect(meta.rule, isNull);
      final src = sourceForField('OptionCfg', meta, deps());
      expect(src, isNotNull, reason: '2D 指令字段变裸文本框 = 全角逗号绕过校验进存档');
      await src!(q('状态'));
      expect(modes, ['effect']);
      expect(offStageCalls, isEmpty);
    });

    test('stateCond 无论被判成哪一类都有候选（不许落到 null）', () async {
      final meta = metaFor('OptionCfg', 'stateCond', '2D Array');
      expect(
        sourceForField('OptionCfg', meta, deps()),
        isNotNull,
        reason: '它是 2D 指令字段：effectLike 或 2D 兜底，两条路任一都得给候选',
      );
    });

    test('固定枚举来自 rule.fixed，不发请求', () async {
      final got = await sourceForField(
        'EvtCfg',
        metaFor('EvtCfg', 'displayType', 'Number'),
        deps(),
      )!(q(''));
      expect(codes(got), ['0', '1']);
      expect(descs(got), ['默认形式', '弹窗形式']);
      expect(httpCalls, isEmpty);
      expect(offStageCalls, isEmpty);
    });

    test('composeSources 按 code 去重且先到先得', () async {
      Future<List<Suggestion>> head(SuggestionQuery _) async => [
        const Suggestion('1', '甲'),
        const Suggestion('2', '乙'),
      ];
      Future<List<Suggestion>> tail(SuggestionQuery _) async => [
        const Suggestion('2', '乙2'),
        const Suggestion('3', '丙'),
      ];
      final got = await composeSources([head, tail])(q(''));
      expect(codes(got), ['1', '2', '3']);
      expect(
        got.firstWhere((s) => s.code == '2').desc,
        '乙',
        reason: '去重先到先得：前面的来源优先',
      );
    });

    test('composeSources 中一路抛错不影响其余来源', () async {
      Future<List<Suggestion>> boom(SuggestionQuery _) async =>
          throw Exception('字典读歪了');
      Future<List<Suggestion>> ok(SuggestionQuery _) async => [
        const Suggestion('7', '吉'),
      ];
      final got = await composeSources([boom, ok])(q(''));
      expect(codes(got), ['7']);
      expect(await composeSources(const [])(q('abc')), isEmpty);
    });
  });

  group('来源实例记忆化（宿主重建不得清掉开着的候选浮层）', () {
    test('同一 deps 内同一 (cfg, meta) 恒返回同一实例', () {
      final d = deps();
      final m = metaFor('TalkCfg', 'nextTalk', '1D Array');
      expect(
        identical(d.sourceForField('TalkCfg', m), d.sourceForField('TalkCfg', m)),
        isTrue,
        reason:
            'identical 不成立时 SuggestionTextField.didUpdateWidget 会 clearCandidates，'
            '宿主一次重建就把用户正开着的浮层悄悄关掉',
      );
      // 顶层入口与实例方法共享同一份缓存
      expect(
        identical(sourceForField('TalkCfg', m, d), d.sourceForField('TalkCfg', m)),
        isTrue,
      );
    });

    test('不同 (cfg, meta) 返回不同实例', () {
      final d = deps();
      final a = d.sourceForField('TalkCfg', metaFor('TalkCfg', 'nextTalk', '1D Array'));
      final b = d.sourceForField('OptionCfg', metaFor('OptionCfg', 'talkId', 'Number'));
      final c = d.sourceForField('TalkCfg', metaFor('TalkCfg', 'bg', 'String'));
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(c, isNotNull);
      expect(identical(a, b), isFalse);
      expect(identical(a, c), isFalse);
      expect(identical(b, c), isFalse);
    });

    test('返回 null 的字段同样被缓存，重复解析不炸也不翻面', () {
      final d = deps();
      final m = metaFor('TalkCfg', 'content', 'String');
      expect(d.sourceForField('TalkCfg', m), isNull);
      expect(d.sourceForField('TalkCfg', m), isNull);
    });

    test('记忆化只固定来源实例，不冻结候选内容（每次查询仍重扫舞台）', () async {
      final d = deps();
      final src = d.sourceForField('TalkCfg', metaFor('TalkCfg', 'nextTalk', '1D Array'));
      expect(src, isNotNull);
      stageTalks.add({'id': 1000001000, 'content': '甲'});
      expect(codes(await src!(q(''))), ['1000001000']);
      stageTalks.add({'id': 1000001001, 'content': '乙'});
      expect(
        codes(await src(q(''))),
        ['1000001000', '1000001001'],
        reason: '缓存的是来源闭包而非查询结果：保存后长出的新台词必须立刻可选',
      );
    });
  });
}

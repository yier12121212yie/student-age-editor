import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/ai/ai_skills.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  group('AiSkillStore.parseFile', () {
    test('有 frontmatter：解析 name/description，body 去掉围栏', () {
      final s = AiSkillStore.parseFile(
        'story.md',
        '---\r\nname: 剧情扩写\r\ndescription: 按风格扩写事件\r\n---\r\n\r\n请扩写剧情 {{event}}\r\n',
        fromMod: false,
      );
      expect(s, isNotNull);
      expect(s!.name, '剧情扩写');
      expect(s.description, '按风格扩写事件');
      expect(s.body, '请扩写剧情 {{event}}');
      expect(s.fromMod, false);
      expect(s.id, 'workspace/story.md');
    });

    test('无 frontmatter：name=文件名去扩展名、description=正文首行截 60 字', () {
      final firstLine = 'a' * 80;
      final s = AiSkillStore.parseFile(
        'my_skill.txt.md',
        '$firstLine\n第二行',
        fromMod: true,
      );
      expect(s, isNotNull);
      expect(s!.name, 'my_skill.txt');
      expect(s.description, 'a' * 60);
      expect(s.body, '$firstLine\n第二行');
      expect(s.fromMod, true);
      expect(s.id, 'mod/my_skill.txt.md');
    });

    test('坏 frontmatter：围栏未闭合 → 整文按正文容错解析', () {
      final s = AiSkillStore.parseFile('bad.md', '---\nname: 未闭合\n正文', fromMod: false);
      expect(s, isNotNull);
      expect(s!.name, 'bad');
      expect(s.body, '---\nname: 未闭合\n正文');
    });

    test('frontmatter 缺字段：逐字段回退', () {
      final s = AiSkillStore.parseFile(
        'e.md',
        '---\nauthor: someone\n---\n正文首行\n第二行',
        fromMod: false,
      );
      expect(s, isNotNull);
      expect(s!.name, 'e');
      expect(s.description, '正文首行');
      expect(s.body, '正文首行\n第二行');
    });

    test('正文为空返回 null', () {
      expect(AiSkillStore.parseFile('x.md', '', fromMod: false), isNull);
      expect(
        AiSkillStore.parseFile('x.md', '---\nname: n\n---\n  \n', fromMod: false),
        isNull,
      );
    });

    test('常量：目录名与缓存时长', () {
      expect(AiSkillStore.dirName, '.editor_skills');
      expect(AiSkillStore.cacheTtl, const Duration(seconds: 30));
    });
  });

  group('AiSkillStore.filterQuery', () {
    final a = AiSkill(
      id: 'workspace/a.md',
      name: '剧情扩写',
      description: '按风格扩写事件',
      body: 'A',
      fromMod: false,
    );
    final b = AiSkill(
      id: 'mod/talk.md',
      name: 'Talk',
      description: '生成台词对话',
      body: 'B',
      fromMod: true,
    );
    final all = [a, b];

    test('空 query 返回全部', () {
      expect(AiSkillStore.filterQuery(all, ''), hasLength(2));
    });

    test('按 name 匹配（大小写不敏感）', () {
      expect(AiSkillStore.filterQuery(all, 'tal'), [b]);
      expect(AiSkillStore.filterQuery(all, '剧情'), [a]);
    });

    test('按 description 匹配', () {
      expect(AiSkillStore.filterQuery(all, '对话'), [b]);
    });

    test('无匹配返回空', () {
      expect(AiSkillStore.filterQuery(all, 'zzz'), isEmpty);
    });
  });

  group('AiSkillStore.load（MockClient）', () {
    test('workspace 与 mod 合并、mod 覆盖全局同名、跳过目录/非 md/读取失败', () async {
      final contents = <String, String>{
        'workspace:.editor_skills/alpha.md': '---\nname: 共享技能\ndescription: 全局版\n---\n全局正文',
        'mod:.editor_skills/alpha.md': '---\nname: 共享技能\ndescription: 模组版\n---\n模组正文',
        'mod:.editor_skills/beta.md': '模组 B 技能首行',
      };
      ApiClient.instance.client = MockClient((req) async {
        final scope = req.url.queryParameters['scope'];
        if (req.url.path == '/api/tools/list') {
          final entries = scope == 'workspace'
              ? [
                  {'name': 'alpha.md', 'type': 'file'},
                  {'name': 'sub', 'type': 'dir'}, // 跳过：目录
                  {'name': 'x.txt', 'type': 'file'}, // 跳过：非 md
                ]
              : [
                  {'name': 'alpha.md', 'type': 'file'},
                  {'name': 'beta.md', 'type': 'file'},
                  {'name': 'gamma.md', 'type': 'file'}, // 跳过：读取 404
                  {'name': 'bin.md', 'type': 'file'}, // 跳过：text=null
                ];
          return _json({'entries': entries});
        }
        if (req.url.path == '/api/tools/read') {
          final key = '$scope:${req.url.queryParameters['path']}';
          if (contents.containsKey(key)) return _json({'text': contents[key]});
          if (key == 'mod:.editor_skills/bin.md') return _json({'text': null});
          return _json({'error': 'not found'}, 404);
        }
        return _json({});
      });

      final list = await AiSkillStore().load();
      expect(list, hasLength(2), reason: '共享技能 + beta，其余条目静默跳过');
      final shared = list.where((s) => s.name == '共享技能').toList();
      expect(shared, hasLength(1), reason: '同名合并为一条');
      expect(shared.single.fromMod, isTrue, reason: 'mod 覆盖全局');
      expect(shared.single.description, '模组版');
      expect(shared.single.body, '模组正文');
      final beta = list.firstWhere((s) => s.name != '共享技能');
      expect(beta.id, 'mod/beta.md');
      expect(beta.body, '模组 B 技能首行');

      // 仅全局：includeMod=false 时同名技能取 workspace 版
      final globalOnly = await AiSkillStore().load(includeMod: false);
      expect(globalOnly, hasLength(1));
      expect(globalOnly.single.name, '共享技能');
      expect(globalOnly.single.fromMod, isFalse);
      expect(globalOnly.single.body, '全局正文');
    });

    test('30s 内存缓存与 invalidate', () async {
      var listCalls = 0;
      ApiClient.instance.client = MockClient((req) async {
        if (req.url.path == '/api/tools/list') listCalls++;
        return _json({'entries': []});
      });
      final store = AiSkillStore();
      await store.load(); // workspace + mod 各 1 次
      await store.load(); // 命中缓存，不发请求
      expect(listCalls, 2);
      store.invalidate();
      await store.load();
      expect(listCalls, 4);
    });

    test('后端失败静默返回空列表', () async {
      ApiClient.instance.client = MockClient(
        (req) async => _json({'error': 'boom'}, 500),
      );
      expect(await AiSkillStore().load(), isEmpty);
    });
  });
}

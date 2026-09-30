// 移动端剧情数据层回归：详情走 ?prefix= 小批量、二次进入命中缓存不再拉表、
// 保存后该事件批次失效（下次进入重拉）。这是手机端头号卡顿源的行为锁。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_age_editor/core/api_client.dart';
import 'package:student_age_editor/features/story/story_editor_mobile.dart';

void main() {
  late List<Uri> cfgReqs;

  setUp(() {
    cfgReqs = [];
    StoryDataAccess().debugClearCache();
    ApiClient.instance.client = MockClient((req) async {
      cfgReqs.add(req.url);
      final path = req.url.path;
      final m = RegExp(r'^/api/cfg/(.+)$').firstMatch(path);
      if (m != null) {
        final name = m.group(1)!;
        // 断言口径：TalkCfg/OptionCfg 必须带 prefix（不允许无参全表请求）。
        final data = switch (name) {
          'EvtCfg' => {
              '101': {
                'id': 101,
                'title': '测试事件',
                'talkId': [101001]
              },
            },
          'TalkCfg' => {
              '101001': {
                'id': 101001,
                'roleName': '角色A',
                'content': '你好',
                'nextTalk': [101002]
              },
              '101002': {
                'id': 101002,
                'roleName': '角色B',
                'content': '再见'
              },
              '202001': {
                'id': 202001,
                'content': '别的事件的对白'
              },
            },
          'OptionCfg' => {
              // 选项 ID = 事件 ID + 2 位序号（每事件上限 99 个）
              '10101': {'id': 10101, 'text': '选项一', 'talkId': [101002]},
              '20201': {'id': 20201, 'text': '别的事件的选项'},
            },
          _ => <String, dynamic>{},
        };
        return http.Response.bytes(
            utf8.encode(jsonEncode({'data': data, 'mtime_ns': 7})), 200,
            headers: {'content-type': 'application/json'});
      }
      if (path == '/api/story/event/save') {
        return http.Response.bytes(
            utf8.encode(jsonEncode({'success': true})), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"error":"mock 404"}', 404,
          headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() {
    ApiClient.instance.client = http.Client();
  });

  int cfgCount(String table) =>
      cfgReqs.where((u) => u.path == '/api/cfg/$table').length;

  test('详情只拉该事件的小批量（带 prefix），不误取全表', () async {
    await StoryDataAccess()
        .loadEventDetails(modName: 'm', eventId: '101');
    final talk = cfgReqs.firstWhere((u) => u.path == '/api/cfg/TalkCfg');
    expect(talk.queryParameters['prefix'], contains('101'));
    final opt = cfgReqs.firstWhere((u) => u.path == '/api/cfg/OptionCfg');
    expect(opt.queryParameters['prefix'], contains('101'));
    expect(opt.queryParameters['suffix'], '2');
  });

  test('同事件二次进入命中缓存，不再发 TalkCfg/OptionCfg 请求', () async {
    final first = await StoryDataAccess()
        .loadEventDetails(modName: 'm', eventId: '101');
    expect(first.talks.map((t) => t.id), containsAll(['101001', '101002']));
    // 他事件的对白（202001）即使被 mock 一起返回，也已被 matcher 过滤
    expect(first.talks.map((t) => t.id), isNot(contains('202001')));
    expect(cfgCount('TalkCfg'), 1);

    final again = await StoryDataAccess()
        .loadEventDetails(modName: 'm', eventId: '101');
    expect(again.talks.length, first.talks.length);
    expect(cfgCount('TalkCfg'), 1, reason: '第二次应命中缓存');
  });

  test('保存后该事件缓存失效，重进会重新拉取', () async {
    final da = StoryDataAccess();
    final first = await da.loadEventDetails(modName: 'm', eventId: '101');
    expect(cfgCount('TalkCfg'), 1);

    final ok = await da.saveEvent(
        modName: 'm', eventId: '101', talks: first.talks, options: first.options);
    expect(ok, isTrue);

    await da.loadEventDetails(modName: 'm', eventId: '101');
    expect(cfgCount('TalkCfg'), 2, reason: '保存后磁盘与缓存已分叉，应重拉');
  });

  test('不同事件各自独立拉取，不共享错误的缓存判定', () async {
    await StoryDataAccess().loadEventDetails(modName: 'm', eventId: '101');
    await StoryDataAccess().loadEventDetails(modName: 'm', eventId: '102');
    expect(cfgCount('TalkCfg'), 2);
  });
}

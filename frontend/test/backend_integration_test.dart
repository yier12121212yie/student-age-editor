// 端到端集成测试：连接真实 Python 后端（需先在 127.0.0.1:8765 启动 editor.server）。
// 覆盖前端 bootstrap 流程与核心只读工作流。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/api_client.dart';

void main() {
  setUpAll(() {
    ApiClient.instance.baseUrl = 'http://127.0.0.1:8765';
  });

  test('bootstrap: ping/state/schema/dicts', () async {
    final ping = await ApiClient.instance.get('/api/ping');
    expect(ping['ok'], true);

    final state = await ApiClient.instance.get('/api/state');
    expect(state['mods'], isA<List>());
    expect(state['workspace_root'], isNotEmpty);

    final schema = await ApiClient.instance.get('/api/schema');
    expect(schema['game_schema'], contains('EvtCfg'));
    expect(schema['game_schema'], contains('PersonCfg'));

    final dicts = await ApiClient.instance.get('/api/dicts');
    expect(dicts['key_maps'], contains('EvtCfg'));
    expect(dicts['game_dicts'], contains('roles'));
  });

  test('mod select + cfg read（只读，不写真实模组）', () async {
    final state = await ApiClient.instance.get('/api/state');
    final mods = (state['mods'] as List).cast<Map<String, dynamic>>();
    if (mods.isEmpty) {
      markTestSkipped('无模组可测');
      return;
    }
    final first = mods.first;
    final sel = await ApiClient.instance.post('/api/mods/select',
        body: {'name': first['name']});
    expect(sel['mod']['name'], first['name']);

    final files = await ApiClient.instance.get('/api/cfg');
    final cfgFiles = (files['cfg_files'] as List).cast<String>();
    expect(cfgFiles, isNotEmpty);
    if (cfgFiles.isEmpty) {
      markTestSkipped('模组无 cfg');
      return;
    }
    final cfg = await ApiClient.instance.get('/api/cfg/${cfgFiles.first}');
    expect(cfg['data'], isA<Map>());
    expect(cfg['keys'], isA<List>());
  });

  test('AI 工具只读：list_files / read_file（mod 沙箱）', () async {
    final state = await ApiClient.instance.get('/api/state');
    if ((state['mod_root'] as String? ?? '').isEmpty) {
      markTestSkipped('未选择模组');
      return;
    }
    final list = await ApiClient.instance.get('/api/tools/list',
        query: {'scope': 'mod', 'path': ''});
    expect(list['entries'], isA<List>());

    // 读取一个真实 cfg 文件（只读）
    final cfg = await ApiClient.instance.get('/api/cfg');
    final files = (cfg['cfg_files'] as List).cast<String>();
    if (files.isNotEmpty) {
      final rd = await ApiClient.instance.get('/api/tools/read',
          query: {'scope': 'mod', 'path': 'Cfgs/zh-cn/${files.first}.json'});
      expect(rd['text'], contains('{'));
    }
  });

  test('沙箱逃逸被拒绝', () async {
    expect(
      () => ApiClient.instance
          .get('/api/tools/read', query: {'path': '../../Windows/win.ini'}),
      throwsA(isA<ApiException>()),
    );
  });

  test('媒体预览链路：/api/tools/read 返回可解码的 base64（图片/音频）', () async {
    // 对应 FileViewer 的纯前端预览方案：不依赖 /api/tools/raw，仅用 read 的 base64。
    final state = await ApiClient.instance.get('/api/state');
    if ((state['mod_root'] as String? ?? '').isEmpty) {
      markTestSkipped('未选择模组');
      return;
    }
    final list = await ApiClient.instance.get('/api/tools/list',
        query: {'scope': 'mod', 'path': '', 'deep': '1'});
    final entries = (list['entries'] as List).cast<Map<String, dynamic>>();
    final img = entries
        .where((e) => e['type'] == 'file')
        .map((e) => e['name'] as String)
        .where((n) =>
            n.toLowerCase().endsWith('.png') || n.toLowerCase().endsWith('.jpg'))
        .firstOrNull;
    if (img == null) {
      markTestSkipped('模组内无图片文件');
      return;
    }
    final rd = await ApiClient.instance.get('/api/tools/read',
        query: {'scope': 'mod', 'path': img});
    expect(rd['base64'], isA<String>());
    final bytes = base64Decode(rd['base64'] as String);
    // PNG/JPEG 魔数校验：证明前端 Image.memory 能拿到完整图片字节
    final sig = bytes.sublist(0, 4);
    final ok = (sig[0] == 0x89 && sig[1] == 0x50 && sig[2] == 0x4E && sig[3] == 0x47) ||
        (sig[0] == 0xFF && sig[1] == 0xD8);
    expect(ok, true, reason: '$img 魔数校验失败: $sig');
  });

  test('AI 附件上传：txt/md 文本解析 + png 图片 base64', () async {
    // txt
    final txt = await ApiClient.instance.post('/api/ai/upload', body: {
      'name': '说明.txt',
      'data': base64Encode(utf8.encode('你好，AI！\n第二行')),
    });
    expect(txt['kind'], 'text');
    expect(txt['text'], contains('你好'));

    // md
    final md = await ApiClient.instance.post('/api/ai/upload', body: {
      'name': 'readme.md',
      'data': base64Encode(utf8.encode('# 标题\n正文')),
    });
    expect(md['text'], contains('# 标题'));

    // png（构造魔数合法的最小文件）
    final pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0];
    final png = await ApiClient.instance.post('/api/ai/upload', body: {
      'name': '截图.png',
      'data': base64Encode(pngBytes),
    });
    expect(png['kind'], 'image');
    expect(png['mime'], 'image/png');
    expect(base64Decode(png['data'] as String), pngBytes);

    // 非法类型被拒绝
    expect(
      () => ApiClient.instance.post('/api/ai/upload', body: {
        'name': 'bad.exe',
        'data': base64Encode([0x4D, 0x5A]),
      }),
      throwsA(isA<ApiException>()),
    );
  });
}

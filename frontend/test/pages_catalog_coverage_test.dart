// 页面目录守护测试：pages_catalog 声明的每张表必须在 native/assets/schema.json
// 有定义（拼错的表名会让编辑器退化成"按数据扫键"，字段类型与标签全丢）。
// 同时守护页面 id 唯一、primaryCfg 属于 cfgNames、每页有图标之外的基本一致性。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/pages/pages_catalog.dart';

/// 定位仓库根的 native/assets/schema.json：CI 与本地都在 frontend/ 下跑测试，
/// 但个别 IDE 配置可能以仓库根为 cwd，两种都试。
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

  test('页面 id 唯一', () {
    final ids = editorPages.map((p) => p.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'editorPages 存在重复 id');
  });

  test('每页 cfgNames 非空且去重、primaryCfg 在清单内', () {
    for (final p in editorPages) {
      expect(p.cfgNames, isNotEmpty, reason: '${p.id} 没有配置表');
      expect(
        p.cfgNames.toSet().length,
        p.cfgNames.length,
        reason: '${p.id} cfgNames 有重复',
      );
      if (p.primaryCfg != null) {
        expect(
          p.cfgNames,
          contains(p.primaryCfg),
          reason: '${p.id} primaryCfg=${p.primaryCfg} 不在 cfgNames',
        );
      }
    }
  });

  test('每页描述与标题非空', () {
    for (final p in editorPages) {
      expect(p.title.trim(), isNotEmpty, reason: '${p.id} 标题为空');
      expect(p.description.trim(), isNotEmpty, reason: '${p.id} 描述为空');
    }
  });

  test('所有页面声明的表都在 schema.json 中', () {
    final missing = <String>[];
    for (final p in editorPages) {
      // official 页的 ManifestCfg 是模组清单校验，不走 schema 表单渲染。
      if (p.id == 'official') continue;
      for (final cfg in p.cfgNames) {
        final table = schema[cfg];
        if (table is! Map || table.isEmpty) missing.add('${p.id} -> $cfg');
      }
    }
    expect(missing, isEmpty, reason: '以下表在 schema.json 缺失或为空：$missing');
  });

  test('隐藏页不出现在入口列表，但仍可由 id 解析（跳转目标）', () {
    final hidden = editorPages.where((p) => p.hidden).map((p) => p.id).toList();
    expect(hidden, contains('story_studio'),
        reason: '剧情工作台应作为隐藏页，不再占列表入口');
    expect(
      visibleEditorPages.map((p) => p.id),
      isNot(contains('story_studio')),
    );
    // 隐藏页仍须能被 pageById 解析，否则「故事」页的跳转按钮会落到兜底页。
    expect(pageById('story_studio'), isNotNull);
  });
}

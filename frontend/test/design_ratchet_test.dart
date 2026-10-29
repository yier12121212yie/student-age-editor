// 视觉棘轮（R3）：只降不升。
//
// 口径：计「含数字字面量的调用点」，而不是关键词出现次数——
// `fontSize: AppText.body` 仍是 fontSize 用法，但已不是魔法数，不应计入。
//
// 基线 = R3 视觉一致性迁移（design_tokens + 共享组件 + 5 个基建文件）后的
// 实测值。修复方向：把字面量换成语义 token（字号/间距/圆角）或共享组件
// （EmptyState / StatusPill / SectionHeader），数量下降后只把基线调低。
//
// 颜色棘轮：`app_theme.dart`（调色板唯一来源）之外禁止新增十六进制色值，
// 白名单按「文件 -> 允许上限」登记，只减不增。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _fontSizeBaseline = 1442;
const _boxBaseline = 1591;
const _insetsBaseline = 941;
const _radiusBaseline = 402;

/// app_theme.dart 之外的十六进制色值白名单（R3 迁移时实测；只减不增）。
const _colorWhitelist = <String, int>{
  'lib/features/preview/event_preview_view.dart': 2,
  'lib/features/settings/mcp_token_section.dart': 1,
  'lib/features/settings/settings_page.dart': 12,
  'lib/features/settings/update_section.dart': 1,
  'lib/features/story/story_flow_graph.dart': 1,
  'lib/features/story/story_flow_side_toolbar.dart': 1,
  'lib/features/story/story_studio_editor.dart': 2,
};

Iterable<File> _libFiles() =>
    Directory('lib').listSync(recursive: true).whereType<File>().where(
          (f) => f.path.endsWith('.dart'),
        );

int _count(RegExp pattern) {
  var n = 0;
  for (final f in _libFiles()) {
    n += pattern.allMatches(f.readAsStringSync()).length;
  }
  return n;
}

String _norm(String path) => path.replaceAll('\\', '/');

void main() {
  test('字号魔法数不增长（基线 $_fontSizeBaseline）', () {
    final n = _count(RegExp(r'fontSize:\s*[0-9]'));
    expect(n, lessThanOrEqualTo(_fontSizeBaseline),
        reason: '新增字号请用 AppText（design_tokens.dart），'
            '并同步调低本测试基线');
  });

  test('尺寸魔法数不增长（SizedBox width/height 数字字面量，基线 $_boxBaseline）', () {
    final n = _count(RegExp(r'SizedBox\(\s*(width|height):\s*[0-9]'));
    expect(n, lessThanOrEqualTo(_boxBaseline),
        reason: '新增间距请用 AppSpace；确实无法归一的几何值可豁免，'
            '但基线不得上调');
  });

  test('内边距魔法数不增长（EdgeInsets 含数字字面量，基线 $_insetsBaseline）', () {
    final n = _count(RegExp(r'EdgeInsets[.A-Za-z]*\([^)]*[0-9]'));
    expect(n, lessThanOrEqualTo(_insetsBaseline),
        reason: '内边距请尽量用 AppSpace 档位');
  });

  test('圆角魔法数不增长（circular() 数字字面量，基线 $_radiusBaseline）', () {
    final n = _count(RegExp(r'(BorderRadius\.circular|Radius\.circular)\(\s*[0-9]'));
    expect(n, lessThanOrEqualTo(_radiusBaseline),
        reason: '圆角请用 AppRadius 阶梯');
  });

  test('app_theme.dart 之外不得新增十六进制色值', () {
    final hits = <String, int>{};
    for (final f in _libFiles()) {
      final key = _norm(f.path);
      if (key == 'lib/core/app_theme.dart') continue;
      final c = RegExp(r'Color\(0x').allMatches(f.readAsStringSync()).length;
      if (c > 0) hits[key] = c;
    }
    for (final e in hits.entries) {
      final cap = _colorWhitelist[e.key];
      expect(cap, isNotNull,
          reason: '${e.key} 出现 ${e.value} 处硬编码色值；'
              '请改用 palette 的语义色 token（确实需要两模式同值的新品牌色'
              '时应登记进白名单并写明理由）');
      expect(e.value, lessThanOrEqualTo(cap!),
          reason: '${e.key} 硬编码色值从 $cap 涨到 ${e.value}；白名单只减不增');
    }
  });
}

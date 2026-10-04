import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 白日模式（亮色外观）守门测试：自定义控件必须从调色板取色。
///
/// 写死的 Color(0x…) 字面量与 Material 的 Colors.* 都不随 AppThemeMode 切换，
/// 是「切到亮色仍有半张界面是深色」的根因；Theme.of(context).brightness 在
/// FluentApp 下不保证跟随当前外观，唯一真相源是 core/app_theme.dart 的 palette。
///
/// 需要例外时：把该值登记进 [_allowedInFiles]（品牌色/几何色这类两模式同值的
/// 颜色），更好的做法是在 AppPalette 里补一个语义 token。

/// 全仓库放行的颜色：无。
///
/// 历史上品牌紫 `Color(0xFF6C5CE7)` 在此放行；主题色可由用户自定义后它是
/// 违规写法——实底主色走 `accentColor`（动态 getter），变体走 palette token。
const brandAllowedEverywhere = <String>[];

/// 完全豁免的文件（调色板/派生定义处）。
const fullyExemptFiles = <String>{'core/app_theme.dart'};

/// 按文件放行的字面量。键为 lib/ 下的相对路径（正斜杠）。
const allowedInFiles = <String, List<String>>{
  'features/settings/settings_page.dart': [
    // 主题色预设色板：用户可选种子色的清单必须写死；勾选取前景的两档中性色。
    'Color(0xFF6C5CE7)',
    'Color(0xFF4F6EF7)',
    'Color(0xFF0078D4)',
    'Color(0xFF00897B)',
    'Color(0xFF43A047)',
    'Color(0xFFC9A227)',
    'Color(0xFFE67E22)',
    'Color(0xFFE5484D)',
    'Color(0xFFD81B60)',
    'Color(0xFF616161)',
    'Color(0xFFFFFFFF)',
    'Color(0xFF101014)',
  ],
  'features/preview/event_preview_view.dart': [
    // 图上底部渐变遮罩：保证白色台词在任意背景图上可读，两模式同值。
    'Color(0xE6101014)',
    // 全屏预览顶栏渐隐遮罩：垫在白色标题/按钮下，同上两模式同值。
    'Color(0xB3000000)',
  ],
  'features/story/story_studio_editor.dart': [
    // 剧情舞台「模拟游戏画面」：黑场上的条件高亮绿与判定黄，与明暗外观解耦。
    'Color(0xFF527C63)',
    'Color(0xFFFFD27D)',
  ],
};

/// Colors.<x> 里仍允许的中性项。
const allowedMaterialColors = <String>{'transparent'};

/// 按文件放行的 Material 颜色：沉浸式游戏画面类 UI（全屏预览舞台、
/// 图片查看器）刻意与明暗外观解耦，白字/黑底两模式同值。
const allowedMaterialColorsInFiles = <String, List<String>>{
  'features/preview/event_preview_view.dart': [
    'black',
    'white',
    'white54',
    'white24',
  ],
  'features/resources/image_asset_picker.dart': [
    'black',
    'white',
    'white54',
  ],
  'features/story/story_studio_editor.dart': [
    // 同「模拟游戏画面」：黑底 + 白字/白描边，两模式同值。
    'black',
    'white',
  ],
};

void main() {
  test('白名单外的硬编码颜色为零', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '请在 frontend/ 下运行');

    final literalRe = RegExp(r'Color\(0x[0-9A-Fa-f]{2,8}\)');
    final materialRe = RegExp(r'\bColors\.([A-Za-z0-9_]+)');
    final brightnessRe = RegExp(r'Theme\.of\(context\)\.brightness');

    final violations = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final rel = entity.path.replaceAll(r'\', '/').replaceFirst('lib/', '');
      if (fullyExemptFiles.contains(rel)) continue;
      final allowed = <String>{
        ...brandAllowedEverywhere,
        ...?allowedInFiles[rel],
      };
      final matAllowed = <String>{
        ...allowedMaterialColors,
        ...?allowedMaterialColorsInFiles[rel],
      };
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('#')) continue;
        final where = rel + ':' + (i + 1).toString();
        for (final m in literalRe.allMatches(line)) {
          if (!allowed.contains(m.group(0))) {
            violations.add(where + '  ' + m.group(0)!);
          }
        }
        for (final m in materialRe.allMatches(line)) {
          if (!matAllowed.contains(m.group(1))) {
            violations.add(where + '  Colors.' + m.group(1)!);
          }
        }
        if (brightnessRe.hasMatch(line)) {
          violations.add(where + '  Theme.of(context).brightness');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '自定义控件必须走 palette token，两套外观才会自动生效。违规 '
          + violations.length.toString() + ' 处：\\n  ' + violations.join('\\n  '),
    );
  });
}

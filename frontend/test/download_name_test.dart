// Web 下载文件名净化（core/download_name.dart）回归。
//
// 背景：`<a download="...">` 不做校验。含 `/`（模组名常见「剧情/第一章」）时
// Chrome 会替换成 `_`，Safari 直接忽略整段；首尾的点与空格在 Windows 上会得到
// 不可用文件名；超长名（整包导出常带模组名 + 版本）会触发路径上限。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/download_name.dart';

void main() {
  group('safeDownloadName', () {
    test('保留正常文件名与中文', () {
      expect(safeDownloadName('我的模组-Alpha-v0.8.2.zip'), '我的模组-Alpha-v0.8.2.zip');
    });

    test('路径分隔符与 Windows 保留字符替换为下划线', () {
      expect(safeDownloadName('剧情/第一章:开头?.zip'), '剧情_第一章_开头_.zip');
      expect(safeDownloadName(r'a\b|c*d".json'), 'a_b_c_d_.json');
    });

    test('去掉首尾的点与空白', () {
      expect(safeDownloadName('  ..name.zip.. '), 'name.zip');
      expect(safeDownloadName('.'), 'download');
      expect(safeDownloadName('   '), 'download');
    });

    test('空串回退 download', () {
      expect(safeDownloadName(''), 'download');
    });

    test('超长时截断主体并保留扩展名', () {
      final long = '${'模' * 200}.zip';
      final out = safeDownloadName(long, maxLength: 32);
      expect(out.length, 32);
      expect(out.endsWith('.zip'), isTrue);
      expect(out.startsWith('模'), isTrue);
    });

    test('超长且无扩展名时硬截断', () {
      final out = safeDownloadName('a' * 300, maxLength: 50);
      expect(out.length, 50);
    });

    test('扩展名过长时按无扩展名处理（不做「保留扩展名」）', () {
      final out = safeDownloadName('${'a' * 40}.verylongextension', maxLength: 20);
      expect(out.length, 20);
      expect(out, 'a' * 20);
    });
  });
}

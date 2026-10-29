// 诊断报告（core/diagnostics.dart）与错误摘要（core/error_fallback.dart）回归。
//
// 这两段文本是用户反馈「白屏/卡住」时唯一能拿到的现场信息，格式一旦漂移，
// 排查成本会立刻回升。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/diagnostics.dart';
import 'package:student_age_editor/core/error_fallback.dart';

void main() {
  group('formatDiagnosticTime', () {
    test('补零到秒', () {
      expect(
        formatDiagnosticTime(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02 03:04:05',
      );
    });
  });

  group('buildDiagnosticsReport', () {
    test('版本缺失显示「未知」，环境缺失同上', () {
      final text = buildDiagnosticsReport(
        now: DateTime(2026, 10, 28, 22, 45, 3),
        appVersion: '  ',
        environment: '',
        diag: const <String, String>{},
      );
      expect(text, contains('版本：未知'));
      expect(text, contains('环境：未知'));
      expect(text, contains('（无）'));
      expect(text, contains('2026-10-28 22:45:03'));
    });

    test('已知字段按「卡在哪」的顺序排列，其余按字母序', () {
      final text = buildDiagnosticsReport(
        now: DateTime(2026, 10, 28),
        appVersion: 'Alpha-v0.8.2',
        environment: 'Chrome',
        diag: const <String, String>{
          'render': 'loading',
          'zeta': 'z',
          'boot': 'loaded=true',
          'alpha': 'a',
        },
      );
      final boot = text.indexOf('boot: loaded=true');
      final render = text.indexOf('render: loading');
      final alpha = text.indexOf('alpha: a');
      final zeta = text.indexOf('zeta: z');
      expect(boot, greaterThan(0));
      expect(boot, lessThan(render));
      expect(render, lessThan(alpha));
      expect(alpha, lessThan(zeta));
    });

    test('没有 JS 错误时不出现该段落', () {
      final text = buildDiagnosticsReport(
        now: DateTime(2026, 10, 28),
        appVersion: 'v1',
        environment: 'env',
        diag: const <String, String>{'boot': 'ok'},
      );
      expect(text, isNot(contains('[最近 JS 错误]')));
    });

    test('JS 错误按旧 → 新编号', () {
      final text = buildDiagnosticsReport(
        now: DateTime(2026, 10, 28),
        appVersion: 'v1',
        environment: 'env',
        diag: const <String, String>{'jsErr': 'x'},
        jsErrors: const <String>['第一条', '第二条'],
      );
      expect(text.indexOf('1. 第一条'), greaterThan(0));
      expect(text.indexOf('2. 第二条'), greaterThan(text.indexOf('1. 第一条')));
      expect(text, contains('不含模组内容与账号信息'));
    });
  });

  group('RenderErrorView', () {
    testWidgets('不依赖 MaterialApp 也能画出错误卡片', (tester) async {
      await tester.pumpWidget(RenderErrorView(summary: 'boom: something failed'));
      expect(find.text('界面渲染出错'), findsOneWidget);
      expect(find.textContaining('boom: something failed'), findsOneWidget);
    });

    testWidgets('空异常信息显示占位文案', (tester) async {
      await tester.pumpWidget(const RenderErrorView(summary: ''));
      expect(find.text('（无异常信息）'), findsOneWidget);
    });
  });

  group('summarizeErrorText', () {
    test('换行与多余空白压成一行', () {
      expect(
        summarizeErrorText('  A\n\n  B\tC  '),
        'A B C',
      );
    });

    test('超长截断并加省略号', () {
      final text = summarizeErrorText('x' * 50, maxChars: 10);
      expect(text, '${'x' * 10}…');
      expect(text.length, 11);
    });

    test('刚好等于上限时不截断', () {
      expect(summarizeErrorText('12345', maxChars: 5), '12345');
    });
  });
}

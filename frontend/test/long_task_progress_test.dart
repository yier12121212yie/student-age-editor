// C5 · 公共长任务进度对话框 + 取消（core/long_task_progress.dart）。
//
// 覆盖（见 plan/ux_roadmap_r2.md C5）：
// - 弹窗展示标题 / 阶段文案 / 进度条；
// - update() 反映阶段与百分比；
// - finish() 关窗且收尾；
// - cancel() 置 isCancelled、触发 onCancel、关窗；
// - fail() 关窗但不置满；
// - cancellable=false 时不显示「取消」按钮；
// - 收尾后的 update()/cancel() 是幂等的（不再改状态）。
//
// 注意：进度值不确定（frac=null）时 ProgressBar 是无限动画，`pumpAndSettle`
// 会超时；故一律用有界的 `pump()` 推进。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:student_age_editor/core/long_task_progress.dart';

/// 推进若干帧以走完路由过渡（不依赖 pumpAndSettle）。
Future<void> _advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 打开一个长任务对话框：点宿主按钮触发 [showLongTaskProgress]。
Future<LongTaskHandle> _open(
  WidgetTester tester, {
  String title = '测试任务',
  String initialLabel = '准备中',
  bool cancellable = true,
}) async {
  late LongTaskHandle handle;
  await tester.pumpWidget(fluent.FluentApp(
    home: fluent.ScaffoldPage(
      content: Builder(
        builder: (ctx) => Center(
          child: fluent.FilledButton(
            onPressed: () {
              handle = showLongTaskProgress(
                ctx,
                title: title,
                initialLabel: initialLabel,
                cancellable: cancellable,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.tap(find.text('open'));
  await _advance(tester);
  return handle;
}

void main() {
  testWidgets('弹出后展示标题、初始阶段与进度条', (tester) async {
    final h = await _open(tester, title: '导入模组包', initialLabel: '申请直传');
    expect(find.byType(LongTaskProgressDialog), findsOneWidget);
    expect(find.text('导入模组包'), findsOneWidget);
    expect(find.textContaining('申请直传'), findsOneWidget);
    expect(find.byType(fluent.ProgressBar), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    h.finish();
    await _advance(tester);
    h.dispose();
  });

  testWidgets('update 反映阶段与百分比', (tester) async {
    final h = await _open(tester, initialLabel: '直传对象存储');
    h.update('直传对象存储', 0.42);
    await tester.pump();
    expect(find.textContaining('直传对象存储'), findsOneWidget);
    expect(find.textContaining('42.0%'), findsOneWidget);
    h.finish();
    await _advance(tester);
    h.dispose();
  });

  testWidgets('finish 关窗且收尾', (tester) async {
    final h = await _open(tester);
    h.finish('导入完成');
    await _advance(tester);
    expect(h.isSettled, isTrue);
    expect(h.isCancelled, isFalse);
    expect(find.byType(LongTaskProgressDialog), findsNothing);
    h.dispose();
  });

  testWidgets('cancel 置标志、触发回调并关窗', (tester) async {
    final h = await _open(tester);
    var called = false;
    h.onCancel = () => called = true;
    await tester.tap(find.text('取消'));
    await _advance(tester);
    expect(h.isCancelled, isTrue);
    expect(h.isSettled, isTrue);
    expect(called, isTrue);
    expect(find.byType(LongTaskProgressDialog), findsNothing);
    h.dispose();
  });

  testWidgets('fail 关窗但不置满', (tester) async {
    final h = await _open(tester);
    h.fail('导入失败');
    await _advance(tester);
    expect(h.isSettled, isTrue);
    expect(h.isCancelled, isFalse);
    expect(find.byType(LongTaskProgressDialog), findsNothing);
    h.dispose();
  });

  testWidgets('cancellable=false 不显示取消按钮与提示', (tester) async {
    final h = await _open(tester, cancellable: false);
    expect(find.text('取消'), findsNothing);
    expect(find.textContaining('后台若已开始执行'), findsNothing);
    h.finish();
    await _advance(tester);
    h.dispose();
  });

  testWidgets('收尾后的 update/cancel 幂等', (tester) async {
    final h = await _open(tester);
    h.finish('完成');
    await _advance(tester);
    h.update('不该生效', 0.1);
    h.cancel();
    expect(h.isCancelled, isFalse);
    expect(find.byType(LongTaskProgressDialog), findsNothing);
    h.dispose();
  });
}

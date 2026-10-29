// WorkbenchScaffold（工作台三栏骨架）行为测试：
// - 宽布局三栏并排；
// - 中窄布局右栏收成 rail，点击以浮层展开（能力不丢），点遮罩收起；
// - 窄屏（<720，见 B1）主从形态：列表铺满 + 底部动作条，编辑页 push 进入
//   （系统返回逐级退出），右栏内容改为 92% 屏高的底部滑出层。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:student_age_editor/core/api_client.dart' show ApiException;
import 'package:student_age_editor/core/motion.dart' show ShimmerBox;
import 'package:student_age_editor/core/workbench_scaffold.dart';

void main() {
  Future<void> pumpScaffold(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: WorkbenchScaffold(
            leftBuilder: (_) => const ColoredBox(
              color: Color(0xFF111111),
              child: Center(child: Text('LEFT')),
            ),
            center: const Center(child: Text('CENTER')),
            rightBuilder: (_) => const Center(child: Text('RIGHT')),
            rightLabel: '设置',
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('宽布局：三栏并排', (tester) async {
    await pumpScaffold(tester, 1400);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('CENTER'), findsOneWidget);
    expect(find.text('RIGHT'), findsOneWidget);
    // 宽布局无 rail。
    expect(find.byTooltip('展开设置'), findsNothing);
  });

  testWidgets('窄布局：右栏收成 rail，点击展开、点遮罩收起', (tester) async {
    await pumpScaffold(tester, 900);
    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('CENTER'), findsOneWidget);
    // 右栏不再并排，而是隐藏在 rail 之后。
    expect(find.text('RIGHT'), findsNothing);
    expect(find.byTooltip('展开设置'), findsOneWidget);

    await tester.tap(find.byTooltip('展开设置'));
    await tester.pump();
    expect(find.text('RIGHT'), findsOneWidget, reason: '展开后右栏应可见');
    expect(find.byTooltip('收起设置'), findsOneWidget);

    // 点遮罩收起：遮罩铺在中栏之上（命中它而不是中栏里的文字），故取中栏
    // 的坐标 tapAt，避免 tap(finder) 因「命中者不是该 finder」而告警。
    await tester.tapAt(tester.getCenter(find.text('CENTER')));
    await tester.pump();
    expect(find.text('RIGHT'), findsNothing);
    expect(find.byTooltip('展开设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ---------------- B1 窄屏（<720）主从形态 ----------------

  Future<void> pumpMobile(WidgetTester tester, double width, double height) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: WorkbenchScaffold(
            leftBuilder: (_) => const ColoredBox(
              color: Color(0xFF111111),
              child: Center(child: Text('LEFT')),
            ),
            center: const Center(child: Text('CENTER')),
            rightBuilder: (_) => const Center(child: Text('RIGHT')),
            rightLabel: '设置',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(390, 844), Size(360, 640)]) {
    testWidgets('窄屏 ${size.width.toInt()}×${size.height.toInt()}：列表铺满 + 底部动作条',
        (tester) async {
      await pumpMobile(tester, size.width, size.height);

      // 列表占满，中栏/右栏都不再并排（右栏收进滑出层，中栏走 push）。
      expect(find.text('LEFT'), findsOneWidget);
      expect(find.text('CENTER'), findsNothing);
      expect(find.text('RIGHT'), findsNothing);
      // 底部动作条：进入编辑 + 设置。
      expect(find.text('打开编辑'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      // 无横向溢出 / 布局异常。
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏 ${size.width.toInt()}×${size.height.toInt()}：设置以底部滑出层展开',
        (tester) async {
      await pumpMobile(tester, size.width, size.height);

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();

      expect(find.text('RIGHT'), findsOneWidget);

      // 点遮罩收起（滑出层占 92% 屏高，顶部留白处即遮罩）。
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.text('RIGHT'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏 ${size.width.toInt()}×${size.height.toInt()}：进入编辑页并可返回',
        (tester) async {
      await pumpMobile(tester, size.width, size.height);

      await tester.tap(find.text('打开编辑'));
      await tester.pumpAndSettle();

      // push 出编辑页：有系统返回按钮，且底部仍有「设置」入口。
      expect(find.text('CENTER'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 编辑页的「设置」入口（列表页那份在下层，取最后一个）。
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.text('RIGHT'), findsOneWidget);

      // 返回列表：编辑页整体退出。
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('CENTER'), findsNothing);
      expect(find.text('LEFT'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  // ---------------- B3 编辑页/滑出层非「快照」回归 ----------------
  // 窄屏编辑页是独立 route，工作台 `setState` 不会重建它；若脚手架不把最新
  // `center` 推过去，编辑页会停在进页那一刻——改字段不刷新、保存条永远禁用，
  // 移动端根本存不了盘。此测试锁死该行为。

  testWidgets('窄屏编辑页：工作台 setState 后中栏实时刷新（非快照）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: const _BumpableHost(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
    expect(find.text('CENTER 0'), findsOneWidget);

    // 在编辑页里改状态 → 中栏必须跟着变。
    await tester.tap(find.text('Bump'));
    await tester.pumpAndSettle();
    expect(find.text('CENTER 1'), findsOneWidget, reason: '编辑页未随工作台重建');
    expect(find.text('CENTER 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏设置滑出层：工作台 setState 后右栏实时刷新（非快照）',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: const _BumpableHost(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('RIGHT 0'), findsOneWidget);

    // 滑出层里改状态 → 右栏必须跟着变。
    await tester.tap(find.text('BumpRight'));
    await tester.pumpAndSettle();
    expect(find.text('RIGHT 1'), findsOneWidget, reason: '滑出层未随工作台重建');
    expect(tester.takeException(), isNull);
  });

  // ---------------- C4 加载/错误/空三态 ----------------

  Future<void> pumpStatus(WidgetTester tester, WorkbenchStatus status,
      {Object? error, VoidCallback? onRetry, String? title}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: WorkbenchScaffold(
            status: status,
            error: error,
            onRetry: onRetry,
            errorTitle: title,
            leftBuilder: (_) => const Center(child: Text('LEFT')),
            center: const Center(child: Text('CENTER')),
            rightBuilder: (_) => const Center(child: Text('RIGHT')),
            rightLabel: '设置',
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('C4 loading：渲染统一骨架屏，不渲染三栏内容', (tester) async {
    await pumpStatus(tester, WorkbenchStatus.loading);

    expect(find.byType(WorkbenchSkeleton), findsOneWidget);
    expect(find.byType(ShimmerBox), findsWidgets);
    // 三栏内容不应被构建。
    expect(find.text('LEFT'), findsNothing);
    expect(find.text('CENTER'), findsNothing);
    expect(find.text('RIGHT'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C4 error：人性化文案 + 重试 + 复制详情', (tester) async {
    await pumpStatus(
      tester,
      WorkbenchStatus.error,
      // 真实 ApiException：5xx 会被 humanizeError 标为 retryable。
      error: ApiException(500, 'boom'),
      onRetry: () {},
    );

    expect(find.byType(WorkbenchErrorPanel), findsOneWidget);
    expect(find.text('数据加载失败'), findsOneWidget);
    // 5xx → 人性化成「后端服务出错」，且 retryable → 按钮文案「重试」。
    expect(find.text('后端服务出错，请稍后重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('复制详情'), findsOneWidget);
    expect(find.text('LEFT'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C4 error：自定义标题 + 无 onRetry 时不显示重试', (tester) async {
    await pumpStatus(
      tester,
      WorkbenchStatus.error,
      error: Exception('boom'),
      title: '人物数据加载失败',
    );

    expect(find.text('人物数据加载失败'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('再试一次'), findsNothing);
    expect(find.text('复制详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C4 ready：维持旧行为，正常渲染三栏', (tester) async {
    await pumpStatus(tester, WorkbenchStatus.ready);

    expect(find.text('LEFT'), findsOneWidget);
    expect(find.text('CENTER'), findsOneWidget);
    expect(find.text('RIGHT'), findsOneWidget);
    expect(find.byType(WorkbenchSkeleton), findsNothing);
    expect(find.byType(WorkbenchErrorPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 可自增的宿主：中栏/右栏都带一个改状态的按钮，用来验证窄屏编辑页 / 滑出层
/// 是否随工作台 `setState` 实时刷新。
class _BumpableHost extends StatefulWidget {
  const _BumpableHost();

  @override
  State<_BumpableHost> createState() => _BumpableHostState();
}

class _BumpableHostState extends State<_BumpableHost> {
  int _n = 0;
  int _m = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WorkbenchScaffold(
        leftBuilder: (_) => const Center(child: Text('LEFT')),
        center: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('CENTER $_n'),
              TextButton(
                onPressed: () => setState(() => _n++),
                child: const Text('Bump'),
              ),
            ],
          ),
        ),
        rightBuilder: (_) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('RIGHT $_m'),
              TextButton(
                onPressed: () => setState(() => _m++),
                child: const Text('BumpRight'),
              ),
            ],
          ),
        ),
        rightLabel: '设置',
      ),
    );
  }
}

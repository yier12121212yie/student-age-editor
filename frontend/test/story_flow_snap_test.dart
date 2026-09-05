/// 阶段 7 吸附层的纯函数回归：容差换算、边缘优先、不过冲、大输入线性。
///
/// 全部不起 Widget：吸附的风险全在「手感」上——容差忘了除以 scale、右边缘
/// 命中却按左边缘对齐、多候选时取了先遇到的而不是最近的，这三类都必须被钉住。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/story/story_flow_snap.dart';

/// 统一用非 200×112 的尺寸，免得「左右同宽」把左/右对齐的错误掩盖掉。
const _box = Size(64, 48);

/// 默认关网格（步长 1000 且值远离 0），这样每条用例只验它声称的那一件事。
const _noGrid = 1000.0;

FlowSnap _snap({
  required Offset desired,
  List<Rect> others = const [],
  double scale = 1,
  Size box = _box,
  double grid = _noGrid,
  double tolerance = 6,
}) => snapDrag(
  desired: desired,
  self: box,
  others: others,
  scale: scale,
  grid: grid,
  tolerance: tolerance,
);

void main() {
  group('网格兜底', () {
    test('others 为空也能用：落网格且不报辅助线', () {
      final s = _snap(desired: const Offset(13, 21), grid: 8);
      expect(s.pos, const Offset(16, 24));
      expect(s.guides, isEmpty, reason: '纯网格吸附不画辅助线');
      expect(s.hasGuides, isFalse);
      expect(s.verticalGuideX, isNull);
      expect(s.horizontalGuideY, isNull);
    });

    test('网格也在容差外时原位不动（不臆造位移）', () {
      final s = _snap(desired: const Offset(13, 21), grid: 64);
      expect(s.pos, const Offset(13, 21));
      expect(s.guides, isEmpty);
    });

    test('grid <= 0 即关闭网格', () {
      final s = _snap(desired: const Offset(13, 21), grid: 0);
      expect(s.pos, const Offset(13, 21));
    });
  });

  group('边缘对齐优先于网格', () {
    test('等宽卡：三对线同时命中，吸附值与目标左边缘一致', () {
      final other = const Rect.fromLTWH(50, 990, 200, 112);
      final s = _snap(
        desired: const Offset(47, 1000),
        others: [other],
        box: const Size(200, 112),
        grid: 8,
      );
      // 网格会给出 48（只移 1），但边缘优先：移到 50（移 3）。
      expect(s.pos.dx, 50);
      expect(s.pos.dy, 1000, reason: '1000 已在 8 网格上，网格吸附不产生辅助线');
      expect(s.guides, [const FlowGuide(vertical: true, at: 50)]);
    });

    test('命中右边缘时对齐的是右边缘，不是左边缘', () {
      final other = const Rect.fromLTWH(0, 250, 96, 60);
      final s = _snap(desired: const Offset(30, 300), others: [other]);
      expect(s.pos.dx, 32, reason: '若按左边缘对齐会得到 96');
      expect(s.pos.dx + _box.width, other.right);
      expect(s.guides, [const FlowGuide(vertical: true, at: 96)]);
      expect(s.pos.dy, 300, reason: 'y 轴无候选且网格已关，不该被挪动');
    });

    test('命中中心线：吸附到 other.center - 半边长', () {
      final s = _snap(
        desired: const Offset(20, 300),
        others: [const Rect.fromLTWH(0, 250, 100, 60)],
      );
      expect(s.pos.dx, 18);
      expect(s.pos.dx + _box.width * 0.5, 50);
      expect(s.guides, [const FlowGuide(vertical: true, at: 50)]);
    });

    test('y 轴命中底边：对齐的是 bottom，不是 top', () {
      final s = _snap(
        desired: const Offset(30, 148),
        others: [const Rect.fromLTWH(52, 200, 100, 60)],
      );
      expect(s.pos.dy, 152, reason: '若按顶边对齐会得到 200');
      expect(s.pos.dy + _box.height, 200);
      expect(s.guides, [const FlowGuide(vertical: false, at: 200)]);
      expect(s.pos.dx, 30);
    });

    test('双轴各命中一条时报两条线（宿主一竖一横）', () {
      final s = _snap(
        desired: const Offset(96, 226),
        others: [const Rect.fromLTWH(100, 200, 100, 60)],
      );
      expect(s.pos, const Offset(100, 230));
      expect(s.guides, [
        const FlowGuide(vertical: true, at: 100),
        const FlowGuide(vertical: false, at: 230),
      ]);
      expect(s.verticalGuideX, 100);
      expect(s.horizontalGuideY, 230);
    });
  });

  group('候选选择与容差', () {
    test('多候选取最近（远的先出现也必须被替换掉）', () {
      final s = _snap(
        desired: const Offset(98, 300),
        others: [
          const Rect.fromLTWH(103, 250, 100, 60), // 距离 5
          const Rect.fromLTWH(101, 252, 100, 60), // 距离 3 ← 应选这条
        ],
      );
      expect(s.pos.dx, 101);
      expect(s.guides, [const FlowGuide(vertical: true, at: 101)]);
    });

    test('容差是屏幕像素：scale 0.5 时世界容差必须是 12', () {
      // 世界距离 10：屏幕 5px（0.5 缩放下）该吸，1:1 时 10px 不该吸。
      final others = [const Rect.fromLTWH(8, 280, 200, 60)];
      final zoomedOut = _snap(
        desired: const Offset(98, 300),
        others: others,
        scale: 0.5,
      );
      expect(zoomedOut.pos.dx, 108);
      // 邻近带要求垂直真的重叠，而重叠后 y 候选必然也进 12px 世界容差，
      // 所以这里只断言竖线，不比整张 guides 列表。
      expect(zoomedOut.verticalGuideX, 108);

      expect(
        _snap(desired: const Offset(98, 300), others: others).pos.dx,
        98,
        reason: 'scale 1 → 世界容差 6，距离 10 必须放过',
      );
      expect(
        _snap(desired: const Offset(98, 300), others: others, scale: 2).pos.dx,
        98,
        reason: 'scale 2 → 世界容差 3，同样不吸',
      );
    });

    test('scale 非法（0 / NaN）时退化不崩，按原始容差处理', () {
      final others = [const Rect.fromLTWH(8, 280, 200, 60)];
      for (final bad in [0.0, -1.0, double.nan]) {
        final s = _snap(
          desired: const Offset(98, 300),
          others: others,
          scale: bad,
        );
        expect(s.pos.dx, 98);
        expect(s.pos.dy, 300);
      }
    });

    test('绝不过冲：返回的平移不大于任何候选，也不超世界容差', () {
      const desired = Offset(123.5, 77.25);
      const scale = 0.75;
      const tolerance = 6.0;
      final others = [
        for (var i = 0; i < 30; i++)
          Rect.fromLTWH(
            (i * 53) % 700 - 100 + 0.5,
            // 邻近带要求垂直重叠：y 全放在被拖框附近，穷举口径才与实现一致
            60 + (i % 5) * 2 + 0.25,
            200,
            112,
          ),
      ];
      final s = _snap(
        desired: desired,
        others: others,
        scale: scale,
        grid: 8,
        tolerance: tolerance,
      );

      // 穷举 snapDrag 的候选口径：每条 rect 的 3 条线 × 自身 3 条线，
      // x/y 分开存——拿 dx 去比 y 轴候选没有意义。
      final xShifts = <double>[];
      final yShifts = <double>[];
      for (final r in others) {
        for (final line in [r.left, r.center.dx, r.right]) {
          for (final k in [0.0, _box.width / 2, _box.width]) {
            xShifts.add(line - desired.dx - k);
          }
        }
        for (final line in [r.top, r.center.dy, r.bottom]) {
          for (final k in [0.0, _box.height / 2, _box.height]) {
            yShifts.add(line - desired.dy - k);
          }
        }
      }
      final worldTol = tolerance / scale;
      final moved = s.pos - desired;
      expect(moved.dx.abs(), lessThanOrEqualTo(worldTol + 1e-9));
      expect(moved.dy.abs(), lessThanOrEqualTo(worldTol + 1e-9));
      for (final shift in xShifts.where((d) => d.abs() <= worldTol)) {
        expect(
          moved.dx.abs(),
          lessThanOrEqualTo(shift.abs() + 1e-9),
          reason: 'x 轴吸附比更近的候选还远',
        );
      }
      for (final shift in yShifts.where((d) => d.abs() <= worldTol)) {
        expect(
          moved.dy.abs(),
          lessThanOrEqualTo(shift.abs() + 1e-9),
          reason: 'y 轴吸附比更近的候选还远',
        );
      }
      expect(s.pos.dx.isFinite && s.pos.dy.isFinite, isTrue);
    });
  });

  group('宿主侧', () {
    test('400 个 rect 的每帧输入：不崩且与只给一条候选时同解', () {
      final others = <Rect>[
        for (var i = 0; i < 400; i++)
          Rect.fromLTWH((i % 20) * 260.0, (i ~/ 20) * 180.0, 200, 112),
        const Rect.fromLTWH(0, 280, 96, 60), // 唯一进带且在容差内的候选（右边缘）
      ];
      final sw = Stopwatch()..start();
      var last = Offset.zero;
      for (var frame = 0; frame < 200; frame++) {
        last = _snap(desired: const Offset(30, 300), others: others).pos;
      }
      sw.stop();
      debugPrint('snapDrag ×200 帧（401 rect）: ${sw.elapsedMilliseconds}ms');
      expect(others.length, 401);
      expect(
        last,
        _snap(
          desired: const Offset(30, 300),
          others: [const Rect.fromLTWH(0, 280, 96, 60)],
        ).pos,
      );
      expect(last, const Offset(32, 300));
    });

    test('flowNodeRects 按 positions/排除集/可见区造输入，尺寸可逐节点覆盖', () {
      final positions = <String, Offset>{
        '1': const Offset(0, 0),
        '2': const Offset(300, 40),
        '3': const Offset(5000, 5000),
      };
      expect(flowNodeRects(positions: positions), [
        const Rect.fromLTWH(0, 0, kFlowSnapNodeW, kFlowSnapNodeH),
        const Rect.fromLTWH(300, 40, kFlowSnapNodeW, kFlowSnapNodeH),
        const Rect.fromLTWH(5000, 5000, kFlowSnapNodeW, kFlowSnapNodeH),
      ]);
      expect(flowNodeRects(positions: positions, exclude: {'1'}), hasLength(2));
      final visible = flowNodeRects(
        positions: positions,
        visible: const Rect.fromLTWH(-10, -10, 1000, 1000),
      );
      expect(visible, hasLength(2));
      expect(visible.last.left, 300);
      final tall = flowNodeRects(
        positions: positions,
        heightOf: (id) => id == '2' ? 316 : kFlowSnapNodeH,
      );
      expect(tall[1].height, 316);
      // 端到端：拖 1 号卡到 (296, 64)，与 2 号卡（左上 300,40）在同一行 ——
      // 64 已在 8 网格上，所以 y 既不对齐也不挪动。
      // 邻近带要求两框在另一轴真的重叠，隔着一整行不再互相吸。
      final s = snapDrag(
        desired: const Offset(296, 64),
        self: const Size(kFlowSnapNodeW, kFlowSnapNodeH),
        others: flowNodeRects(positions: positions, exclude: {'1'}),
        scale: 1,
        grid: 8,
      );
      expect(s.pos.dx, 300);
      expect(s.pos.dy, 64, reason: 'y 已在网格上，既不对齐也不挪动');
      expect(s.guides, [const FlowGuide(vertical: true, at: 300)]);
    });
  });

  group('邻近带（另一个轴必须真的重叠）', () {
    test('正上方 3000px 的一行不抢 x 吸附', () {
      // 没有这一步，419 节点的事件里几乎任何一次拖拽都会被某个远处的
      // 行「抽」走 3px，用户感觉是吸附在抓人。
      final s = _snap(
        desired: const Offset(103, 400),
        others: [Rect.fromLTWH(100, 0, 64, 48)],
      );
      expect(s.pos, const Offset(103, 400), reason: '垂直不重叠 → 不认它的 x');
      expect(s.guides, isEmpty);
    });

    test('同一行（垂直重叠）时照常吸附并出竖线', () {
      final s = _snap(
        desired: const Offset(103, 400),
        others: [Rect.fromLTWH(100, 400, 64, 48)],
      );
      expect(s.pos.dx, 100);
      expect(s.verticalGuideX, 100);
    });

    test('只差几个像素的间隙仍算邻近（带内按容差放宽）', () {
      // r.top(440) 与被拖框底边(448)在容差带内重叠 → 仍应参与 x 对齐；
      // 它的三条 y 线离自身 y 线都超过容差，所以 y 不该动。
      final s = _snap(
        desired: const Offset(103, 400),
        others: [Rect.fromLTWH(100, 440, 64, 60)],
      );
      expect(s.pos.dx, 100);
      expect(s.pos.dy, 400, reason: '它的 y 线离得太远，不该顺手把 y 也吸走');
      expect(s.horizontalGuideY, isNull);
    });

    test('y 对齐同样要求水平重叠', () {
      final s = _snap(
        desired: const Offset(103, 400),
        others: [Rect.fromLTWH(600, 398, 64, 48)],
      );
      expect(s.pos, const Offset(103, 400), reason: '水平不相干 → 2px 也不吸');
    });
  });
}

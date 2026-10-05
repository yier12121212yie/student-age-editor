// AppState 离开守卫链（切换模式/模组前统一确认）的单元测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/models.dart';

void main() {
  test('runLeaveGuards：任一守卫返回 false 即中止', () async {
    final s = AppState();
    var ran = 0;
    s.registerLeaveGuard('ok', () async {
      ran++;
      return true;
    });
    s.registerLeaveGuard('stop', () async {
      ran++;
      return false;
    });
    expect(await s.runLeaveGuards(), isFalse);
    expect(ran, greaterThanOrEqualTo(1));
  });

  test('runLeaveGuards：全部通过返回 true，注销后不再调用', () async {
    final s = AppState();
    var n = 0;
    s.registerLeaveGuard('g', () async {
      n++;
      return true;
    });
    expect(await s.runLeaveGuards(), isTrue);
    expect(n, 1);
    s.unregisterLeaveGuard('g');
    expect(await s.runLeaveGuards(), isTrue);
    expect(n, 1);
  });

  test('runLeaveGuards：兼容旧单槽 leaveGuard，且先于注册表运行', () async {
    final s = AppState();
    final order = <String>[];
    s.leaveGuard = () async {
      order.add('legacy');
      return true;
    };
    s.registerLeaveGuard('g', () async {
      order.add('registered');
      return true;
    });
    expect(await s.runLeaveGuards(), isTrue);
    expect(order, ['legacy', 'registered']);

    // 旧守卫拒绝时，注册表守卫不应再运行。
    order.clear();
    s.leaveGuard = () async {
      order.add('legacy');
      return false;
    };
    expect(await s.runLeaveGuards(), isFalse);
    expect(order, ['legacy']);
  });
}

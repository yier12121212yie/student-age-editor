/// 画布未保存改动的内存撤销栈。
///
/// 为什么后端历史不够：`/api/history` 的快照由 `cfg_store` 在**存表时**打点，
/// 粒度是整张 cfg 表，且各表栈互相独立。画布上「改了还没保存」的那段区间它
/// 根本看不见，所以编辑栈必须自己维护。两层各自的边界见 workspace 的 `_undo`。
library;

import 'dart:ui' show Offset;

import 'story_logic.dart' show copyRecords, valueEquals;

/// 一次编辑后的舞台全量快照。位置也在内：删节点会连坐标一起清掉，
/// 撤销若不带回位置，复活的节点会掉到 (0, 0)。
class FlowEditSnapshot {
  FlowEditSnapshot({
    required this.talks,
    required this.opts,
    required this.positions,
  });

  final Map<String, dynamic> talks;
  final Map<String, dynamic> opts;
  final Map<String, Offset> positions;
}

/// 线性快照栈：`_states[0]` 是载入/切事件时的初始态，游标指向当前内容。
class FlowEditHistory {
  FlowEditHistory({this.limit = 60});

  /// 栈深上限。超限丢最旧一步：初始态丢了也不能丢，所以实际保留 limit+1 个。
  final int limit;

  final List<FlowEditSnapshot> _states = [];
  int _cursor = -1;
  Object? _lastKey;

  int get length => _states.length;
  int get cursor => _cursor;

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor >= 0 && _cursor < _states.length - 1;

  /// 载入舞台后调用：清栈并把当前内容作为初始态。
  void seed(
    Map<String, dynamic> talks,
    Map<String, dynamic> opts,
    Map<String, Offset> positions,
  ) {
    _states
      ..clear()
      ..add(_snapshot(talks, opts, positions));
    _cursor = 0;
    _lastKey = null;
  }

  /// 内容变更后记录当前状态。同一 `mergeKey` 连续变更（在内联输入框里
  /// 逐字打字）合成一步，否则一次输入会吃掉整个栈、撤销要按字退。
  void record(
    Map<String, dynamic> talks,
    Map<String, dynamic> opts,
    Map<String, Offset> positions, {
    Object? mergeKey,
  }) {
    if (_states.isEmpty) return;
    final snap = _snapshot(talks, opts, positions);
    final atTip = _cursor == _states.length - 1;
    if (mergeKey != null && atTip && mergeKey == _lastKey) {
      _states[_cursor] = snap;
      return;
    }
    _lastKey = mergeKey;
    if (_cursor < _states.length - 1) {
      _states.removeRange(_cursor + 1, _states.length);
    }
    _states.add(snap);
    while (_states.length > limit + 1) {
      _states.removeAt(1); // 初始态（下标 0）永不淘汰
    }
    _cursor = _states.length - 1;
  }

  /// 回退一步；无可退返回 null（调用方决定是否落到后端历史层）。
  ///
  /// 交出的是**脱离引用的副本**：宿主把返回值直接当作舞台内容并继续原地编辑，
  /// 若共享同一对象就等于把快照栈里的那一步也改掉了（再撤销会看到漂移内容）。
  FlowEditSnapshot? undo() {
    if (!canUndo) return null;
    _cursor--;
    _lastKey = null;
    return _detach(_states[_cursor]);
  }

  FlowEditSnapshot? redo() {
    if (!canRedo) return null;
    _cursor++;
    _lastKey = null;
    return _detach(_states[_cursor]);
  }

  FlowEditSnapshot _detach(FlowEditSnapshot s) =>
      _snapshot(s.talks, s.opts, s.positions);

  FlowEditSnapshot _snapshot(
    Map<String, dynamic> talks,
    Map<String, dynamic> opts,
    Map<String, Offset> positions,
  ) {
    return FlowEditSnapshot(
      talks: copyRecords(talks),
      opts: copyRecords(opts),
      // Offset 不可变，浅拷贝即可
      positions: Map<String, Offset>.of(positions),
    );
  }
}

/// 两份舞台内容是否等价。
///
/// 撤销回到基线时宿主要把「未保存」标记摘掉，但**不能靠游标位置判断**：
/// 保存会把基线前移到当时的内容，此后退到 0 号快照仍是已改过的状态。
bool sameStage(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (!_valueEquals(entry.value, b[entry.key])) return false;
  }
  return true;
}

bool _valueEquals(dynamic a, dynamic b) => valueEquals(a, b);

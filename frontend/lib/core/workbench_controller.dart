/// 工作台公共控制器(A3.2):整表 load / save / dirty / 乐观锁 409 的单一实现。
///
/// 12 个工作台此前各自复制一份「`_loadAll` / `_saveAll` / `_dirty` / `_snap`
/// / `_mtime` / 409 冲突弹窗」,共约 90 行 × 12 份。行为差异是隐患:
/// 有的漏了 `expect_mtime_ns`、有的 409 只提示不弹窗、有的 `_snap` 用
/// `jsonEncode` 有的用 `jsonDecode` 往返。此处统一,并复用第一轮的
/// [WorkbenchLeaveGuard] 让「未保存修改」的离开确认也走同一份状态。
///
/// 设计要点:
/// - **不持有 UI**:弹窗 / 提示通过回调 [onConflict] / [onError] / [onSaved]
///   交给工作台注入(工作台才知道该用哪个 `context` 与文案);
/// - **表可多个**:一个工作台常管 2–3 张表(如「外部对话」要写入口表 + TalkCfg),
///   所以 [tables] 是列表,`save` 逐表 PUT、[dirty] 任表脏即脏;
/// - **乐观锁逐表**:每表各自记住 `mtime_ns` 与快照,互不干扰。
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 脏状态追踪用的共享可变量：被包装的任意一层(含嵌套 Map/List)发生写操作即自增。
class _Rev {
  int n = 0;

  /// 「即将写入」钩子（N12）：在工作台数据发生**实际写入前**调用，
  /// 控制器借此捕获「变更前」快照（此刻数据仍是旧值）。loadFrom/discard
  /// 这类整表替换不走这里（它们直接自增 [n]），避免把重载当成一次编辑。
  VoidCallback? onChange;

  void bump() {
    onChange?.call();
    n++;
  }
}

/// 递归包装:把 JSON 解码得到的 Map/List 换成「写入时自增 [rev]」的视图,
/// 使 `dirty` 判定从「每帧全量 jsonEncode」降为 O(1) 比较。
///
/// 幂等:已是同一 [rev] 的 [_TrackedMap] / [_TrackedList] 直接原样返回;
/// 来自旧 [rev] 的则解包其底层容器、按当前 [rev] 重新绑定。
Object? _wrap(Object? v, _Rev rev) {
  if (v is _TrackedMap) {
    if (identical(v._rev, rev)) return v;
    v = v._m;
  } else if (v is _TrackedList) {
    if (identical(v._rev, rev)) return v;
    v = v._l;
  }
  if (v is Map) {
    final m = <String, dynamic>{};
    v.forEach((k, e) => m['$k'] = _wrap(e, rev));
    return _TrackedMap<String, dynamic>(m, rev);
  }
  if (v is List) {
    return _TrackedList<dynamic>([for (final e in v) _wrap(e, rev)], rev);
  }
  return v;
}

/// 纯 Dart 树的递归深拷贝(快照用):只认 Map/List/String/num/bool/null,
/// 与 `jsonDecode(jsonEncode(x))` 等价但不产生中间 JSON 字符串。
Object? _clonePlain(Object? v) {
  if (v is Map) {
    final out = <String, dynamic>{};
    v.forEach((k, e) => out['$k'] = _clonePlain(e));
    return out;
  }
  if (v is List) {
    return [for (final e in v) _clonePlain(e)];
  }
  return v;
}

/// 纯 Dart 树的递归深比较(与 `jsonEncode` 串比对同口径,免去字符串分配)。
bool _valueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key)) return false;
      if (!_valueEquals(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_valueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// 写入可观测的 Map 视图(仅 `[]=` / `remove` / `clear` 会自增版本号)。
class _TrackedMap<K, V> extends MapBase<K, V> {
  _TrackedMap(Map<K, V> m, _Rev rev)
      : _m = m,
        _rev = rev;

  final Map<K, V> _m;
  final _Rev _rev;

  @override
  V? operator [](Object? key) => _m[key];

  @override
  void operator []=(K key, V value) {
    // 同值重复写不入版本号(避免无意义的 dirty 翻转)。
    if (_m.containsKey(key) && identical(_m[key], value)) return;
    _rev.bump();  // 写入前通知（N12 快照要的是变更前状态）
    // 写入前包一层:否则新赋入的 Map/List 是裸容器,后续在其中的修改
    // 无法自增版本号 -> dirty 静默丢失。
    _m[key] = _wrap(value, _rev) as V;
  }

  @override
  V? remove(Object? key) {
    if (!_m.containsKey(key)) return null;
    _rev.bump();
    return _m.remove(key);
  }

  @override
  void clear() {
    if (_m.isEmpty) return;
    _rev.bump();
    _m.clear();
  }

  @override
  Iterable<K> get keys => _m.keys;
}

/// 写入可观测的 List 视图(仅 `length=` / `[]=` / `add` / `addAll` / `insert`
/// 会自增版本号)。
class _TrackedList<E> extends ListBase<E> {
  _TrackedList(List<E> l, _Rev rev)
      : _l = l,
        _rev = rev;

  final List<E> _l;
  final _Rev _rev;

  @override
  int get length => _l.length;

  @override
  set length(int value) {
    _rev.bump();
    _l.length = value;
  }

  @override
  E operator [](int index) => _l[index];

  @override
  void operator []=(int index, E value) {
    if (identical(_l[index], value)) return;
    _rev.bump();
    _l[index] = _wrap(value, _rev) as E;
  }

  @override
  void add(E element) {
    _rev.bump();
    _l.add(_wrap(element, _rev) as E);
  }

  @override
  void addAll(Iterable<E> iterable) {
    final items = [for (final e in iterable) _wrap(e, _rev) as E];
    if (items.isEmpty) return;
    _rev.bump();
    _l.addAll(items);
  }

  @override
  void insert(int index, E element) {
    _rev.bump();
    _l.insert(index, _wrap(element, _rev) as E);
  }
}

/// 单张表的乐观锁状态。
class WorkbenchTable {
  WorkbenchTable(this.cfg) {
    // 版本号的「即将写入」事件转发给编辑钩子（读字段而非捕获，允许后挂）。
    _rev.onChange = () => onBeforeChange?.call();
  }

  /// 配置表名(对应 `/api/cfg/<cfg>`)。
  final String cfg;

  final _Rev _rev = _Rev();

  /// 最近一次加载/保存时的版本号;与当前 [_rev] 不同即为脏。
  int _savedRev = 0;

  /// 编辑前钩子（N12）：由 [WorkbenchController] 注入，在任意一层发生
  /// 实际写入前调用（此刻 [data] 仍是变更前的值）。
  VoidCallback? onBeforeChange;

  /// 纯 Dart 树快照的快速取用（撤销/重做用）。
  Object? snapshotPlain() => _clonePlain(_data);

  /// 用纯 Dart 树整体替换当前数据（撤销/重做回放）。与 [loadFrom]/[discard]
  /// 同语义：不触发编辑钩子；若内容恰与磁盘快照一致，脏标记立即归位到
  /// 「已同步」（否则 `dirty` 会停留在上一个版本号上）。
  void replaceDataFromSnapshot(Object? plain) {
    _rev.n++;  // 整表被替换，同 loadFrom
    _data = _wrap(_clonePlain(plain), _rev) as Map<String, dynamic>;
    _deepRev = -1;  // 数据换了，深比较缓存失效
    if (_valueEquals(_data, _snapData)) _savedRev = _rev.n;
  }

  /// 最近一次加载/保存的纯 Dart 树快照,供 [discard] 与 [checkDirtyDeep] 使用。
  Object? _snapData = const <String, dynamic>{};

  late Map<String, dynamic> _data =
      _wrap(<String, dynamic>{}, _rev) as Map<String, dynamic>;

  /// 内存中的整表数据。写入其中任意一层都会让 [dirty] 立即为 true。
  Map<String, dynamic> get data => _data;

  /// 最近一次读/写得到的 `mtime_ns`,作为下次 PUT 的 `expect_mtime_ns`。
  int? mtime;

  /// 是否有未保存修改(O(1),不再每帧全量 jsonEncode)。
  bool get dirty => _rev.n != _savedRev;

  /// 当前版本号（对 `data` 任意一层写入即自增）。
  /// 供调用方做「数据一变就失效」的派生缓存键（如排序/分组结果）。
  int get revision => _rev.n;

  /// 与最近一次加载/保存的快照做精确深比较(逃生口)。
  ///
  /// 结果按当前版本号缓存：同一 [_Rev.n] 内重复调用只算一次，避免「保存按钮
  /// 启用态」这类每帧读取把 O(表行数) 的深比较摊到每一帧。
  bool checkDirtyDeep() {
    if (_deepRev == _rev.n) return _deepDirty;
    _deepRev = _rev.n;
    _deepDirty = !_valueEquals(_data, _snapData);
    return _deepDirty;
  }

  // checkDirtyDeep 的版本化缓存（见上）。
  int _deepRev = -1;
  bool _deepDirty = false;

  /// 显式标记为脏(修改未经可观测 Map/List 时的兜底入口)。
  void markDirty() => _rev.n++;

  /// 从磁盘响应体解出 `data` 与 `mtime_ns`。响应可能是
  /// `{data:{...}, mtime_ns:N}` 或直接是数据对象。
  void loadFrom(dynamic resp) {
    Map<String, dynamic> raw;
    if (resp is Map && resp['data'] is Map) {
      raw = (resp['data'] as Map).cast<String, dynamic>();
      mtime = resp['mtime_ns'] is int ? resp['mtime_ns'] as int : null;
    } else if (resp is Map) {
      raw = resp.cast<String, dynamic>();
      mtime = null;
    } else {
      raw = <String, dynamic>{};
      mtime = null;
    }
    // 整表被替换：版本号必须推进，否则按 [revision] 缓存的派生结果（排序/分组/
    // 深比较）会停在旧数据上（loadFrom 不改 `_rev.n`，只需 `_savedRev` 归位即可
    // 保持 dirty=false，这正是当初没注意到缓存键的地方）。
    _rev.n++;
    _data = _wrap(raw, _rev) as Map<String, dynamic>;
    _snapData = _clonePlain(_data);
    _savedRev = _rev.n;
    _deepRev = -1;  // 数据/快照换了，深比较缓存失效
  }

  /// 记录一次成功写入的新 `mtime_ns`,并把当前内存态固化为新快照。
  void markSaved(dynamic resp) {
    if (resp is Map && resp['mtime_ns'] is int) {
      mtime = resp['mtime_ns'] as int;
    }
    _snapData = _clonePlain(_data);
    _savedRev = _rev.n;
    _deepRev = -1;  // 快照换了，深比较缓存失效
  }

  /// 放弃内存修改,恢复磁盘快照。
  void discard() {
    _rev.n++;  // 整表被替换，同 loadFrom
    _data = _wrap(_clonePlain(_snapData), _rev) as Map<String, dynamic>;
    _savedRev = _rev.n;
    _deepRev = -1;  // 数据/快照换了，深比较缓存失效
  }
}

/// 保存冲突([save] 检出 409)时工作台的选择。
enum WorkbenchConflictChoice { reload, force, cancel }

/// 一个工作台的整表数据控制器。工作台 `State` 持有一个实例,
/// 在 `setState` 之外改 `controller.table(cfg).data` 后调用 `notify` 即可。
class WorkbenchController extends ChangeNotifier {
  WorkbenchController({
    required this.cfgs,
    this.onConflict,
    this.onError,
    this.onSaved,
    this.onLoaded,
  }) {
    for (final c in cfgs) {
      _tables[c] = WorkbenchTable(c)..onBeforeChange = _onBeforeTableChange;
    }
  }

  /// 本控制器管理的表名列表。
  final List<String> cfgs;

  /// 撤销栈上限（步）。
  static const int maxUndoSteps = 50;

  /// 编辑合并窗口：窗口内的连续改动合并为一步撤销（去抖：每次改动顺延）。
  static const Duration editWindow = Duration(milliseconds: 600);

  /// 检出冲突时弹窗问用户。返回 `null` 视为取消。
  final Future<WorkbenchConflictChoice?> Function(WorkbenchTable table)?
      onConflict;

  /// 保存失败提示(文案已由调用方人性化)。
  final void Function(Object error)? onError;

  /// 保存成功提示。
  final void Function(WorkbenchTable table)? onSaved;

  /// 全部表加载完成后(`_loading` 置 false 之前)。
  final Future<void> Function()? onLoaded;

  final Map<String, WorkbenchTable> _tables = <String, WorkbenchTable>{};

  // ---- N12 撤销/重做：有界快照栈（步数上限 [maxUndoSteps]）----
  // 一步 = 全部表在同一编辑窗口内的改动；栈里存的是「变更前」的纯 Dart 树。
  final List<Map<String, Object?>> _undoStack = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _redoStack = <Map<String, Object?>>[];
  Map<String, Object?>? _pendingStep;  // 当前窗口的变更前快照
  Timer? _editTimer;

  bool _loading = true;
  bool _saving = false;
  Object? _error;

  /// 统一的响应体数据提取:兼容 `{data:{...}}` 与裸数据对象两种形态,
  /// 取代各工作台各自复制的 `_dataOf`。
  static Map<String, dynamic> extractData(dynamic resp) {
    if (resp is Map && resp['data'] is Map) {
      return (resp['data'] as Map).cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  WorkbenchTable table(String cfg) => _tables[cfg]!;

  List<WorkbenchTable> get tables => cfgs.map(table).toList(growable: false);

  bool get loading => _loading;
  bool get saving => _saving;
  Object? get error => _error;

  /// 任表有未保存修改（O(1) 快速预判）。
  bool get dirty => _tables.values.any((t) => t.dirty);

  /// 精确脏判定：`dirty` 快速预判 + 深比较（P2-I2-a）。用于保存按钮启用态与
  /// 离开守卫——「把字段改回原值」后版本号仍不同，但内容与快照一致，不应再
  /// 弹无谓的「未保存」提示。深比较结果按版本号缓存，同一版本内只算一次。
  bool get dirtyDeep => _tables.values.any((t) => t.dirty && t.checkDirtyDeep());

  /// 加载代际序号：并发触发 [load] 时，旧请求的回填必须被丢弃，
  /// 否则两次响应的 `loadFrom` 会交错、旧响应覆盖新响应（P2-I1）。
  int _loadSeq = 0;

  /// 加载所有表。任一表失败则整体进入 error 态并抛出。
  Future<void> load() async {
    final seq = ++_loadSeq;
    _clearHistory();  // 重载后旧快照对应的是被替换的数据，历史作废
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      for (final cfg in cfgs) {
        final resp = await ApiClient.instance.get('/api/cfg/$cfg');
        if (seq != _loadSeq) return;  // 已被更新的 load 取代：丢弃旧回填
        _tables[cfg]!.loadFrom(resp);
      }
      if (onLoaded != null) await onLoaded!();
      if (seq != _loadSeq) return;
      _loading = false;
      _error = null;
    } catch (e) {
      if (seq != _loadSeq) return;
      _error = e;
      _loading = false;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  /// 保存所有脏表。返回是否**全部**保存成功(用户选择取消冲突即 false)。
  ///
  /// 409 处理:按 [onConflict] 的答复决定 `reload`(放弃本地、重载该表)/
  /// `force`(带 `force:true` 重试)/ 取消(中止本次保存)。
  Future<bool> save() async {
    if (_saving) return false;
    _saving = true;
    notifyListeners();
    try {
      for (final t in tables) {
        if (!t.dirty) continue;
        var force = false;
        for (;;) {
          try {
            final body = <String, dynamic>{
              'data': t.data,
              if (!force) 'expect_mtime_ns': t.mtime,
              if (force) 'force': true,
            };
            final resp = await ApiClient.instance
                .put('/api/cfg/${t.cfg}', body: body);
            t.markSaved(resp);
            onSaved?.call(t);
            break;
          } on ApiException catch (e) {
            if (e.statusCode == 409 && !force && onConflict != null) {
              final choice = await onConflict!(t);
              if (choice == WorkbenchConflictChoice.reload) {
                final resp = await ApiClient.instance.get('/api/cfg/${t.cfg}');
                t.loadFrom(resp);
                break;
              }
              if (choice == WorkbenchConflictChoice.force) {
                force = true;
                continue;
              }
              return false; // 取消
            }
            onError?.call(e);
            return false;
          } catch (e) {
            onError?.call(e);
            return false;
          }
        }
      }
      return true;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// 放弃全部内存修改（U2：保留撤销能力）。
  ///
  /// 恢复磁盘快照前把当前状态压入撤销栈——误点「放弃修改」后 Ctrl+Z 仍可
  /// 找回整场编辑；旧实现直接 `_clearHistory()`，一次误点即不可逆。
  void discard() {
    _sealPending();
    final before = _snapshotAll();
    for (final t in tables) {
      t.discard();
    }
    _redoStack.clear();
    _undoStack.add(before);
    while (_undoStack.length > maxUndoSteps) {
      _undoStack.removeAt(0);
    }
    notifyListeners();
  }

  // ---------- N12 撤销 / 重做 ----------

  /// 可否撤销（进行中的编辑窗口也算一步）。
  bool get canUndo => _pendingStep != null || _undoStack.isNotEmpty;

  bool get canRedo => _redoStack.isNotEmpty;

  /// 撤销一步。还原后 [dirty]/[dirtyDeep] 按内容自然重算。
  bool undo() {
    _sealPending();  // 若正处在编辑窗口内，先把这一步封口
    if (_undoStack.isEmpty) return false;
    final target = _undoStack.removeLast();
    _redoStack.add(_snapshotAll());
    _restoreAll(target);
    notifyListeners();
    return true;
  }

  /// 重做一步。
  bool redo() {
    if (_redoStack.isEmpty) return false;
    final target = _redoStack.removeLast();
    _undoStack.add(_snapshotAll());
    _restoreAll(target);
    notifyListeners();
    return true;
  }

  /// 任意一层数据即将写入前（钩子）：开/续编辑窗口并捕获「变更前」快照。
  void _onBeforeTableChange() {
    if (_pendingStep == null) {
      _pendingStep = _snapshotAll();
      _redoStack.clear();  // 新编辑分叉：重做链失效
    }
    _editTimer?.cancel();
    _editTimer = Timer(editWindow, () {
      _editTimer = null;
      _sealPending();
    });
  }

  /// 封口当前编辑窗口：把「变更前」快照压入撤销栈。
  void _sealPending() {
    _editTimer?.cancel();
    _editTimer = null;
    final step = _pendingStep;
    if (step == null) return;
    _pendingStep = null;
    _undoStack.add(step);
    while (_undoStack.length > maxUndoSteps) {
      _undoStack.removeAt(0);
    }
  }

  Map<String, Object?> _snapshotAll() => <String, Object?>{
        for (final e in _tables.entries) e.key: e.value.snapshotPlain(),
      };

  void _restoreAll(Map<String, Object?> snap) {
    for (final e in snap.entries) {
      _tables[e.key]?.replaceDataFromSnapshot(e.value);
    }
  }

  void _clearHistory() {
    _editTimer?.cancel();
    _editTimer = null;
    _pendingStep = null;
    _undoStack.clear();
    _redoStack.clear();
  }

  @override
  void dispose() {
    _clearHistory();
    _tables.clear();
    super.dispose();
  }
}

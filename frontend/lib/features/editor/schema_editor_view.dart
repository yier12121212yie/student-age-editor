import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../settings/settings_page.dart';
import '../files/file_viewer.dart' show ImagePreview;
import '../nocode/entity_picker.dart';
import '../nocode/no_code_exit.dart';
import '../nocode/nocode_effect_field.dart';
import '../nocode/role_picker.dart';
import '../resources/image_asset_picker.dart';
import 'effect_hint_field.dart';
import 'field_meta.dart';
import 'field_search.dart';
import 'field_utils.dart';
import 'id_ref_picker.dart';
import '../resources/local_import.dart' show importLocalAssets;
import 'section_card.dart';
import 'suggestion_text_field.dart';
import 'visual_fields.dart';
import '../../core/app_theme.dart';

/// Schema 驱动数据编辑器：左侧条目列表 + 右侧字段表单。
class SchemaEditorView extends StatefulWidget {
  const SchemaEditorView({
    super.key,
    required this.state,
    required this.cfgName,
    this.onPreview,
    this.onOpenSearch,
    this.classic = false,
    this.embedInCard = false,
    this.selectedId,
    this.onSelectedIdChanged,
    this.reloadToken = 0,
    this.onDirtyChanged,
  });
  final AppState state;
  final String cfgName;

  /// 脏状态上报（阶段 2b）：宿主（编辑区页签）据此在关闭/切换页签前
  /// 弹确认，避免「切页签即丢改动」被静默吞掉。
  final ValueChanged<bool>? onDirtyChanged;

  /// 事件预览回调：cfgName 为 EvtCfg 且用户点击「预览」时携带当前条目 ID 触发。
  final ValueChanged<String>? onPreview;

  /// 剧情库检索回调（EvtCfg 工具卡「剧情库检索」跳转）。
  final VoidCallback? onOpenSearch;

  /// 经典布局：以卡片（SectionCard）形式呈现编辑区。
  final bool classic;

  /// 直接内嵌于现有卡片中，无需自身再包裹外层 SectionCard。
  final bool embedInCard;

  /// 外部指定的当前选中条目 ID。
  final String? selectedId;

  /// 选中条目变更回调。
  final ValueChanged<String?>? onSelectedIdChanged;

  /// 外部刷新信号（撤销/重做成功后自增）：变化时重新加载磁盘内容并更新 mtime。
  final int reloadToken;

  /// 测试探针（性能 P0-1）：本视图 State 的 build 次数。仅供 Widget 测试
  /// 断言「dirty 期间连续编辑不再触发全视图重建」，不参与任何 UI 逻辑。
  static int debugBuildCount = 0;

  @override
  State<SchemaEditorView> createState() => _SchemaEditorViewState();
}

class _SchemaEditorViewState extends State<SchemaEditorView> {
  Map<String, dynamic> _data = {};
  bool _loaded = false;
  bool _missing = false; // 配置表文件尚不存在（保存后自动创建）
  String? _error;
  String? _selectedId;
  bool _dirty = false;
  // 误操作保护：加载时记录的磁盘 mtime（保存时回传做乐观锁冲突检测）
  int? _mtimeNs;
  // 性能：条目列表排序与过滤缓存，避免每帧重算
  List<String> _sortedIds = [];
  String _filter = '';
  List<String> _filteredIds = [];
  // 字段键与类型缓存
  List<String>? _cachedFieldKeys;
  String? _cachedFieldKeysCfg;
  final Map<String, String> _fieldTypeCache = {};
  // ID 引用候选缓存：cfg → [(id, 预览)]（懒加载，跨字段共享）
  final Map<String, List<(String, String)>> _idCandidatesCache = {};
  // EvtCfg 官方基础 ID 缓存（懒加载一次，失败记为空集）
  Set<int>? _cachedBaseIds;

  // ---------------- 阶段 2a：Mod 串档守卫 ----------------
  // 当前 _data 所属的 modRoot。外部切换（模组页 / AI 面板的 setMod）会
  // 把服务端沙箱根切走，而本视图仍持旧 Mod 的数据；此时保存 = 旧数据写
  // 新沙箱（串档）。与 story_flow_workspace 同一策略：监听 AppState，弹
  // 确认重载；用户选「先留在旧画面」则记下 root 禁保存（_save 拒绝）。
  String? _loadedModRoot;
  String? _externalModRefusedRoot;

  // ---------------- 阶段 2b：保存链路加固 ----------------
  bool _saving = false; // 重入门：双击/移动端连点保存按钮时直接忽略

  // 编辑代数：每次真实编辑事件 +1（新增/删除条目与字段编辑都算）。
  // 注意不能只在 clean→dirty 转变时递增：唯一消费点 _saveInner 用
  // 「发送时快照 vs 当前值」判断在途保存期间有无新编辑，若 dirty 期间
  // 编辑不推进代数，保存响应会把在途的新编辑误标成已落盘并清 dirty。
  int _editGen = 0;

  void _setDirty(bool v) {
    if (_dirty == v) return;
    _dirty = v;
    widget.onDirtyChanged?.call(v);
  }

  /// 字段编辑回调统一入口：推进编辑代数 + 首次置脏。
  ///
  /// 性能 P0-1：已脏时只推进代数、不再 setState——dirty 期间每键一次的
  /// 全视图重建会让所有字段行走 didUpdateWidget/文本同步链路。代数前进
  /// 本身不依赖重建（在途保存的 dirty 守卫照常工作），首次 clean→dirty
  /// 的那次重建保留（脏标记 UI 需要它）。
  void _markDirty() {
    _editGen++;
    if (_dirty) return;
    setState(() => _setDirty(true));
  }

  void _notify(String msg, fluent.InfoBarSeverity sev) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) =>
          fluent.InfoBar(title: Text(msg), severity: sev),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onAppStateChanged);
    _load();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onAppStateChanged);
    _filterDebounce?.cancel();
    super.dispose();
  }

  /// AppState 广播（AA 轮询等也会触发）：只关心 modRoot 是否已不属于我。
  void _onAppStateChanged() {
    if (!mounted) return;
    if (widget.state.modRoot == _loadedModRoot) return;
    if (widget.state.modRoot == _externalModRefusedRoot) return; // 已选先留在旧画面
    _reloadForExternalMod();
  }

  Future<void> _reloadForExternalMod() async {
    if (_dirty) {
      final action = await fluent.showDialog<String>(
        context: context,
        builder: (ctx) => fluent.ContentDialog(
          title: const Text('Mod 已被外部切换'),
          content: const Text(
            '当前视图仍显示旧 Mod 的未保存修改，但保存目标已随 Mod 切换变更，'
            '继续编辑会把旧数据写进新 Mod。是否放弃这些修改并重载？',
            style: TextStyle(fontSize: 12.5),
          ),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx, 'later'),
              child: const Text('先留在旧画面'),
            ),
            fluent.Button(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: const Text('放弃并重载'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (action != 'discard') {
        _externalModRefusedRoot = widget.state.modRoot;
        _notify('视图已陈旧，保存被禁止，直到重载新 Mod',
            fluent.InfoBarSeverity.warning);
        return;
      }
    }
    await _load();
    if (!mounted) return;
    _notify('已跟随外部切换到 Mod：${widget.state.modName}',
        fluent.InfoBarSeverity.success);
  }

  void _rebuildSortedIds() {
    final ids = _data.keys.toList();
    ids.sort((a, b) {
      final na = int.tryParse(a);
      final nb = int.tryParse(b);
      if (na != null && nb != null) return na.compareTo(nb);
      if (na != null) return -1;
      if (nb != null) return 1;
      return a.compareTo(b);
    });
    _sortedIds = ids;
    _applyFilter();
    _cachedFieldKeys = null;
    _fieldTypeCache.clear();
  }

  // C8：筛选输入防抖 —— 过滤是全表扫（ID + 每条记录的字符串值），大表
  // （近 10 万条）每键一次根本扛不住，所以文本变化只记词，停顿 220ms 后
  // 才真正过滤；dispose 时取消未到期的回调。
  Timer? _filterDebounce;

  /// 最近一次真正应用到 [_filteredIds] 的查询词（trim + lower 后），
  /// 防抖到期时若查询没变就直接跳过，避免重复全表扫。
  String _appliedFilter = '';

  /// 筛选框输入回调：只记录查询并重置防抖，不立即扫表。
  void _onFilterChanged(String v) {
    _filter = v;
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      if (_filter.trim().toLowerCase() == _appliedFilter) return;
      setState(_applyFilter);
    });
  }

  void _applyFilter() {
    final q = _filter.trim().toLowerCase();
    _appliedFilter = q;
    if (q.isEmpty) {
      // 空查询直接复用排序结果引用：两个列表此后都只被 ListView 只读消费
      // （唯一写入点就是这里），为 98,963 项再复制一份纯属每键一次的浪费。
      _filteredIds = _sortedIds;
      return;
    }
    _filteredIds = _sortedIds.where((id) {
      if (id.toLowerCase().contains(q)) return true;
      final rec = _data[id];
      if (rec is Map) {
        for (final v in rec.values) {
          if (v is String && v.toLowerCase().contains(q)) return true;
          if (v is List && v.toString().toLowerCase().contains(q)) return true;
        }
      }
      return false;
    }).toList();
  }

  List<String> get _fieldKeys {
    if (_cachedFieldKeys != null && _cachedFieldKeysCfg == widget.cfgName) {
      return _cachedFieldKeys!;
    }
    final schema = widget.state.gameSchema[widget.cfgName];
    List<String> out;
    if (schema is Map) {
      out = schema.keys.cast<String>().toList();
    } else {
      final seen = <String>{};
      for (final rec in _data.values) {
        if (rec is Map) seen.addAll(rec.keys.cast<String>());
      }
      out = seen.toList();
    }
    _cachedFieldKeys = out;
    _cachedFieldKeysCfg = widget.cfgName;
    return out;
  }

  String? _fieldType(String key) {
    final cached = _fieldTypeCache[key];
    if (cached != null) return cached;
    String result;
    final schema = widget.state.gameSchema[widget.cfgName];
    if (schema is Map) {
      final t = schema[key];
      if (t is String) {
        _fieldTypeCache[key] = t;
        return t;
      }
    }
    final v = _selectedRecord?[key];
    if (v is List) {
      result = v.isNotEmpty && v.first is List ? '2D Array' : '1D Array';
    } else {
      result = v is num ? 'Number' : 'String';
    }
    _fieldTypeCache[key] = result;
    return result;
  }

  Map<String, dynamic>? get _selectedRecord {
    final id = _selectedId;
    if (id == null) return null;
    final v = _data[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  @override
  void didUpdateWidget(covariant SchemaEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cfgName != widget.cfgName) {
      _load();
    } else if (oldWidget.reloadToken != widget.reloadToken) {
      // 撤销/重做强制刷新：有未保存改动时先问，不静默覆盖（阶段 2b）。
      if (_dirty) {
        _confirmReloadFromDisk();
      } else {
        _load();
      }
    } else if (widget.selectedId != null && widget.selectedId != _selectedId) {
      setState(() => _selectedId = widget.selectedId);
    }
  }

  Future<void> _confirmReloadFromDisk() async {
    final action = await fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('磁盘内容已变化'),
        content: Text(
          '撤销/重做等操作已改写磁盘上的 ${widget.cfgName}，'
          '而当前视图有未保存修改。重载将放弃本地修改。',
          style: const TextStyle(fontSize: 12.5),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('保留我的修改'),
          ),
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'reload'),
            child: const Text('放弃并重载'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'reload') await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loaded = false;
      _missing = false;
      _error = null;
    });
    // 请求发起时锁定服务端沙箱根：响应回来后数据就属于它。
    final reqRoot = widget.state.modRoot;
    try {
      // S3：经典编辑器确实需要全表 → getBig 把 40MB 解码搬进后台 isolate
      final r = await ApiClient.instance.getBig('/api/cfg/${widget.cfgName}');
      if (!mounted) return;
    setState(() {
      _idCandidatesCache.clear(); // 配置表重载后候选缓存失效
      _data = (r['data'] as Map).cast<String, dynamic>();
      _mtimeNs = r['mtime_ns'] is int ? r['mtime_ns'] as int : null;
      _missing = r['exists'] == false;
      _loaded = true;
      _loadedModRoot = reqRoot;
      _externalModRefusedRoot = null;
      _rebuildSortedIds();
      if (widget.selectedId != null && _data.containsKey(widget.selectedId)) {
        _selectedId = widget.selectedId;
      } else {
        _selectedId = _sortedIds.isNotEmpty ? _sortedIds.first : null;
      }
      _setDirty(false);
    });
      if (widget.onSelectedIdChanged != null) {
        widget.onSelectedIdChanged!(_selectedId);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loaded = true;
      });
    }
  }

  Future<void> _save({bool force = false}) async {
    // 重入门（阶段 2b）：校验弹窗、409 冲突弹窗、网络往返都是多个 await，
    // 期间按钮仍可点——双击会产生两个 PUT 竞写同一张表。
    if (_saving) return;
    // 串档守卫（阶段 2a）：外部切了 Mod 而用户选了「先留在旧画面」——
    // 此时保存 = 旧 Mod 数据写进新沙箱。
    if (_loadedModRoot != null && widget.state.modRoot != _loadedModRoot) {
      _notify(
        'Mod 已在别处切换，视图仍为旧 Mod 数据，禁止保存——请重载后再试',
        fluent.InfoBarSeverity.error,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _saveInner(force: force);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveInner({required bool force}) async {
    // 保存前指南校验：请求失败（网络/后端旧版本）时静默降级，直接保存不阻塞
    List<Map<String, dynamic>>? issues;
    try {
      // 性能 P0-3：校验请求同样携带全表 _data，jsonEncode 走 postRaw 的
      // 后台 isolate，不在 UI isolate 上冻结输入。
      final r = await ApiClient.instance
          .postRaw('/api/validate', body: {'cfg': widget.cfgName, 'data': _data})
          .timeout(const Duration(seconds: 30));
      final raw = r is Map ? r['issues'] : null;
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) list.add(Map<String, dynamic>.from(e));
        }
      }
      issues = list;
    } catch (_) {
      issues = null;
    }
    if (!mounted) return;

    var nError = 0;
    var nWarn = 0;
    var nInfo = 0;
    if (issues != null) {
      for (final e in issues) {
        final level = e['level']?.toString();
        if (level == 'error') {
          nError++;
        } else if (level == 'warn') {
          nWarn++;
        } else {
          nInfo++;
        }
      }
      if (nError > 0 && await SaveValidatePrefs.load()) {
        // 严格模式：错误阻止保存，弹窗确认（可选择「仍要保存」强制继续）
        final proceed = await _showValidateConfirm(issues, nError, nWarn, nInfo);
        if (!proceed || !mounted) return;
      }
    }

    var retryForce = force;
    for (var attempt = 0;; attempt++) {
      // 非阻塞保存（性能 P0-3）：整表 jsonEncode 由 putRaw 搬进后台
      // isolate（compute），40MB 表在 UI isolate 上曾是数秒冻结。
      // 此前这里还先做 jsonDecode(jsonEncode(_data)) 快照；现直接发
      // _data，编码期间用户继续编辑最多把当次键入混进本次保存，
      // 而「响应后是否清 dirty」由下面的 genAtSend 守卫兜住：发送后
      // 推进的新编辑保持 dirty，由下次保存带走。
      final genAtSend = _editGen;
      try {
        final resp = await ApiClient.instance.putRaw(
          '/api/cfg/${widget.cfgName}',
          body: {
            'data': _data,
            // 乐观锁：加载时的磁盘 mtime，被外部改写时后端返回 409
            'expect_mtime_ns': _mtimeNs,
            if (retryForce) 'force': true,
          },
        );
        if (!mounted) return;
        if (resp is Map && resp['mtime_ns'] is int) {
          _mtimeNs = resp['mtime_ns'] as int;
        }
        // 在途无新编辑才认定已落盘；有则保持 dirty（下次保存带走）。
        if (_editGen == genAtSend) _setDirty(false);
        // 结果提示：错误/警告优先于成功提示
        if (nError > 0) {
          _notify('已保存，但指南校验发现 $nError 个错误',
              fluent.InfoBarSeverity.warning);
        } else if (nWarn > 0) {
          final extra = nInfo > 0 ? '、$nInfo 条提示' : '';
          _notify('已保存，但有 $nWarn 条警告$extra',
              fluent.InfoBarSeverity.warning);
        } else {
          _notify('已保存', fluent.InfoBarSeverity.success);
        }
        return;
      } on ApiException catch (e) {
        if (!mounted) return;
        if (e.statusCode == 409 && attempt == 0) {
          // 误操作保护：文件已被外部修改（可能被游戏或其他端改写）
          final action = await _showConflictDialog(widget.cfgName);
          if (!mounted) return;
          if (action == 'reload') {
            await _load(); // 重新加载磁盘内容（放弃本地修改）
            return;
          }
          if (action == 'force') {
            retryForce = true; // 强制覆盖：仅重试一轮
            continue;
          }
          return;
        }
        _notify('保存失败：$e', fluent.InfoBarSeverity.error);
        return;
      } catch (e) {
        if (!mounted) return;
        _notify('保存失败：$e', fluent.InfoBarSeverity.error);
        return;
      }
    }
  }

  /// 保存冲突（HTTP 409）弹窗：重新加载（放弃本地修改）或强制覆盖。
  Future<String?> _showConflictDialog(String cfgName) {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('文件冲突'),
        content: Text(
          '$cfgName 文件已被外部修改（可能被游戏或其他端改写）。\n'
          '重新加载将放弃本地未保存的修改；强制覆盖将用当前编辑内容覆盖磁盘文件。',
          style: TextStyle(fontSize: 12.5, color: palette.textPrimary, height: 1.5),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'reload'),
            child: const Text('重新加载(放弃本地修改)'),
          ),
          fluent.Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'force'),
            child: const Text('强制覆盖'),
          ),
        ],
      ),
    );
  }

  Future<void> _addEntry() async {
    final id = (await _nextId()).toString();
    if (!mounted) return;
    setState(() {
      _data[id] = {'id': id};
      _rebuildSortedIds();
      _selectedId = id;
      _editGen++; // 新增条目是真实编辑：推进代数（P0-1，见 _markDirty 注释）
      _setDirty(true);
    });
  }

  /// 删除条目：先确认（阶段 2b）。点选列表项右侧的删除图标曾是直接
  /// 生效的，误触一次就把整条记录从内存里抹掉（保存后即丢数据）。
  Future<void> _deleteEntry(String id) async {
    final rec = _data[id];
    final name = rec is Map
        ? KeyTranslator(widget.state).entryName(id, rec.cast<String, dynamic>())
        : '#$id';
    final ok = await fluent.showDialog<bool>(
          context: context,
          builder: (ctx) => fluent.ContentDialog(
            title: const Text('删除条目'),
            content: Text(
              '确定删除 $name（ID: $id）？保存后该条目将从磁盘移除。',
              style: const TextStyle(fontSize: 12.5),
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              fluent.FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ==
        true;
    if (!ok || !mounted) return;
    setState(() {
      _data.remove(id);
      _rebuildSortedIds();
      if (_selectedId == id) {
        _selectedId = _sortedIds.isNotEmpty ? _sortedIds.first : null;
      }
      _editGen++; // 删除条目是真实编辑：推进代数（P0-1，见 _markDirty 注释）
      _setDirty(true);
    });
  }

  /// 计算新建条目 ID：EvtCfg/TalkCfg/OptionCfg 按官方指南格式，其余表 max+1。
  /// - EvtCfg：随机 1XXXXXX（7 位首位 1），避开已有键与官方基础 ID，重试 200 次后回退 max+1；
  /// - TalkCfg/OptionCfg：事件前缀（现有 ID 前 7 位众数，默认 1000000）+ 001~999 / 01~99；
  /// - 其他表：max+1。
  Future<int> _nextId() async {
    switch (widget.cfgName) {
      case 'EvtCfg':
        return _nextEvtId();
      case 'TalkCfg':
      case 'OptionCfg':
        return _nextDerivedId();
      default:
        return _maxIdPlus1();
    }
  }

  /// 现有键中的最大数值 ID + 1（兜底策略）。
  int _maxIdPlus1() {
    var maxId = 0;
    for (final k in _data.keys) {
      final n = int.tryParse(k);
      if (n != null && n > maxId) maxId = n;
    }
    return maxId + 1;
  }

  /// EvtCfg：随机 1XXXXXX，避开表内已有键与官方基础 ID（懒加载缓存一次）。
  Future<int> _nextEvtId() async {
    final existing = <int>{};
    for (final k in _data.keys) {
      final n = int.tryParse(k);
      if (n != null) existing.add(n);
    }
    if (_cachedBaseIds == null) {
      var baseIds = const <int>{};
      try {
        final r = await ApiClient.instance
            .get('/api/base_ids', query: {'cfg': 'EvtCfg'})
            .timeout(const Duration(seconds: 5));
        final ids = r is Map ? r['ids'] : null;
        if (ids is List) {
          baseIds = ids.whereType<num>().map((e) => e.toInt()).toSet();
        }
      } catch (_) {
        // 后端不可用/旧版本：忽略，仅按表内键避让
      }
      _cachedBaseIds = baseIds;
    }
    final baseIds = _cachedBaseIds ?? const <int>{};
    final rnd = Random();
    for (var i = 0; i < 200; i++) {
      final candidate = 1000000 + rnd.nextInt(1000000);
      if (!existing.contains(candidate) && !baseIds.contains(candidate)) {
        return candidate;
      }
    }
    return _maxIdPlus1();
  }

  /// TalkCfg/OptionCfg：事件前缀（现有 ID 前 7 位众数）+ 未占用序号（001~999 / 01~99）。
  int _nextDerivedId() {
    final prefixCount = <String, int>{};
    for (final k in _data.keys) {
      // 仅统计 8 位以上的纯数字 ID（前 7 位为事件 ID，其后为序号）
      if (k.length < 8 || !RegExp(r'^\d+$').hasMatch(k)) continue;
      final p = k.substring(0, 7);
      prefixCount[p] = (prefixCount[p] ?? 0) + 1;
    }
    String bestPrefix = '1000000';
    var bestCount = 0;
    for (final e in prefixCount.entries) {
      if (e.value > bestCount) {
        bestCount = e.value;
        bestPrefix = e.key;
      }
    }
    final seqWidth = widget.cfgName == 'TalkCfg' ? 3 : 2;
    final seqMax = widget.cfgName == 'TalkCfg' ? 999 : 99;
    for (var seq = 1; seq <= seqMax; seq++) {
      final candidate = '$bestPrefix${seq.toString().padLeft(seqWidth, '0')}';
      if (!_data.containsKey(candidate)) {
        return int.tryParse(candidate) ?? _maxIdPlus1();
      }
    }
    return _maxIdPlus1(); // 序号全部占用：回退 max+1
  }

  /// ID 引用候选：cfg → [(id, 预览)]。
  /// 本表已加载时直接用 _data 生成（预览取条目名前 20 字，与 /api/cfg_ids 规则一致）；
  /// 其他表懒加载 GET /api/cfg_ids 并缓存；失败返回空列表，不阻塞输入。
  Future<List<(String, String)>> _loadIdCandidates(String cfg) async {
    if (cfg == widget.cfgName) {
      final translator = KeyTranslator(widget.state);
      final out = <(String, String)>[];
      for (final id in _sortedIds) {
        final rec = _data[id];
        var preview = '';
        if (rec is Map) {
          final name = translator.entryName(id, rec.cast<String, dynamic>());
          if (name != '#$id') preview = name;
        }
        out.add((id, preview.length > 20 ? preview.substring(0, 20) : preview));
      }
      return out;
    }
    final cached = _idCandidatesCache[cfg];
    if (cached != null) return cached;
    try {
      final r = await ApiClient.instance
          .get('/api/cfg_ids', query: {'name': cfg})
          .timeout(const Duration(seconds: 5));
      final out = <(String, String)>[];
      final items = r is Map ? r['items'] : null;
      if (items is List) {
        for (final e in items) {
          if (e is Map) {
            out.add((
              e['id']?.toString() ?? '',
              e['preview']?.toString() ?? '',
            ));
          }
        }
      }
      _idCandidatesCache[cfg] = out;
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 指南校验未通过弹窗：返回 true 表示用户选择「仍要保存」。
  Future<bool> _showValidateConfirm(
    List<Map<String, dynamic>> issues,
    int nError,
    int nWarn,
    int nInfo,
  ) async {
    final result = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => fluent.ContentDialog(
        title: const Text('指南校验未通过'),
        content: SizedBox(
          // 固定 480 宽在手机屏直接横向溢出（保存校验在手机端可达），
          // 桌面维持 480，窄屏贴边（同选图器公式）。
          width: min(480, MediaQuery.sizeOf(ctx).width - 72),
          height: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '发现 $nError 个错误、$nWarn 条警告、$nInfo 条提示'
                '（依据官方《学生时代》Mod 指南）。',
                style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: palette.border),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: issues.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: palette.card),
                    itemBuilder: (context, i) => _buildIssueRow(issues[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回编辑'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍要保存'),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// 单条校验问题行：按 level 着色（error 红 / warn 黄 / info 灰）。
  Widget _buildIssueRow(Map<String, dynamic> issue) {
    final level = issue['level']?.toString() ?? 'info';
    final msg = issue['msg']?.toString() ?? '';
    final rid = issue['rid']?.toString() ?? '';
    Color color;
    String label;
    if (level == 'error') {
      color = palette.statusDanger;
      label = '错误';
    } else if (level == 'warn') {
      color = palette.statusWarn;
      label = '警告';
    } else {
      color = palette.textSecondary;
      label = '提示';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              rid.isNotEmpty ? '$msg（$rid）' : msg,
              style: TextStyle(
                fontSize: 12,
                color: palette.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    SchemaEditorView.debugBuildCount++; // 测试探针（P0-1）
    if (!_loaded) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          '加载失败: $_error',
          style: TextStyle(color: palette.textSecondary, fontSize: 13),
        ),
      );
    }
    final translator = KeyTranslator(widget.state);
    if (widget.embedInCard) {
      return _buildEmbeddedEditor(translator);
    }
    if (widget.classic) {
      return _buildClassicEditor(translator);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左侧条目列表
        // 移动端占满全宽：Row 给非弹性子项无界宽度约束，不能用 double.infinity
        SizedBox(
          width: isMobileWidth(context)
              ? MediaQuery.sizeOf(context).width
              : 260,
          child: Column(
            children: [
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${widget.cfgName}（${_data.length}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textSecondary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (widget.cfgName == 'EvtCfg' &&
                        widget.onPreview != null &&
                        _selectedId != null) ...[
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => widget.onPreview!(_selectedId!),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: palette.tintAccent,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: palette.accentDeep,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  FluentIcons.play_24_regular,
                                  size: 12,
                                  color: palette.accentLight,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  '预览',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: palette.accentLighter,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _addEntry,
                        // 裸 15px 图标当按钮手机几乎点不中：加内衬扩到 ≥40 热区。
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: EdgeInsets.all(isMobileWidth(context) ? 12 : 0),
                          child: Icon(
                            FluentIcons.add_24_regular,
                            size: isMobileWidth(context) ? 20 : 15,
                            color: palette.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_missing)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: palette.tintWarn,
                  child: Text(
                    '该配置表尚不存在，添加条目并保存后将自动创建',
                    style: TextStyle(fontSize: 11, color: palette.warning),
                  ),
                ),
              // 筛选
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: fluent.TextBox(
                  placeholder: '筛选 ID/标题…',
                  onChanged: _onFilterChanged,
                  suffix: const Icon(FluentIcons.search_24_regular, size: 12),
                ),
              ),
              Divider(height: 1, color: palette.border),
              Expanded(
                child: ListView.builder(
                  itemCount: _filteredIds.length,
                  itemExtent: isMobileWidth(context) ? 64 : 52,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
                  itemBuilder: (context, i) {
                    final id = _filteredIds[i];
                    final rec = _data[id];
                    return _buildEntryTile(id, rec, translator);
                  },
                ),
              ),
            ],
          ),
        ),
        if (!isMobileWidth(context)) ...[
          VerticalDivider(width: 1, color: palette.border),
          // 右侧字段表单
          Expanded(
          child: _selectedRecord == null
              ? Center(
                  child: Text(
                    '选择左侧条目进行编辑',
                    style: TextStyle(color: palette.textHint, fontSize: 13),
                  ),
                )
              : Column(
                  children: [
                    Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Text(
                            '字段编辑',
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          if (_dirty) ...[
                            Text(
                              '有未保存修改',
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.warning,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          fluent.FilledButton(
                            onPressed: _saving ? null : () => _save(),
                            style: const fluent.ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 4,
                                ),
                              ),
                            ),
                            child: const Text(
                              '保存',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: palette.border),
                    Expanded(
                      child: _FieldForm(
                        cfgName: widget.cfgName,
                        record: _selectedRecord!,
                        fieldKeys: _fieldKeys,
                        fieldType: _fieldType,
                        translator: translator,
                        gameDicts: widget.state.gameDicts,
                        loadIdCandidates: _loadIdCandidates,
                        onChanged: _markDirty,
                        noCodeMode: widget.state.noCodeMode,
                      ),
                    ),
                  ],
                ),
          ),
        ],
      ],
    );
  }

  /// 条目列表项（标题 + ID + 删除）。
  Widget _buildEntryTile(String id, dynamic rec, KeyTranslator translator) {
    final name = rec is Map
        ? translator.entryName(id, rec.cast<String, dynamic>())
        : '#$id';
    final selected = id == _selectedId;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _selectEntry(id, translator),
        child: Container(
          color: selected ? palette.hover : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: selected
                            ? palette.textHigh
                            : palette.textPrimary,
                      ),
                    ),
                    Text(
                      'ID: $id',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.textHint,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => _deleteEntry(id),
                // 行内 14px 删除图标手机易误触相邻的「选中条目」手势：
                // 移动端扩出 ≥44 宽热区。
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.all(isMobileWidth(context) ? 15 : 0),
                  child: Icon(
                    FluentIcons.delete_24_regular,
                    size: isMobileWidth(context) ? 17 : 14,
                    color: palette.textHint,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 移动端：点条目进入独立表单页。
  void _selectEntry(String id, KeyTranslator translator) {
    setState(() => _selectedId = id);
    if (isMobileWidth(context)) {
      _openMobileForm(translator);
    }
  }

  /// 移动端表单页（独立路由，返回后停留在列表）。
  void _openMobileForm(KeyTranslator translator) {
    final rec = _selectedRecord;
    final id = _selectedId;
    if (rec == null || id == null) return;
    
    // 获取当前条目在列表中的索引，用于返回后保持选中状态
    final currentIndex = _sortedIds.indexOf(id);
    
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _MobileFormPage(
          cfgName: widget.cfgName,
          record: rec,
          entryTitle: translator.entryName(id, rec),
          fieldKeys: _fieldKeys,
          fieldType: _fieldType,
          translator: translator,
          gameDicts: widget.state.gameDicts,
          loadIdCandidates: _loadIdCandidates,
          currentIndex: currentIndex,
          totalItems: _sortedIds.length,
          noCodeMode: widget.state.noCodeMode,
          onChanged: _markDirty,
          onSave: () => _save(),
        ),
      ),
    );
  }

  /// 经典布局的编辑区：📚 条目列表卡 + 📝 字段编辑卡（EvtCfg 另有 🧰 工具卡）。
  Widget _buildClassicEditor(KeyTranslator translator) {
    final showTools =
        (widget.cfgName == 'EvtCfg' && widget.onPreview != null) ||
        widget.onOpenSearch != null;
    final tools = <Widget>[
      if (widget.cfgName == 'EvtCfg' && widget.onPreview != null) ...[
        _ClassicToolButton(
          emoji: '▶',
          label: '预览选中事件',
          onPressed: _selectedId == null
              ? null
              : () => widget.onPreview!(_selectedId!),
        ),
        const SizedBox(height: 8),
      ],
      if (widget.onOpenSearch != null) ...[
        _ClassicToolButton(
          emoji: '🔍',
          label: '剧情库检索',
          onPressed: widget.onOpenSearch,
        ),
        const SizedBox(height: 8),
      ],
      if (showTools)
        Text(
          '更多高级工具（剧本导入导出、批量处理等）请在创作布局中使用。',
          style: TextStyle(fontSize: 11, color: palette.textMuted, height: 1.5),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: SectionCard(
              title: '📚 ${widget.cfgName} 条目列表',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _ClassicToolButton(
                        emoji: '➕',
                        label: '新建条目',
                        primary: true,
                        onPressed: _addEntry,
                      ),
                      const SizedBox(width: 8),
                      _ClassicToolButton(
                        emoji: '🗑️',
                        label: '删除选中',
                        onPressed: _selectedId == null
                            ? null
                            : () => _deleteEntry(_selectedId!),
                      ),
                      if (widget.cfgName == 'EvtCfg' &&
                          widget.onPreview != null &&
                          _selectedId != null) ...[
                        const SizedBox(width: 12),
                        _ClassicToolButton(
                          emoji: '▶',
                          label: '预览',
                          onPressed: () => widget.onPreview!(_selectedId!),
                        ),
                      ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_missing)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: palette.tintWarn,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '该配置表尚不存在，添加条目并保存后将自动创建',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.warning,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _filteredIds.length,
                      itemExtent: 52,
                      addAutomaticKeepAlives: false,
                      itemBuilder: (context, i) {
                        final id = _filteredIds[i];
                        final rec = _data[id];
                        return _buildEntryTile(id, rec, translator);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: SectionCard(
              title: '📝 字段编辑',
              child: _selectedRecord == null
                  ? Center(
                      child: Text(
                        '选择左侧条目进行编辑',
                        style: TextStyle(
                          color: palette.textHint,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _FieldForm(
                            cfgName: widget.cfgName,
                            record: _selectedRecord!,
                            fieldKeys: _fieldKeys,
                            fieldType: _fieldType,
                            translator: translator,
                            gameDicts: widget.state.gameDicts,
                            loadIdCandidates: _loadIdCandidates,
                            onChanged: _markDirty,
                            classic: true,
                            noCodeMode: widget.state.noCodeMode,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (_dirty)
                              Text(
                                '有未保存修改',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.warning,
                                ),
                              ),
                            const Spacer(),
                          ],
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: fluent.FilledButton(
                            onPressed: _saving ? null : () => _save(),
                            child: Text('💾 保存修改至 ${widget.cfgName}'),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          if (showTools) ...[
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: SectionCard(
                title: '🧰 工具',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: tools,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 直接内嵌在父卡片中的表单与保存操作（无重复外边距与卡片套卡片）。
  Widget _buildEmbeddedEditor(KeyTranslator translator) {
    if (_selectedRecord == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.edit_24_regular, size: 36, color: palette.iconDisabled),
            const SizedBox(height: 8),
            Text(
              _data.isEmpty ? '该配置表暂无数据，请新建条目' : '请在左侧选择条目进行编辑',
              style: TextStyle(color: palette.textHint, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _FieldForm(
            cfgName: widget.cfgName,
            record: _selectedRecord!,
            fieldKeys: _fieldKeys,
            fieldType: _fieldType,
            translator: translator,
            gameDicts: widget.state.gameDicts,
            loadIdCandidates: _loadIdCandidates,
            onChanged: _markDirty,
            classic: true,
            noCodeMode: widget.state.noCodeMode,
          ),
        ),
        const SizedBox(height: 8),
        if (_dirty)
          Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              '● 有未保存修改',
              style: TextStyle(fontSize: 11, color: palette.warning),
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 32,
          child: fluent.FilledButton(
            onPressed: _saving ? null : () => _save(),
            style: fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(accentColor),
            ),
            child: Text('💾 保存修改至 ${widget.cfgName}'),
          ),
        ),
      ],
    );
  }
}

/// 移动端字段编辑页：AppBar 返回 + 保存，正文为字段表单。
class _MobileFormPage extends StatelessWidget {
  const _MobileFormPage({
    required this.cfgName,
    required this.record,
    required this.entryTitle,
    required this.fieldKeys,
    required this.fieldType,
    required this.translator,
    required this.gameDicts,
    required this.loadIdCandidates,
    required this.onChanged,
    required this.onSave,
    this.currentIndex = -1,
    this.totalItems = 0,
    this.noCodeMode = false,
  });

  final String cfgName;
  final Map<String, dynamic> record;
  final String entryTitle;
  final List<String> fieldKeys;
  final String? Function(String key) fieldType;
  final KeyTranslator translator;
  final Map<String, dynamic> gameDicts;
  final Future<List<(String, String)>> Function(String cfg) loadIdCandidates;
  final VoidCallback onChanged;
  final VoidCallback onSave;
  final int currentIndex;
  final int totalItems;
  final bool noCodeMode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: palette.bgDeep2,
      appBar: AppBar(
        backgroundColor: palette.bg,
        elevation: 0,
        leading: BackButton(color: palette.textHigh),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entryTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, color: palette.textHigh),
            ),
            if (currentIndex >= 0 && totalItems > 0)
              Text(
                '第 ${currentIndex + 1} / $totalItems 条',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
          ],
        ),
        actions: [
          fluent.FilledButton(
            onPressed: onSave,
            style: const fluent.ButtonStyle(
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              ),
            ),
            child: const Text('保存', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _FieldForm(
          cfgName: cfgName,
          record: record,
          fieldKeys: fieldKeys,
          fieldType: fieldType,
          translator: translator,
          gameDicts: gameDicts,
          loadIdCandidates: loadIdCandidates,
          onChanged: onChanged,
          noCodeMode: noCodeMode,
        ),
      ),
    );
  }
}

/// 经典布局的编辑区工具按钮（emoji + 文字，可禁用）。
class _ClassicToolButton extends StatelessWidget {
  const _ClassicToolButton({
    required this.emoji,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String emoji;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final bg = primary ? accentColor : palette.card;
    final fg = primary ? palette.onAccent : palette.textPrimary;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onPressed : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(5),
              border: primary
                  ? null
                  : Border.all(color: palette.borderHover),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldForm extends StatefulWidget {
  const _FieldForm({
    required this.cfgName,
    required this.record,
    required this.fieldKeys,
    required this.fieldType,
    required this.translator,
    required this.gameDicts,
    required this.onChanged,
    required this.loadIdCandidates,
    this.classic = false,
    this.noCodeMode = false,
  });
  final String cfgName;
  final Map<String, dynamic> record;
  final List<String> fieldKeys;
  final String? Function(String key) fieldType;
  final KeyTranslator translator;
  final Map<String, dynamic> gameDicts;
  final VoidCallback onChanged;

  /// ID 引用候选加载器：cfg → [(id, 预览)]（上层懒加载 + 缓存）。
  final Future<List<(String, String)>> Function(String cfg) loadIdCandidates;

  /// 经典布局：以两列表格（属性名称 | 属性值）呈现字段。
  final bool classic;

  /// 无代码模式（后端共享开关）：效果字段点选 + 参数表单，人物字段出浏览面板。
  final bool noCodeMode;

  @override
  State<_FieldForm> createState() => _FieldFormState();
}

class _FieldFormState extends State<_FieldForm> {
  final ScrollController _scrollCtrl = ScrollController();

  // 编辑页「查找字段」：输入即过滤当前条目的字段（模糊匹配标签/键/帮助/类型）。
  // 只作用于本表单的展示，不修改数据；空查询时原样展示全部字段。
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _FieldForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换到另一条记录时清空查找词，避免上一条的过滤把新条目的字段藏起来。
    // 以 record['id'] 判定条目变化：record 是调用方每次 build 用 .cast() 新建
    // 的视图，对象 identity 每次重建都会变，不能拿来判断。
    if ((oldWidget.cfgName != widget.cfgName ||
            oldWidget.record['id'] != widget.record['id']) &&
        _searchQuery.isNotEmpty) {
      _searchCtrl.clear();
      _searchQuery = '';
    }
  }

  /// 当前查找词过滤后的字段列表；空查询原样返回（保持 schema/表单顺序）。
  ///
  /// 结果按相关度降序；同分时按字段原始顺序稳定排列，避免同类字段被打散。
  List<String> _visibleFieldKeys(List<String> fieldKeys) {
    final q = _searchQuery.trim();
    if (q.isEmpty) return fieldKeys;
    final scored = <(int, String, int)>[]; // (原序号, key, 得分)
    for (var i = 0; i < fieldKeys.length; i++) {
      final key = fieldKeys[i];
      final type = widget.fieldType(key) ?? 'String';
      final score = fuzzyFieldScore(
        query: q,
        label: widget.translator.translate(key, widget.cfgName),
        key: key,
        help: _getHelpText(widget.cfgName, key, type),
        type: type,
      );
      if (score != null) scored.add((i, key, score));
    }
    scored.sort((a, b) {
      final d = b.$3.compareTo(a.$3);
      return d != 0 ? d : a.$1.compareTo(b.$1);
    });
    return [for (final e in scored) e.$2];
  }

  void _clearFieldSearch() {
    _searchCtrl.clear();
    setState(() => _searchQuery = '');
  }

  /// 表单顶部的字段查找框：模糊搜索 + 命中计数 + 一键清除。
  Widget _buildSearchBar({required int matchCount, required int total}) {
    final active = _searchQuery.trim().isNotEmpty;
    return Padding(
      padding: widget.classic
          ? const EdgeInsets.fromLTRB(14, 8, 14, 8)
          : const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: fluent.TextBox(
              controller: _searchCtrl,
              placeholder: '查找可编辑字段（支持模糊搜索）…',
              prefix: const Icon(FluentIcons.search_24_regular, size: 12),
              suffix: active
                  ? MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _clearFieldSearch,
                        behavior: HitTestBehavior.opaque,
                        child: Icon(
                          FluentIcons.dismiss_24_regular,
                          size: 12,
                          color: palette.textMuted,
                        ),
                      ),
                    )
                  : null,
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          if (active) ...[
            const SizedBox(width: 8),
            Text(
              '$matchCount / $total',
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  /// 查找无结果时的占位（保留清除入口，避免用户以为字段消失了）。
  Widget _buildNoFieldMatch() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.search_24_regular,
              size: 28,
              color: palette.iconDisabled,
            ),
            const SizedBox(height: 8),
            Text(
              '没有匹配「$_searchQuery」的字段',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: palette.textMuted),
            ),
            const SizedBox(height: 8),
            fluent.Button(
              onPressed: _clearFieldSearch,
              child: const Text('清除查找', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  /// 查找时高亮命中片段；无查找词或未命中时退回普通 [Text]（保持布局不变）。
  Widget _highlightedText(
    String text, {
    required TextStyle style,
    int? maxLines = 1,
    TextOverflow? overflow = TextOverflow.ellipsis,
  }) {
    final q = _searchQuery.trim();
    if (q.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }
    final ranges = fuzzyMatchRanges(q, text);
    if (ranges.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in ranges) {
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(TextSpan(
        text: text.substring(start, end),
        style: TextStyle(
          color: accentColor,
          fontWeight: FontWeight.bold,
        ),
      ));
      cursor = end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }


  /// 获取友好的帮助文本。
  ///
  /// 注意传的是**字段键**（key）而不是显示名：显示名是 KeyTranslator 翻出来的
  /// 中文（如 name → "名称"），拿它去查英文键表永远不会命中。具体判定序见
  /// [fieldHelpText]。
  String _getHelpText(String cfgName, String key, String type) {
    return fieldHelpText(cfgName, key, type, rule: fieldRuleFor(cfgName, key));
  }


  @override
  Widget build(BuildContext context) {
    final fieldKeys = widget.fieldKeys;
    final record = widget.record;
    final gameDicts = widget.gameDicts;
    // 只要有字段就启用查找框（之前 condition > 1 会导致单字段配置表无法显示搜索框）。
    final searchEnabled = fieldKeys.isNotEmpty;
    final visibleKeys =
        searchEnabled ? _visibleFieldKeys(fieldKeys) : fieldKeys;
    final searching = searchEnabled && _searchQuery.trim().isNotEmpty;
    if (widget.classic) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (searchEnabled)
            _buildSearchBar(
              matchCount: visibleKeys.length,
              total: fieldKeys.length,
            ),
          Expanded(
            child: visibleKeys.isEmpty && searching
                ? _buildNoFieldMatch()
                : _buildClassicTable(visibleKeys, record, gameDicts),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (searchEnabled)
          _buildSearchBar(
            matchCount: visibleKeys.length,
            total: fieldKeys.length,
          ),
        Expanded(
          child: visibleKeys.isEmpty && searching
              ? _buildNoFieldMatch()
              : fluent.Scrollbar(
                  controller: _scrollCtrl,
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                    itemCount: visibleKeys.length + 1,
                    itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Text(
                              'ID: ${record['id'] ?? record.keys.first}',
                              style: TextStyle(
                                fontSize: 14,
                                color: palette.textHigh,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              widget.cfgName,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.textHint,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final key = visibleKeys[i - 1];
                    final type = widget.fieldType(key) ?? 'String';
                    final label =
                        widget.translator.translate(key, widget.cfgName);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                flex: 2,
                                child: _highlightedText(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: palette.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: _highlightedText(
                                  key,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: palette.textFaint,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '[$type]',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.textFaint,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _getHelpText(widget.cfgName, key, type),
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.textMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _FieldInput(
                            cfgName: widget.cfgName,
                            fieldKey: key,
                            value: record[key],
                            type: type,
                            rule: fieldRuleFor(widget.cfgName, key),
                            gameDicts: gameDicts,
                            idCandidates: widget.loadIdCandidates,
                            noCodeMode: widget.noCodeMode,
                            onChanged: (v) {
                              record[key] = v;
                              widget.onChanged();
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
        ),
      ],
    );
  }

  /// 经典布局：两列表格（属性名称 | 属性值）。
  /// ListView.builder：索引 0 = ID 行，1 = 表头，≥2 = 字段行。字段多的表
  /// 不再一次性构建全部行 widget，只构建视口内的。
  Widget _buildClassicTable(
    List<String> fieldKeys,
    Map<String, dynamic> record,
    Map<String, dynamic> gameDicts,
  ) {
    Widget buildRow(int index) {
      if (index == 0) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  'ID: ${record['id'] ?? record.keys.first}',
                  style: TextStyle(
                    fontSize: 13,
                    color: palette.textHigh,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  widget.cfgName,
                  style: TextStyle(
                    fontSize: 11,
                    color: palette.textHint,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      if (index == 1) {
        return Container(
          color: palette.card,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  '属性名称',
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                flex: 7,
                child: Text(
                  '属性值',
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }
      final key = fieldKeys[index - 2];
      final type = widget.fieldType(key) ?? 'String';
      final help = _getHelpText(widget.cfgName, key, type);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: palette.card, width: 1),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _highlightedText(
                    widget.translator.translate(key, widget.cfgName),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 2),
                  _highlightedText(
                    key,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: palette.textFaint,
                    ),
                  ),
                  if (help.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Tooltip(
                      message: help,
                      child: Text(
                        help,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.3,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 7,
              child: _FieldInput(
                cfgName: widget.cfgName,
                fieldKey: key,
                value: record[key],
                type: type,
                rule: fieldRuleFor(widget.cfgName, key),
                gameDicts: gameDicts,
                idCandidates: widget.loadIdCandidates,
                noCodeMode: widget.noCodeMode,
                onChanged: (v) {
                  record[key] = v;
                  widget.onChanged();
                },
              ),
            ),
          ],
        ),
      );
    }

    return fluent.Scrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: EdgeInsets.zero,
        itemCount: fieldKeys.length + 2,
        itemBuilder: (_, index) => buildRow(index),
      ),
    );
  }
}

class _FieldInput extends StatefulWidget {
  const _FieldInput({
    required this.cfgName,
    required this.value,
    required this.type,
    required this.onChanged,
    this.rule,
    this.gameDicts = const {},
    this.fieldKey,
    this.idCandidates,
    this.noCodeMode = false,
  });
  /// 所属配置表名：效果/条件类字段判定要用（与剧情图共用规则表）。
  final String cfgName;
  final dynamic value;
  final String type;
  final ValueChanged<dynamic> onChanged;
  final FieldRule? rule;
  final Map<String, dynamic> gameDicts;
  /// 原始字段 key，用于决定走 effect/condition/cost 哪套提示
  final String? fieldKey;

  /// 无代码模式：效果字段点选（空输入出候选 + 参数表单），人物字段出浏览面板。
  final bool noCodeMode;

  /// ID 引用候选加载器（rule.idRefCfg 指定的配置表，懒加载 + 上层缓存）。
  final Future<List<(String, String)>> Function(String cfg)? idCandidates;
  @override
  State<_FieldInput> createState() => _FieldInputState();
}

class _FieldInputState extends State<_FieldInput> {
  late final TextEditingController _ctrl;
  late final FocusNode _focusNode = FocusNode();
  // ID 引用候选（异步加载后填充）
  List<(String, String)> _idOpts = const [];

  /// 贴图类字段：cfg:key → 选图写回时的 url 路径前缀（'' = 原样写回）。
  /// 本体数据 url 均无扩展名（bg/img_keting、role_male、cg/xxx），与 AA 索引
  /// key 只差路径前缀；选中 key 已带前缀时原样保留。
  static const Map<String, String> _kTexFieldPrefix = {
    'PersonCfg:url': '',
    'PersonCfg:url2': '',
    'BgCfg:url': 'bg/',
    'CGCfg:urls': 'cg/',
    'CGCfg:url': 'cg/',
    // 新纳入编辑页的贴图字段：前缀未对本体数据核实，一律原样写回。
    'RenshengguanMemoryCfg:url': '',
    'NewsCfg:img': '',
    'NewsCfg:big': '',
    'BirthdayPaintCfg:img': '',
    'FishCfg:icon': '',
    'ExploreCfg:icon': '',
    'ExpoSiteCfg:icon': '',
    'DIYCfg:icon': '',
    'DIYRankCfg:bgurl': '',
    'ClubDailyCfg:icon': '',
    'HandicraftMiniGameCfg:icon': '',
    'NegotiationUniqueCardCfg:icon': '',
    'KZoneAvatarCfg:icon': '',
    'ModFaceCfg:icon': '',
    'ModFaceCfg:icon_xx': '',
    'ModFaceCfg:photobooth': '',
  };

  /// 当前字段是否贴图类；是则返回写回前缀。
  String? get _texFieldPrefix {
    final key = (widget.fieldKey ?? '').toLowerCase();
    return _kTexFieldPrefix['${widget.cfgName}:$key'];
  }

  /// TalkCfg.bg：Number 引用 bg id，选图后按合并 bgKeys 反查 id 写回。
  bool get _isTalkBg => widget.cfgName == 'TalkCfg' && (widget.fieldKey ?? '') == 'bg';

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ValueCodec.encode(widget.value));
    _loadIdOpts();
  }

  @override
  void didUpdateWidget(covariant _FieldInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文本与值已语义等价时不回写（如数组输入的中间态 "1," 对应值 [1]）：
    // 回写会把半截输入规范化（"1," → "1"）并把光标弹到末尾，破坏连续输入。
    // 仅包裹文本同步；下方的 idRefCfg 重载不能跳过——ListView.builder 复用
    // 本 State 渲染不同字段时 rule 可能变化，必须无条件检查。
    if (ValueCodec.needsResync(_ctrl.text, widget.value, widget.type)) {
      final enc = ValueCodec.encode(widget.value);
      if (_ctrl.text != enc) {
        _ctrl.text = enc;
      }
    }
    // 切换到不同 ID 引用来源的字段时重新加载候选
    if (widget.rule?.idRefCfg != oldWidget.rule?.idRefCfg) {
      _idOpts = const [];
      _loadIdOpts();
    }
  }

  /// 异步加载 ID 引用候选（失败时保持为空，不影响输入）。
  Future<void> _loadIdOpts() async {
    final cfg = widget.rule?.idRefCfg;
    final loader = widget.idCandidates;
    if (cfg == null || loader == null) return;
    try {
      final opts = await loader(cfg);
      if (!mounted) return;
      setState(() => _idOpts = opts);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 字典/ID 引用候选：token 与候选 ID、名称做包含匹配（大小写不敏感），
  /// 上限 50 与剧情图同一取舍。匹配读 [_optIndexLower]（随 [_options] 同步
  /// 刷新，小写化已完成），ListView.builder 跨字段复用本 State 时自动跟随
  /// 当前字段。
  Future<List<Suggestion>> _suggestCandidates(SuggestionQuery q) async {
    final token = q.token.trim().toLowerCase();
    if (token.isEmpty) return const [];
    final out = <Suggestion>[];
    for (final (id, idLower, name, nameLower) in _optIndexLower) {
      if (!idLower.contains(token) && !nameLower.contains(token)) continue;
      out.add(Suggestion(id, name));
      if (out.length >= 50) break;
    }
    return out;
  }

  /// 候选源要跨帧同标识：补全框按 identical 比较 source，方法 tear-off 每次
  /// 求值都是新对象，父级一次 setState 就把用户正开着的候选浮层清掉
  /// （与 effect_hint_field 的 `_source`、剧情图 deps 缓存同一契约）。
  late final SuggestionSource _suggestSource = _suggestCandidates;

  // C9：_options() 结果缓存 —— build 里它会被调两次（hasDictOptions + opts），
  // 每次都物化并排序整个字典（近千项），随 build 次数线性浪费。key 捕捉全部
  // 输入的身份：rule（fieldRuleFor 返回规则表中的稳定实例）、异步候选列表、
  // gameDicts 对象。字典内容被原地修改时不会自动失效（与 _cachedFieldKeys
  // 等既有缓存同一边界）；宿主整体替换 gameDicts 实例即失效。
  (FieldRule?, List<(String, String)>, Map<String, dynamic>)? _optCacheKey;
  List<(String, String)> _optCache = const [];

  /// 选项 id → 名称索引：_namePreview 按 token 查名由 O(选项数·token 数)
  /// 线性扫降为 O(1)，且不随 build 次数增长。与 [_optCache] 同步更新。
  Map<String, String> _optIndex = const {};

  /// 小写匹配索引：(id, id小写, 名称, 名称小写)，与 [_optIndex] 同步、同序。
  /// [_suggestCandidates] 键入时零分配匹配，不再对全字典逐项 toLowerCase。
  List<(String, String, String, String)> _optIndexLower = const [];

  /// 下拉选项：(id, 名称)。来自固定选项或 game_dicts 字典。
  /// 结果已缓存：同一 (rule, 候选, 字典) 身份返回同一列表实例，调用方只读。
  List<(String, String)> _options() {
    final key = (widget.rule, _idOpts, widget.gameDicts);
    if (key == _optCacheKey) return _optCache;
    final out = <(String, String)>[];
    final rule = widget.rule;
    if (rule != null) {
      final fixed = rule.fixed;
      if (fixed != null) {
        for (final e in fixed.entries) {
          out.add((e.key, e.value));
        }
      } else {
        if (rule.idRefCfg != null) {
          // ID 引用字段：候选由上层异步加载（本表数据或 /api/cfg_ids）
          out.addAll(_idOpts);
        }
        // 退回字典：既服务纯 dictName 字段，也兜住 idRefCfg 指向的表还没数据
        // 的场景（如 TalkCfg:audio 同时声明 audios 字典与 AudioCfg 表）。
        if (out.isEmpty) _addDictOptions(rule.dictName, out);
      }
      out.sort((a, b) {
        final an = int.tryParse(a.$1);
        final bn = int.tryParse(b.$1);
        if (an != null && bn != null) return an.compareTo(bn);
        return a.$1.compareTo(b.$1);
      });
    }
    _optCacheKey = key;
    _optCache = out;
    _optIndex = {for (final o in out) o.$1: o.$2};
    _optIndexLower = [
      for (final (id, name) in out) (id, id.toLowerCase(), name, name.toLowerCase()),
    ];
    return out;
  }

  /// game_dicts 字典候选（'actions' 由行动表另行供给，这里不掺和）。
  void _addDictOptions(String? name, List<(String, String)> out) {
    if (name == null || name == 'actions') return;
    final dict = widget.gameDicts[name];
    if (dict is! Map) return;
    for (final e in dict.entries) {
      final v = e.value;
      var label = v.toString();
      if (v is List && v.isNotEmpty) label = v.first.toString();
      out.add((e.key.toString(), label));
    }
  }

  /// 下拉候选渲染上限（性能 P0-2）：fluent.ComboBox 非虚拟化，候选全量
  /// 物化会让近千项字典在每次 build/打开下拉时都卡。超过上限只渲染前
  /// [_kMaxComboItems] 项；有当前值时把它置顶（去重），保证截断后
  /// ComboBox 的 value 仍能匹配、选中项始终可见。≤ 上限原样返回零开销。
  static const int _kMaxComboItems = 200;

  List<(String, String)> _comboItems(
      List<(String, String)> opts, String currentId) {
    final pinned = (currentId.isNotEmpty && _optIndex.containsKey(currentId))
        ? (currentId, _optIndex[currentId] ?? '')
        : null;
    if (opts.length <= _kMaxComboItems &&
        (pinned == null || (opts.isNotEmpty && opts.first.$1 == currentId))) {
      return opts;
    }
    final seen = <String>{if (pinned != null) currentId};
    final out = <(String, String)>[];
    if (pinned != null) out.add(pinned);
    for (final o in opts) {
      if (!seen.add(o.$1)) continue; // 已置顶的当前值去重
      out.add(o);
      if (out.length >= _kMaxComboItems) break;
    }
    return out;
  }

  /// 名称预览：把输入中的 ID 解析成「ID → 名称」（支持逗号/分号/顿号多值）。
  /// 查名走 [_optIndex]（与最近一次 [_options()] 同步），不逐 token 线性扫。
  String? _namePreview(String text) {
    if ((widget.rule?.dictName == null && widget.rule?.idRefCfg == null) ||
        _optIndex.isEmpty) {
      return null;
    }
    final tokens = text
        .split(RegExp(r'[;，、,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;
    final parts = <String>[];
    for (final t in tokens) {
      final name = _optIndex[t];
      if (name == null) {
        parts.add('$t → 未找到');
      } else {
        parts.add(name.isEmpty ? t : '$t → $name');
      }
    }
    return parts.join('，');
  }

  /// 弹出「ID · 预览」候选列表（可多选），确定后追加为逗号分隔多值。
  Future<void> _pickIdsFromList() async {
    // 无代码模式下有专用面板的种类（人物/道具/背景…）：换成实体浏览面板。
    if (widget.noCodeMode && _entityKind != null) return _pickEntity();
    final cfg = widget.rule?.idRefCfg;
    if (cfg == null) return;
    final opts = _options();
    if (opts.isEmpty) return;
    final picked = await fluent.showDialog<List<String>>(
      context: context,
      builder: (ctx) => _IdPickerDialog(title: '选择 $cfg ID', options: opts),
    );
    if (!mounted) return;
    if (picked == null || picked.isEmpty) return;
    final existing = _ctrl.text
        .split(RegExp(r'[;，、,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    // P0-2：合并去重用 Set 查找，替代对 existing 的逐项 List.contains。
    final existingSet = existing.toSet();
    final merged = [...existing, ...picked.where((e) => !existingSet.contains(e))];
    final newText = merged.join(', ');
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(offset: newText.length);
    try {
      widget.onChanged(ValueCodec.decode(newText, widget.type));
    } catch (_) {}
    setState(() {});
  }

  /// 本字段的实体种类（无代码模式浏览面板入口）；null = 没有专用面板，
  /// 沿用既有的 ID 浏览对话框。
  EntityKind? get _entityKind => entityKindForRule(widget.rule);

  /// 无代码模式「选 X」：实体浏览面板（人物是立绘网格、背景带缩略图）选 id 写回。
  /// Number/String 单选替换；数组类多选并入现值（已含项置灰防重复）。
  Future<void> _pickEntity() async {
    final kind = _entityKind;
    if (kind == null) return;
    final single = widget.type == 'Number' || widget.type == 'String';
    final existing = _ctrl.text
        .split(RegExp(r'[;，、,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final ids = await showEntityPicker(
      context,
      kind: kind,
      multi: !single,
      title: '选择${kind.label}',
      exclude: single ? const {} : existing.toSet(),
      gameDicts: widget.gameDicts,
    );
    if (!mounted || ids == null || ids.isEmpty) return;
    if (single) {
      final id = ids.first;
      if (widget.type == 'Number') {
        widget.onChanged(num.tryParse(id) ?? id);
      } else {
        try {
          widget.onChanged(ValueCodec.decode(id, widget.type));
        } catch (_) {}
      }
      _ctrl.text = id;
    } else {
      final merged = {...existing, ...ids}.join(', ');
      _ctrl.text = merged;
      _ctrl.selection = TextSelection.collapsed(offset: merged.length);
      try {
        widget.onChanged(ValueCodec.decode(merged, widget.type));
      } catch (_) {}
    }
    setState(() {});
  }

  /// 音频候选池：game_dicts['audios']（后端由 AudioCfg 合并而成）。
  /// 无代码模式给「key 命中音频命名但字段没有 dictName 规则」的字段（vocals /
  /// music / entersound…）留一条只选不敲的通道。
  List<(String, String)> _audioPool() {
    final dict = widget.gameDicts['audios'];
    if (dict is! Map) return const [];
    final out = <(String, String)>[];
    for (final e in dict.entries) {
      final v = e.value;
      var label = v.toString();
      if (v is List && v.isNotEmpty) label = v.first.toString();
      out.add((e.key.toString(), label));
    }
    out.sort((a, b) {
      final an = int.tryParse(a.$1);
      final bn = int.tryParse(b.$1);
      if (an != null && bn != null) return an.compareTo(bn);
      return a.$1.compareTo(b.$1);
    });
    return out;
  }

  /// 无代码模式选音频：从音频池里挑（可先试听），Number 直接写 id；
  /// 数组（vocals 这类 [声ID, 音量] 扁平对）只替换首个 token，音量原样保留。
  Future<void> _pickAudioId() async {
    final pool = _audioPool();
    if (pool.isEmpty) return;
    final picked = await showIdBrowseDialog(
      context,
      title: '选择音频',
      options: pool,
      multi: false,
      initialSelected: _firstToken().isEmpty ? const [] : [_firstToken()],
      audition: true,
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    final id = picked.first;
    if (widget.type == 'Number') {
      widget.onChanged(num.tryParse(id) ?? id);
      _ctrl.text = id;
      setState(() {});
      return;
    }
    final tokens = fieldTextTokens(_ctrl.text);
    if (tokens.isEmpty) {
      tokens.add(id);
    } else {
      tokens[0] = id;
    }
    _applyTokens(tokens);
  }
  /// 当前值的首个 token（缩略图与选图追加的基准）。
  String _firstToken() {
    final tokens = _ctrl.text
        .split(RegExp(r'[;，、,\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return tokens.isEmpty ? '' : tokens.first;
  }

  // ── M1 全字段可视化输入 ──────────────────────────────────────────────

  /// 本字段的可视化形态（判定真源在 field_meta，与剧情图共用）。
  FieldVisual? get _visual => fieldVisualFor(
      widget.cfgName, widget.fieldKey ?? '', widget.type, widget.rule);

  /// Number 当前值（步进框显示值与试听 ID 的同一来源）。
  num? get _numberValue {
    final v = widget.value;
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  /// 有序 ID 列表整体重写文本框并回写值（chips 移序/移除与浏览对话框共用）。
  void _applyTokens(List<String> tokens) {
    final newText = tokens.join(', ');
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(offset: newText.length);
    try {
      widget.onChanged(ValueCodec.decode(newText, widget.type));
    } catch (_) {}
    setState(() {});
  }

  /// 浏览对话框：Number 单选即写回；数组类多选（按对话框内顺序写回）。
  Future<void> _browseIds() async {
    final opts = _options();
    if (opts.isEmpty) return;
    final single = widget.type == 'Number';
    final picked = await showIdBrowseDialog(
      context,
      title: '浏览候选（${widget.rule?.idRefCfg ?? widget.rule?.dictName ?? ''}）',
      options: opts,
      multi: !single,
      initialSelected: single
          ? (_firstToken().isEmpty ? const [] : [_firstToken()])
          : fieldTextTokens(_ctrl.text),
      audition: _visual == FieldVisual.audioPick,
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    if (single) {
      final id = picked.first;
      final n = num.tryParse(id);
      widget.onChanged(n ?? id);
      _ctrl.text = id;
      setState(() {});
    } else {
      _applyTokens(picked);
    }
  }

  /// M3：从本地导入音频（后端顺手登记 AudioCfg）并把 audio_id 写回字段。
  /// Number 字段直接写 id；1D Array（vocals 组）按序追加（去重）。登记失败
  /// 时文件已落盘，提示用户到 AudioCfg 手动补登记。
  Future<void> _importLocalAudio() async {
    final saved =
        await importLocalAssets(context, kind: 'audio', registerAudio: true);
    if (!mounted || saved.isEmpty) return;
    final id = saved.first['audio_id'];
    if (id == null) {
      await fluent.showDialog<void>(
        context: context,
        builder: (ctx) => fluent.ContentDialog(
          title: const Text('音频已写入，登记失败'),
          content: Text(
              '文件已存为 ${saved.first['path'] ?? '（未知路径）'}，但自动登记 AudioCfg 未成功，请手动补一条 AudioCfg 并填入该路径。'),
          actions: [
            fluent.Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final idText = '$id';
    if (widget.type == '1D Array') {
      final tokens = fieldTextTokens(_ctrl.text);
      if (tokens.contains(idText)) return;
      _applyTokens([...tokens, idText]);
    } else {
      final n = num.tryParse(idText);
      widget.onChanged(n ?? idText);
      _ctrl.text = idText;
      setState(() {});
    }
  }

  /// 贴图类字段「选图」：打开共享大窗口选择器，确认后按前缀约定写回。
  Future<void> _pickTexFromAssets() async {
    final prefix = _texFieldPrefix;
    if (prefix == null) return;
    final picked = await showImageAssetPicker(
      context,
      title: '选择图片资源',
      multiSelect: widget.type == '1D Array',
      initialSelected: [_firstToken()],
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    final values = [
      for (final k in picked)
        (prefix.isEmpty || k.startsWith(prefix)) ? k : '$prefix$k',
    ];
    String newText;
    if (widget.type == '1D Array') {
      final existing = _ctrl.text
          .split(RegExp(r'[;，、,\n]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !values.contains(e))
          .toList();
      newText = [...existing, ...values].join(', ');
    } else {
      newText = values.first;
    }
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(offset: newText.length);
    try {
      widget.onChanged(ValueCodec.decode(newText, widget.type));
    } catch (_) {}
    setState(() {});
  }

  /// TalkCfg.bg「选背景图」：选中 tex key 后按合并 bgKeys 反查 bg id 写回。
  Future<void> _pickBgForTalk() async {
    final picked = await showImageAssetPicker(context, title: '选择背景图片');
    if (!mounted || picked == null || picked.isEmpty) return;
    final id = await bgIdForKey(picked.first);
    if (!mounted) return;
    if (id == null) {
      fluent.displayInfoBar(
        context,
        builder: (_, close) => const fluent.InfoBar(
          title: Text('未在 BgCfg（mod + 本体）中找到该图片对应的背景记录'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }
    widget.onChanged(num.tryParse(id) ?? id);
    _ctrl.text = id;
    setState(() {});
  }

  /// bg id 当前值缩略图的单击预览：反查 key 后复用贴图预览；
  /// 顺带惰性拉取 bg 地图，供 BgIdThumb 随下次重建显示。
  Future<void> _previewBgId(String id) async {
    final map = await loadBgIdKeyMap();
    final key = id.isEmpty ? null : map?[id];
    if (!mounted) return;
    setState(() {});
    if (key == null || key.isEmpty) {
      fluent.displayInfoBar(
        context,
        builder: (_, close) => fluent.InfoBar(
          title: Text('bg id $id 没有对应的图片资源'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }
    await _previewTexValue(key);
  }

  /// 贴图字段当前值缩略图（60×45，单击预览大图；空值显示占位）。
  Widget _texThumbSlot() {
    final raw = _firstToken();
    return GestureDetector(
      onTap: raw.isEmpty ? null : () => _previewTexValue(raw),
      child: TexThumb(
        keyName: raw,
        width: 60,
        height: 45,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  /// 单击字段缩略图 → 大图预览。
  Future<void> _previewTexValue(String raw) async {
    final src = await TexBytesCache.loadSmartSource(raw);
    if (!mounted) return;
    if (src == null || src.isEmpty) {
      fluent.displayInfoBar(
        context,
        builder: (_, close) => fluent.InfoBar(
          title: Text('图片不可用：$raw（资源缺失或索引未就绪）'),
          severity: fluent.InfoBarSeverity.warning,
        ),
      );
      return;
    }
    final screen = MediaQuery.sizeOf(context);
    await fluent.showDialog<void>(
      context: context,
      builder: (_) => fluent.ContentDialog(
        title: Text(raw,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: min(860, screen.width - 80),
          height: min(620, screen.height - 120),
          child: src.bytes != null
              ? ImagePreview(bytes: src.bytes!, name: raw)
              : InteractiveViewer(
                  maxScale: 6,
                  child: Center(
                      child: TexSourceImage(source: src, fit: BoxFit.contain)),
                ),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 2D Array 优先走友商同款效果提示（候选+校验），与友商 SmartTemplateEditor 对齐
    final hasDictOptions = _options().isNotEmpty;
    final rawKey = widget.fieldKey ?? '';
    final k = rawKey.toLowerCase();
    // 「效果/条件/指令」类判定统一用 field_meta，与剧情图共用同一份规则表
    final effectLike = isEffectLikeField(widget.cfgName, rawKey, widget.type);
    // 无代码模式的渲染分流（schema 编辑器 / 剧情图内联 / Inspector 唯一真源）
    final noCodeShape =
        noCodeShapeFor(widget.cfgName, rawKey, widget.type, widget.rule);
    // roles（TalkCfg.roles 指令行）/ screenEffect（1D 扁平代码）同样走效果提示；
    // 其余 1D Array 沿用原编辑区的裸文本框，本次去重不顺手改已有渲染。
    final isActionOrScreen = k == 'roles' || k == 'screeneffect';
    final useEffectHint = !hasDictOptions &&
        ((effectLike && (widget.type == '2D Array' || isActionOrScreen)) ||
            (k.isEmpty && widget.type == '2D Array'));

    // 无代码模式 + 码字段：内联积木编辑，**没有任何文本输入**。
    // 规则类字段（shape=reference/visual）不在此列，由下方下拉/浏览分支处理。
    if (widget.noCodeMode && noCodeShape == NoCodeShape.blocks) {
      final fieldKey = rawKey.isEmpty ? 'effect' : rawKey;
      return NoCodeEffectField(
        value: widget.value,
        type: widget.type,
        cfg: widget.cfgName,
        fieldKey: fieldKey,
        mode: effectSuggestMode(widget.cfgName, fieldKey),
        gameDicts: widget.gameDicts,
        onChanged: widget.onChanged,
        onDisableNoCode: _leaveNoCodeMode,
      );
    }

    if (useEffectHint) {
      final fieldKey = widget.fieldKey ?? 'effect';
      return EffectHintField(
        key: ValueKey('hint_${fieldKey}_${widget.type}'),
        value: widget.value,
        type: widget.type,
        fieldKey: fieldKey,
        // 模式也交给 field_meta 推断（roles→action、screenEffect→screen…），
        // 与 EffectHintField 内部的兜底推断同解
        mode: effectSuggestMode(widget.cfgName, fieldKey),
        noCodeMode: widget.noCodeMode,
        gameDicts: widget.gameDicts,
        onChanged: widget.onChanged,
      );
    }
    final opts = _options();
    final isSingleArray =
        widget.type == '1D Array' && widget.rule?.singleArray == true;
    final isStringFixed = widget.type == 'String' && widget.rule?.fixed != null;
    final texPrefix = _texFieldPrefix;
    // Number / 单选 1D Array / String 固定选项 有选项时显示下拉框（旁边保留文本框可自定义输入）。
    if (opts.isNotEmpty &&
        (widget.type == 'Number' || isSingleArray || isStringFixed)) {
      String currentId;
      if (widget.type == 'Number') {
        currentId = widget.value == null ? '' : ValueCodec.encode(widget.value);
      } else if (isSingleArray) {
        final v = widget.value;
        currentId = (v is List && v.isNotEmpty) ? v.first.toString() : '';
      } else {
        currentId = widget.value == null ? '' : ValueCodec.encode(widget.value);
      }
      final currentName = _optIndex[currentId];
      // P0-2：存在性判断走 [_optIndex]（_options() 同步维护的 id→名称
      // 索引），替代对全候选的 any/where 线性扫——大字典每次 build 两趟 O(n)。
      final hasCurrent = currentId.isNotEmpty && _optIndex.containsKey(currentId);
      // 无代码模式：引用/枚举字段只留下拉与动作按钮——旁边的自由文本框会让用户
      // 仍然能直接敲 ID（那正是"输入代码的地方"）。Number 步进框同理去掉：
      // 对引用字段来说那个数字就是 id。
      final hideTextInput = widget.noCodeMode && widget.rule != null;
      return Row(
        children: [
          // 窄屏加固（H）：下拉用 Flexible 包裹——宽屏仍 ≤220，窄屏先收缩让位
          // 给动作按钮，避免固定 220 把行撑溢出。
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220, minWidth: 120),
              child: fluent.ComboBox<String>(
              value: hasCurrent ? currentId : null,
              isExpanded: true,
              placeholder: Text(
                currentName != null && currentName.isNotEmpty
                    ? '$currentId · $currentName'
                    : (currentId.isNotEmpty
                        ? currentId
                        : (hideTextInput ? '选择 ID' : '选择或输入 ID')),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              items: [
                for (final o in _comboItems(opts, currentId))
                  fluent.ComboBoxItem(
                    value: o.$1,
                    child: Text(
                      o.$2.isEmpty ? o.$1 : '${o.$1} · ${o.$2}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) {
                  if (widget.type == 'Number') {
                    widget.onChanged(num.tryParse(v) ?? v);
                  } else if (isSingleArray) {
                    // 1D Array 单选：写入单元素数组
                    widget.onChanged(<dynamic>[num.tryParse(v) ?? v]);
                  } else {
                    // String 固定选项：原样写入
                    widget.onChanged(v);
                  }
                  _ctrl.text = v;
                  setState(() {}); // 本行 name 预览/选中态随自身重建刷新（P0-1 后父级不再逐键重建）
                }
              },
            ),
          ),
          ),
          if (!hideTextInput) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // M1：Number 字段升级为步进框（手输精确值能力保留）。
                  if (widget.type == 'Number')
                    NumberStepField(
                      value: _numberValue,
                      hint: kFieldNumericHints['${widget.cfgName}:$rawKey'],
                      onChanged: (n) {
                        widget.onChanged(n);
                        _ctrl.text = n.toString();
                        setState(() {});
                      },
                    )
                  else
                    fluent.TextBox(
                      controller: _ctrl,
                      onChanged: (_) {
                        widget.onChanged(
                          ValueCodec.decode(_ctrl.text, widget.type),
                        );
                        setState(() {});
                      },
                    ),
                  if (_namePreview(_ctrl.text) case final preview?)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        preview,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          // 窄屏加固（H）：尾部动作改为可换行的 Wrap——宽屏单行排布与原先
          // 视觉一致，窄屏自动折行，杜绝固定按钮组把行撑溢出。
          Flexible(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_isTalkBg) ...[
                  // 当前背景缩略图（单击预览大图）
                  GestureDetector(
                    onTap:
                        currentId.isNotEmpty ? () => _previewBgId(currentId) : null,
                    child: BgIdThumb(id: currentId),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: fluent.Button(
                      onPressed: _pickBgForTalk,
                      child:
                          const Text('选背景图', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ] else if (texPrefix != null && isSingleArray) ...[
                  _texThumbSlot(),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: fluent.Button(
                      onPressed: _pickTexFromAssets,
                      child: const Text('选图', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
                // 无代码模式：引用字段（人物/道具/背景/地图/属性/职业/关系/回合/
                // 事件类型）走实体浏览面板——人物是立绘网格、背景带缩略图。
                if (widget.noCodeMode && _entityKind != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: fluent.Button(
                      onPressed: _pickEntity,
                      child: Text('选${_entityKind!.label}',
                          style: const TextStyle(fontSize: 11)),
                    ),
                  ),
                // M1：音频引用行内试听（当前 ID 的字节可播即可点）+ M3 本地导入
                if (_visual == FieldVisual.audioPick) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: AudioAuditionButton(audioId: currentId),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: fluent.Button(
                      onPressed: _importLocalAudio,
                      child: const Text('导入', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
                // M1：ID 引用/跳转目标——下拉之外的有序浏览对话框（与下拉并存）
                if (_visual == FieldVisual.idBrowse ||
                    _visual == FieldVisual.jumpTarget ||
                    _visual == FieldVisual.audioPick)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: fluent.Button(
                      onPressed: opts.isEmpty ? null : _browseIds,
                      child: Text(
                        _visual == FieldVisual.jumpTarget ? '浏览跳转目标' : '浏览',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    final isArray = widget.type == '1D Array' || widget.type == '2D Array';
    final multiline = widget.type == 'String' || isArray;
    final preview = _namePreview(_ctrl.text);
    // 字典/ID 引用且有候选的 String/1D Array 字段：裸文本框升级为输入即补全
    // （Number/单选/固定选项已由上方 ComboBox 覆盖；2D 指令字段走 EffectHintField）。
    final useSuggest =
        opts.isNotEmpty && (widget.type == 'String' || widget.type == '1D Array');
    // M1：可视化形态的 Number 不再走裸文本框（有候选时由上方 ComboBox 分支接管）。
    final useNumber = widget.type == 'Number' && _visual != null;
    // ID 引用的多值字段：文本框旁提供选择入口（跳转/数组多升级为有序浏览对话框）
    final canPickIds = widget.type == '1D Array' &&
        opts.isNotEmpty &&
        (widget.rule?.idRefCfg != null ||
            _visual == FieldVisual.multiIdChips ||
            _visual == FieldVisual.jumpTarget);
    // 无代码模式：码/引用字段的裸文本框整体不渲染——只留 chips、缩略图、
    // 试听与浏览按钮；否则用户仍能直接敲 ID 或代码。
    final noCodeHideText =
        widget.noCodeMode && noCodeShape != NoCodeShape.untouched;
    // 藏掉文本框后必须至少留一条「只选不敲」的通道；通道优先级与三面共用：
    // 实体面板 > 音频池 > 字典/ID 浏览对话框（含 Number 单选）。
    final audioPool = _audioPool();
    VoidCallback? noCodePick;
    var noCodePickLabel = '浏览选择…';
    if (widget.noCodeMode && noCodeShape != NoCodeShape.untouched) {
      if (_entityKind != null) {
        noCodePick = _pickEntity;
        noCodePickLabel = '选${_entityKind!.label}';
      } else if (_visual == FieldVisual.audioPick && audioPool.isNotEmpty) {
        noCodePick = _pickAudioId;
        noCodePickLabel = '选音频';
      } else if (opts.isNotEmpty) {
        noCodePick = _browseIds;
      }
    }
    // 一条通道都没有（无候选池、无浏览/试听/选图入口）= 死路，给逃生口。
    final noCodeDeadEnd =
        noCodeHideText && !canPickIds && noCodePick == null && texPrefix == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (texPrefix != null && _ctrl.text.trim().isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _texThumbSlot(),
              ),
              const SizedBox(width: 8),
            ],
            if (!noCodeHideText)
              Expanded(
                child: useNumber
                    ? NumberStepField(
                        value: _numberValue,
                        hint: kFieldNumericHints['${widget.cfgName}:$rawKey'],
                        onChanged: (n) {
                          widget.onChanged(n);
                          _ctrl.text = n.toString();
                          setState(() {});
                        },
                      )
                    : useSuggest
                        ? SuggestionTextField(
                            controller: _ctrl,
                            focusNode: _focusNode,
                            source: _suggestSource,
                            multivalued: isArray,
                            maxLines: multiline ? 3 : 1,
                            onChanged: (_) {
                              try {
                                widget.onChanged(
                                    ValueCodec.decode(_ctrl.text, widget.type));
                              } catch (_) {}
                              setState(() {});
                            },
                          )
                        : fluent.TextBox(
                            controller: _ctrl,
                            maxLines: multiline ? 3 : 1,
                            onChanged: (_) {
                              try {
                                widget.onChanged(
                                    ValueCodec.decode(_ctrl.text, widget.type));
                              } catch (_) {}
                              setState(() {});
                            },
                          ),
              ),
            // 窄屏加固（H）：尾部动作改为可换行的 Wrap——宽屏单行与原先一致，
            // 窄屏自动折行，杜绝固定按钮组把行撑溢出。
            Flexible(
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (canPickIds)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: fluent.Button(
                        // M1：跳转目标/数组多选升级为「有序浏览」（顺序即语义）；
                        // 人物引用在无代码模式仍走立绘面板。
                        onPressed: () {
                          if (widget.noCodeMode && _entityKind != null) {
                            _pickEntity();
                          } else if (_visual == FieldVisual.jumpTarget ||
                              _visual == FieldVisual.multiIdChips) {
                            _browseIds();
                          } else {
                            _pickIdsFromList();
                          }
                        },
                        child: Text(
                          widget.noCodeMode && _entityKind != null
                              ? '选${_entityKind!.label}'
                              : _visual == FieldVisual.jumpTarget
                                  ? '浏览跳转目标'
                                  : _visual == FieldVisual.multiIdChips
                                      ? '多选'
                                      : '从列表选择',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  // M1：音频引用（无候选的 Number 或 vocals 对）——首 token 试听 + M3 导入
                  if (_visual == FieldVisual.audioPick) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: AudioAuditionButton(audioId: _firstToken()),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: fluent.Button(
                        onPressed: _importLocalAudio,
                        child: const Text('导入', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  ],
                  // 无代码模式且数组通道不可用（Number 单选 / 音频 / 无 idRefCfg 的
                  // 数组）：补一个与 chips 同源的选择入口，藏了文本框也选得到值。
                  if (!canPickIds && noCodePick != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: fluent.Button(
                        onPressed: noCodePick,
                        child: Text(noCodePickLabel,
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                  if (texPrefix != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: fluent.Button(
                        onPressed: _pickTexFromAssets,
                        child: const Text('选图', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        // M1：多值 ID 引用数组——文本框下按序展示「ID · 名称」chips，可移序/移除。
        if (_visual == FieldVisual.multiIdChips &&
            _ctrl.text.trim().isNotEmpty) ...[
          const SizedBox(height: 5),
          ValueNameChips(
            tokens: fieldTextTokens(_ctrl.text),
            nameOf: (t) => _optIndex[t],
            onRemove: (i) {
              final ts = fieldTextTokens(_ctrl.text)..removeAt(i);
              _applyTokens(ts);
            },
            onMove: (from, to) {
              final ts = fieldTextTokens(_ctrl.text);
              final id = ts.removeAt(from);
              ts.insert(to.clamp(0, ts.length), id);
              _applyTokens(ts);
            },
          ),
        ],
        if (noCodeDeadEnd) _noCodeDeadEndRow(),
        if (preview != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              preview,
              style: TextStyle(fontSize: 11, color: palette.textMuted),
            ),
          ),
      ],
    );
  }

  /// 无代码模式的死路提示：字段没有候选池、也没有浏览/试听/选图入口，
  /// 文本框又被藏起来——给出唯一可行的逃生口（关闭共享开关）。
  Widget _noCodeDeadEndRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '该字段没有可选候选；如需手写请关闭无代码模式。',
              style: TextStyle(fontSize: 10.5, color: palette.textHint),
            ),
          ),
          fluent.Button(
            onPressed: _leaveNoCodeMode,
            child: const Text('关闭无代码模式', style: TextStyle(fontSize: 10.5)),
          ),
        ],
      ),
    );
  }

  /// 逃生口：关闭共享的无代码开关（写穿后端 editor_env.json），
  /// 让当前字段回到可手写的形态。写穿失败时提示并回滚本地态。
  Future<void> _leaveNoCodeMode() => exitNoCodeMode(context);
}

/// 「从列表选择」ID 候选弹窗：关键字筛选 + 多选，确定返回所选 ID（按候选顺序）。
class _IdPickerDialog extends StatefulWidget {
  const _IdPickerDialog({required this.title, required this.options});

  final String title;
  final List<(String, String)> options;

  @override
  State<_IdPickerDialog> createState() => _IdPickerDialogState();
}

class _IdPickerDialogState extends State<_IdPickerDialog> {
  final TextEditingController _queryCtrl = TextEditingController();
  final Set<String> _selected = {};

  /// 输入防抖：过滤是对全量候选的线性扫描 + 整表重建，逐字符即时过滤在
  /// 长列表下会卡输入法，停顿 200ms 后才应用过滤词。
  Timer? _debounce;

  /// 过滤结果缓存：以数据源 identity + 长度 + 过滤词为失效判据（在 getter
  /// 里每次核对，最稳），勾选触发的 setState 直接复用上次扫描结果。
  List<(String, String)>? _filterCache;
  List<(String, String)>? _filterCacheSource;
  String _filterCacheQuery = '';

  @override
  void dispose() {
    // 防抖定时器必须随 State 释放，否则 dispose 后 setState 报错。
    _debounce?.cancel();
    _queryCtrl.dispose();
    super.dispose();
  }

  List<(String, String)> get _filtered {
    final source = widget.options;
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return source;
    if (identical(_filterCacheSource, source) &&
        _filterCacheSource!.length == source.length &&
        _filterCacheQuery == q) {
      return _filterCache!;
    }
    final result =
        source.where((o) => o.$1.contains(q) || o.$2.contains(q)).toList();
    _filterCache = result;
    _filterCacheSource = source;
    _filterCacheQuery = q;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return fluent.ContentDialog(
      title: Text(widget.title),
      content: SizedBox(
        // 候选多选弹窗（编辑器「从列表选择」在手机端可达）：固定 460 宽
        // 会溢出，桌面维持 460，窄屏贴边。
        width: min(460, MediaQuery.sizeOf(context).width - 72),
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            fluent.TextBox(
              controller: _queryCtrl,
              placeholder: '筛选 ID 或内容…',
              // 防抖：输入过程中不重建列表，停顿 200ms 后再应用过滤词。
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 200), () {
                  if (mounted) setState(() {});
                });
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        '无匹配候选',
                        style: TextStyle(fontSize: 12, color: palette.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemExtent: 34,
                      itemBuilder: (context, i) {
                        final o = items[i];
                        final selected = _selected.contains(o.$1);
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() {
                              if (selected) {
                                _selected.remove(o.$1);
                              } else {
                                _selected.add(o.$1);
                              }
                            }),
                            child: Container(
                              color: selected
                                  ? palette.tintInfo
                                  : Colors.transparent,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  fluent.Checkbox(
                                    checked: selected,
                                    onChanged: (v) => setState(() {
                                      if (v == true) {
                                        _selected.add(o.$1);
                                      } else {
                                        _selected.remove(o.$1);
                                      }
                                    }),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      o.$2.isEmpty ? o.$1 : '${o.$1} · ${o.$2}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.textPrimary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '共 ${widget.options.length} 项候选，已选 ${_selected.length} 项',
                style: TextStyle(fontSize: 11, color: palette.textHint),
              ),
            ),
          ],
        ),
      ),
      actions: [
        fluent.Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        fluent.FilledButton(
          onPressed: () => Navigator.pop(
            context,
            widget.options
                .where((o) => _selected.contains(o.$1))
                .map((o) => o.$1)
                .toList(),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

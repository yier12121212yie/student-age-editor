import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_feedback.dart';
import '../../core/app_theme.dart';
import '../../core/debouncer.dart';
import '../../core/error_text.dart';
import '../../core/models.dart';
import '../../core/workbench_controller.dart';
import '../../core/workbench_guard.dart';
import '../../core/workbench_scaffold.dart';
import '../../core/save_bar.dart';
import '../editor/section_card.dart';
import '../editor/synced_fields.dart';
import '../blocks/block_library.dart';
import '../editor/field_utils.dart';
import '../resources/image_asset_picker.dart' show TexThumb;

/// 小游戏库工作台 —— 导演布局下「小游戏」的专属界面。
///
/// 三栏：小游戏列表（搜索 / 新建 / 删除）｜小游戏详情 + 关卡编辑（第 1~5 关）｜
/// 玩法预览与统计。
///
/// 编辑两张表：`MinigameCfg`（小游戏定义）与 `MinigameActionCfg`（关卡与效果），
/// 各自整表读写（`expect_mtime_ns` 乐观锁）。`GuideCfg` / `RelationCfg` / `TalkCfg`
/// 作为只读字典（原版玩法说明、关系名、对白编号预览）。关卡效果复用「积木库」。
class MinigamesWorkbench extends StatefulWidget {
  const MinigamesWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<MinigamesWorkbench> createState() => _MinigamesWorkbenchState();
}

const _gameCfg = 'MinigameCfg';
const _actionCfg = 'MinigameActionCfg';

class _MinigamesWorkbenchState extends State<MinigamesWorkbench>
    with WorkbenchLeaveGuard<MinigamesWorkbench> {
  /// A3：可写主表（`GuideCfg` / `RelationCfg` / `TalkCfg` 为只读引用表）。
  late final WorkbenchController _ctl = WorkbenchController(
    cfgs: const [_gameCfg, _actionCfg],
    onConflict: _onConflict,
    onError: (e) {
      if (mounted) {
        AppFeedback.error(context, '保存失败：${humanizeErrorMessage(e)}',
            detail: e.toString());
      }
    },
    onSaved: (_) {},
  );

  /// 兼容旧访问点：把控制器表按名字包成 map（读取 `data` / `dirty` / `mtime`）。
  Map<String, WorkbenchTable> get _tables =>
      {for (final t in _ctl.tables) t.cfg: t};

  Map<String, dynamic> _guides = {};
  Map<String, dynamic> _relations = {};
  Map<String, dynamic> _talks = {};

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? _selGame;
  String? _selLevel;
  String _search = '';

  final TextEditingController _searchCtrl = TextEditingController();
  final Debouncer _searchDebounce = Debouncer();

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onCtl);
    _loadAll();
  }

  void _onCtl() {
    if (!mounted) return;
    setState(() {
      _loading = _ctl.loading;
      _saving = _ctl.saving;
      _error = _ctl.error?.toString();
    });
  }

  @override
  void dispose() {
    _ctl.removeListener(_onCtl);
    _ctl.dispose();
    _searchCtrl.dispose();
    _searchDebounce.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 数据
  // ------------------------------------------------------------------

  // ---- 离开守卫（切模式/切模组/刷新）：见 core/workbench_guard.dart ----
  @override
  AppState get guardAppState => widget.state;
  @override
  bool get guardDirty => _dirty;
  @override
  Future<void> guardSave() => _saveAll();
  @override
  void guardDiscard() => _discard();
  @override
  Future<void> guardReload() => _loadAll();
  @override
  String get guardSubject => '小游戏库';

  Future<void> _loadAll() async {
    try {
      final res = await Future.wait([
        _ctl.load(),
        ApiClient.instance.get('/api/cfg/GuideCfg'),
        ApiClient.instance.get('/api/cfg/RelationCfg'),
        ApiClient.instance.get('/api/cfg/TalkCfg'),
      ]);
      if (!mounted) return;
      _guides = WorkbenchController.extractData(res[1]);
      _relations = WorkbenchController.extractData(res[2]);
      _talks = WorkbenchController.extractData(res[3]);
      _ensureSelection();
    } catch (_) {
      // 错误已由控制器记录并经监听器反映到 _error。
    }
  }

  void _ensureSelection() {
    final ids = _sortedGames;
    if (_selGame == null || !_tables[_gameCfg]!.data.containsKey(_selGame)) {
      _selGame = ids.isNotEmpty ? ids.first : null;
      _selLevel = null;
    }
    final levels = _levelsOf(_selGame);
    if (_selLevel == null || !levels.contains(_selLevel)) {
      _selLevel = levels.isNotEmpty ? levels.first : null;
    }
  }

  Map<String, dynamic> _tableData(String t) =>
      _tables[t]?.data ?? <String, dynamic>{};

  bool _tableDirty(String t) => _tables[t]?.dirty ?? false;

  bool get _dirty => _ctl.dirtyDeep;

  Future<void> _saveAll() async {
    final ok = await _ctl.save();
    if (mounted && ok) AppFeedback.success(context, '小游戏库已保存');
  }

  void _discard() {
    _ctl.discard();
    _ensureSelection();
  }

  /// 409 冲突弹窗 → 控制器的 [WorkbenchConflictChoice]。
  Future<WorkbenchConflictChoice?> _onConflict(WorkbenchTable table) =>
      showWorkbenchConflictDialog(context, table);

  Future<String?> _conflictDialog(String name) {
    return fluent.showDialog<String>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('文件冲突'),
        content: Text(
          '$name 已被外部修改（可能被游戏或其他端改写）。\n'
          '重新加载将放弃本地未保存的修改；强制覆盖将用当前编辑内容覆盖磁盘文件。',
          style: TextStyle(
              fontSize: 12.5, color: palette.textPrimary, height: 1.5),
        ),
        actions: [
          fluent.Button(
            onPressed: () => Navigator.pop(ctx, 'reload'),
            child: const Text('重新加载'),
          ),
          fluent.FilledButton(
            onPressed: () => Navigator.pop(ctx, 'force'),
            child: const Text('强制覆盖'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? _rowIn(String table, String id) {
    final v = _tableData(table)[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? get _game =>
      _selGame == null ? null : _rowIn(_gameCfg, _selGame!);

  Map<String, dynamic>? get _level =>
      _selLevel == null ? null : _rowIn(_actionCfg, _selLevel!);

  List<String> get _sortedGames {
    // 排序结果按源表版本号缓存：一次 build 内多处调用共享同一份结果，
    // 源表未变时也不重排。避免每帧 O(n log n) 与重复组装。
    final rev = _ctl.table(_gameCfg).revision;
    if (rev == _sortRev) return _sortedGamesCache;
    final ids = _tableData(_gameCfg).keys.toList();
    ids.sort((a, b) =>
        (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    _sortRev = rev;
    _sortedGamesCache = ids;
    return ids;
  }

  int _sortRev = -1;
  List<String> _sortedGamesCache = const [];

  List<String> _levelsOf(String? gameId) {
    if (gameId == null) return const [];
    final g = int.tryParse(gameId);
    if (g == null) return const [];
    final ids = _tableData(_actionCfg).keys.where((k) {
      final v = int.tryParse(k);
      return v != null && v ~/ 100 == g;
    }).toList();
    ids.sort((a, b) =>
        (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return ids;
  }

  int _levelIndex(String id) => (int.tryParse(id) ?? 0) % 100;

  int _intOf(Map<String, dynamic>? row, String field, [int fallback = 0]) {
    final v = row?[field];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  List<int> _intList(Map<String, dynamic>? row, String field) {
    final v = row?[field];
    if (v is! List) return <int>[];
    return [
      for (final e in v)
        if (e is num)
          e.toInt()
        else if (int.tryParse(e.toString()) != null)
          int.parse(e.toString()),
    ];
  }

  int _nextGameId() {
    var max = 0;
    for (final k in _tableData(_gameCfg).keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return max < 4 ? 5 : max + 1;
  }

  int _nextLevelId(int gameId) {
    var max = 0;
    for (final k in _tableData(_actionCfg).keys) {
      final v = int.tryParse(k);
      if (v != null && v ~/ 100 == gameId && v % 100 > max) max = v % 100;
    }
    return gameId * 100 + (max + 1);
  }

  String _relationName(int id) {
    if (id == 0) return '无';
    final v = _relations[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '关系 $id';
  }

  Map<String, dynamic>? _guideOf(String gameId) {
    final g = int.tryParse(gameId);
    if (g == null) return null;
    // 原版玩法说明通常放在 GuideCfg 的“游戏 id × 100 + 1”。
    final v1 = _guides[(g * 100 + 1).toString()];
    if (v1 is Map) return v1.cast<String, dynamic>();
    final v0 = _guides[(g * 100).toString()];
    return v0 is Map ? v0.cast<String, dynamic>() : null;
  }

  bool _talkExists(int id) => id > 0 && _talks.containsKey(id.toString());

  String _talkLabel(int id) {
    if (id <= 0) return '无';
    return _talkExists(id) ? '$id' : '$id(缺失)';
  }

  // ------------------------------------------------------------------
  // 编辑操作
  // ------------------------------------------------------------------

  Future<void> _addGame() async {
    final id = _nextGameId();
    setState(() {
      _tableData(_gameCfg)[id.toString()] = <String, dynamic>{
        'id': id,
        'name': '新小游戏',
        'tips': '',
        'bgm': 0,
      };
      final levelId = id * 100 + 1;
      _tableData(_actionCfg)[levelId.toString()] = _defaultLevel(levelId);
      _selGame = id.toString();
      _selLevel = levelId.toString();
    });
  }

  Map<String, dynamic> _defaultLevel(int id) => <String, dynamic>{
        'id': id,
        'cost': 0,
        'effect': <dynamic>[],
        'loseTalk': 0,
        'mode': 0,
        'needRelation': 0,
        'parms': <dynamic>[],
        'startTalk': 0,
        'winTalk': 0,
      };

  void _addLevel() {
    final gameId = int.tryParse(_selGame ?? '');
    if (gameId == null) return;
    final id = _nextLevelId(gameId);
    setState(() {
      _tableData(_actionCfg)[id.toString()] = _defaultLevel(id);
      _selLevel = id.toString();
    });
  }

  Future<void> _deleteGame() async {
    final id = _selGame;
    if (id == null) return;
    final name = _game?['name']?.toString() ?? id;
    final levelCount = _levelsOf(id).length;
    final yes = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除小游戏'),
        content: Text(
          '确定删除「$name」及其 $levelCount 个关卡吗？保存前可以「放弃修改」回滚。',
          style: TextStyle(
              fontSize: 12.5, color: palette.textPrimary, height: 1.5),
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
    );
    if (yes != true || !mounted) return;
    setState(() {
      _tableData(_gameCfg).remove(id);
      for (final l in _levelsOf(id)) {
        _tableData(_actionCfg).remove(l);
      }
      _selGame = null;
      _selLevel = null;
      _ensureSelection();
    });
  }

  Future<void> _deleteLevel() async {
    final id = _selLevel;
    if (id == null) return;
    final yes = await fluent.showDialog<bool>(
      context: context,
      builder: (ctx) => AppContentDialog(
        title: const Text('删除关卡'),
        content: Text('确定删除第 ${_levelIndex(id)} 关吗？',
            style: TextStyle(
                fontSize: 12.5, color: palette.textPrimary, height: 1.5)),
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
    );
    if (yes != true || !mounted) return;
    setState(() {
      _tableData(_actionCfg).remove(id);
      _selLevel = null;
      _ensureSelection();
    });
  }

  void _selectGame(String id) {
    setState(() {
      _selGame = id;
      _selLevel = null;
      _ensureSelection();
    });
  }

  // ------------------------------------------------------------------
  // 积木库
  // ------------------------------------------------------------------

  Future<void> _editEffect() async {
    final row = _level;
    if (row == null) return;
    final current = row['effect'];
    final out = await showBlockLibrary(
      context,
      initialText: ValueCodec.encode(current ?? const <dynamic>[]),
      initialMode: 'effect',
      gameDicts: widget.state.gameDicts,
      title: '积木库 · 关卡效果',
    );
    if (out == null || !mounted) return;
    setState(() => row['effect'] = ValueCodec.decode(out, '2D Array'));
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return WorkbenchScaffold(
      errorTitle: '小游戏数据加载失败',
      status: _loading
          ? WorkbenchStatus.loading
          : _error != null
              ? WorkbenchStatus.error
              : WorkbenchStatus.ready,
      error: _error,
      onRetry: _loadAll,
      leftBuilder: (w) => _leftPanel(w),
      center: _center(),
      rightBuilder: (w) => _rightPanel(w),
      rightLabel: '游戏概览',
      rightIcon: FluentIcons.info_24_regular,
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final q = _search.trim().toLowerCase();
    final ids = _sortedGames.where((id) {
      if (q.isEmpty) return true;
      final name = _rowIn(_gameCfg, id)?['name']?.toString().toLowerCase() ?? '';
      return id.contains(q) || name.contains(q);
    }).toList();

    return Container(
      width: w,
      color: palette.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                fluent.TextBox(
                  controller: _searchCtrl,
                  placeholder: '搜索小游戏名称或编号',
                  onChanged: (v) =>
                      _searchDebounce.run(() => setState(() => _search = v)),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _addGame,
                  child: const Text('＋ 新建小游戏',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                WorkbenchMiniButton(
                  label: '删除此小游戏',
                  danger: true,
                  enabled: _selGame != null,
                  onTap: _deleteGame,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ids.isEmpty
                ? Center(
                    child: Text(
                      _sortedGames.isEmpty ? '还没有小游戏，点上方新建。' : '没有匹配的小游戏。',
                      style: TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    itemCount: ids.length,
                    itemBuilder: (context, i) => _gameTile(ids[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _gameTile(String id) {
    final row = _rowIn(_gameCfg, id);
    final selected = id == _selGame;
    final levels = _levelsOf(id);
    return _HoverTile(
      selected: selected,
      onTap: () => _selectGame(id),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.bgDeep2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            alignment: Alignment.center,
            child: Icon(FluentIcons.games_24_regular,
                size: 18, color: palette.textMuted),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row?['name']?.toString() ?? '未命名小游戏',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected
                            ? palette.textHigh
                            : palette.textPrimary)),
                const SizedBox(height: 3),
                Text('${levels.length} 个关卡',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
            ),
          ),
          Text(id,
              style: TextStyle(fontSize: 10, color: palette.textHint)),
        ],
      ),
    );
  }

  // ---------- 中栏 ----------

  Widget _center() {
    final game = _game;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: game == null
              ? Center(
                  child: Text('选择或新建一个小游戏，中间编辑、右侧预览。',
                      style: TextStyle(fontSize: 13, color: palette.textHint)),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _headerBar(),
                      const SizedBox(height: 14),
                      _gameEditor(game),
                      const SizedBox(height: 14),
                      _levelsSection(),
                    ],
                  ),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _headerBar() {
    final game = _game!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(FluentIcons.games_24_regular, size: 20, color: accentColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  game['name']?.toString().trim().isNotEmpty == true
                      ? game['name'].toString()
                      : '未命名小游戏',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh),
                ),
                const SizedBox(height: 2),
                Text('小游戏 · 编号 $_selGame',
                    style: TextStyle(fontSize: 10.5, color: palette.textMuted)),
              ],
            ),
          ),
          _Tag(text: '${_levelsOf(_selGame).length} 关', color: palette.statusInfo),
        ],
      ),
    );
  }

  Widget _gameEditor(Map<String, dynamic> game) {
    return WorkbenchSectionCard(
      title: '小游戏定义',
      children: [
        _labeled('名称', SyncedTextField(
          value: game['name']?.toString() ?? '',
          hint: '小游戏名称',
          onChanged: (v) => setState(() => game['name'] = v),
        )),
        _labeled('玩法提示', SyncedTextField(
          value: game['tips']?.toString() ?? '',
          hint: '显示给玩家的玩法说明',
          maxLines: 3,
          onChanged: (v) => setState(() => game['tips'] = v),
        )),
        _labeled('背景音乐编号', NumBox(
          format: true, value: game['bgm'],
          hint: '音频编号，0 = 不播放',
          onChanged: (v) => setState(() => game['bgm'] = (v ?? 0).toInt()),
        )),
      ],
    );
  }

  // ---------- 关卡 ----------

  Widget _levelsSection() {
    final levels = _levelsOf(_selGame);
    return WorkbenchSectionCard(
      title: '关卡',
      subtitle: '编号规则：小游戏编号 × 100 + 关卡序号（第 1~5 关）。',
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final id in levels)
              _LevelChip(
                index: _levelIndex(id),
                selected: id == _selLevel,
                onTap: () => setState(() => _selLevel = id),
              ),
            _AddChip(onTap: _addLevel),
          ],
        ),
        const SizedBox(height: 12),
        if (_level == null)
          Text('还没有关卡，点上方「＋ 关卡」添加。',
              style: TextStyle(fontSize: 12, color: palette.textHint))
        else
          _levelEditor(_level!),
      ],
    );
  }

  Widget _levelEditor(Map<String, dynamic> level) {
    final parms = _intList(level, 'parms');
    final effectCount =
        (level['effect'] is List) ? (level['effect'] as List).length : 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('第 ${_levelIndex(_selLevel ?? '')} 关设置',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textHigh)),
              const Spacer(),
              WorkbenchMiniButton(label: '删除此关', danger: true, onTap: _deleteLevel),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _labeled('精力消耗', NumBox(
                  format: true, value: level['cost'],
                  onChanged: (v) =>
                      setState(() => level['cost'] = (v ?? 0).toInt()),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeled('模式', NumBox(
                  format: true, value: level['mode'],
                  onChanged: (v) =>
                      setState(() => level['mode'] = (v ?? 0).toInt()),
                )),
              ),
            ],
          ),
          _labeled('关系要求', _DropdownInt(
            value: _intOf(level, 'needRelation'),
            options: {
              0: '无',
              for (final k in _relations.keys)
                if (int.tryParse(k) != null)
                  int.parse(k): _relationName(int.parse(k)),
            },
            onChanged: (v) => setState(() => level['needRelation'] = v),
          )),
          _labeled('数值参数（逗号分隔）', ListNumField(
            value: parms,
            hint: '例如 30,60,0.5,0.2',
            onChanged: (v) => setState(() => level['parms'] = v),
          )),
          Row(
            children: [
              Expanded(
                child: _labeled('开场对话', NumBox(
                  format: true, value: level['startTalk'],
                  hint: '对话编号',
                  onChanged: (v) =>
                      setState(() => level['startTalk'] = (v ?? 0).toInt()),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _labeled('胜利对话', NumBox(
                  format: true, value: level['winTalk'],
                  hint: '对话编号',
                  onChanged: (v) =>
                      setState(() => level['winTalk'] = (v ?? 0).toInt()),
                )),
              ),
            ],
          ),
          _labeled('失败对话', NumBox(
            format: true, value: level['loseTalk'],
            hint: '对话编号',
            onChanged: (v) =>
                setState(() => level['loseTalk'] = (v ?? 0).toInt()),
          )),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('关卡效果',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: palette.textSecondary)),
                      const SizedBox(height: 3),
                      Text(effectCount == 0 ? '未设置（effect）' : '已设置 $effectCount 条（effect）',
                          style: TextStyle(
                              fontSize: 11, color: palette.textMuted)),
                    ],
                  ),
                ),
                WorkbenchMiniButton(label: '打开积木库', onTap: _editEffect),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 底部保存条 ----------

  Widget _saveBar() {
    return SaveBar(
      dirty: _dirty,
      saving: _saving,
      onSave: _saveAll,
      onDiscard: _discard,
      onOpenSearch: widget.onOpenSearch,
      history: _ctl,
    );
  }

  // ---------- 右栏 ----------

  Widget _rightPanel(double w) {
    final game = _game;
    return Container(
      width: w,
      color: palette.panel,
      child: game == null
          ? Center(
              child: Text('选择小游戏查看预览。',
                  style: TextStyle(fontSize: 12, color: palette.textHint)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  WorkbenchSectionCard(
                    title: '玩法预览',
                    children: [_previewCard(game)],
                  ),
                  _statsCard(game),
                ],
              ),
            ),
    );
  }

  Widget _previewCard(Map<String, dynamic> game) {
    final guide = _guideOf(_selGame ?? '');
    final guideUrl = guide?['url']?.toString() ?? '';
    final tips = guide?['tips']?.toString().trim() ?? '';
    final gameTips = game['tips']?.toString().trim() ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            height: 120,
            decoration: BoxDecoration(
              color: palette.bgDeep2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            child: guideUrl.isEmpty
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.image_24_regular,
                          size: 26, color: palette.iconDisabled),
                      const SizedBox(height: 6),
                      Text('暂无原版玩法配图',
                          style: TextStyle(
                              fontSize: 10.5, color: palette.textHint)),
                    ],
                  )
                : TexThumb(
                    keyName: guideUrl,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: 120,
                  ),
          ),
          const SizedBox(height: 10),
          Text(
            game['name']?.toString().trim().isNotEmpty == true
                ? game['name'].toString()
                : '未命名小游戏',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: palette.textHigh),
          ),
          const SizedBox(height: 6),
          Text(
            gameTips.isNotEmpty ? gameTips : (tips.isNotEmpty ? tips : '暂无玩法提示'),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11.5, height: 1.6, color: palette.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _statsCard(Map<String, dynamic> game) {
    final levels = _levelsOf(_selGame);
    final level = _level;
    return WorkbenchSectionCard(
      title: '统计与引用',
      children: [
        _kv('关卡数量', '${levels.length}'),
        _kv('背景音乐', _intOf(game, 'bgm') == 0 ? '无' : '音频编号 ${_intOf(game, 'bgm')}'),
        if (level != null) ...[
          _kv('当前关卡', '第 ${_levelIndex(_selLevel ?? '')} 关'),
          _kv('精力消耗', '${_intOf(level, 'cost')}'),
          _kv('关系要求', _relationName(_intOf(level, 'needRelation'))),
          _kv(
              '开场 / 胜利 / 失败对话',
              '${_talkLabel(_intOf(level, 'startTalk'))} / '
              '${_talkLabel(_intOf(level, 'winTalk'))} / '
              '${_talkLabel(_intOf(level, 'loseTalk'))}'),
          _kv('关卡效果', '${(level['effect'] is List) ? (level['effect'] as List).length : 0} 条'),
        ],
      ],
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 11.5, color: palette.textMuted)),
          ),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: palette.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _labeled(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: palette.textSecondary)),
          const SizedBox(height: 7),
          child,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 通用小部件
// ---------------------------------------------------------------------------


class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
    );
  }
}

class _HoverTile extends StatefulWidget {
  const _HoverTile({
    required this.child,
    required this.onTap,
    this.selected = false,
  });
  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<_HoverTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.12)
                : _hover
                    ? palette.card
                    : palette.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.16)
                : palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Text('第 $index 关',
              style: TextStyle(
                fontSize: 12,
                color: selected ? palette.textHigh : palette.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              )),
        ),
      ),
    );
  }
}

class _AddChip extends StatelessWidget {
  const _AddChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.border),
          ),
          child: Text('＋ 关卡',
              style: TextStyle(fontSize: 12, color: palette.textSecondary)),
        ),
      ),
    );
  }
}

class _DropdownInt extends StatelessWidget {
  const _DropdownInt({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final int value;
  final Map<int, String> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final has = options.containsKey(value);
    return fluent.ComboBox<int>(
      value: has ? value : (entries.isNotEmpty ? entries.first.key : 0),
      isExpanded: true,
      items: [
        for (final e in entries)
          fluent.ComboBoxItem<int>(
            value: e.key,
            child: Text(e.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
        if (!has)
          fluent.ComboBoxItem<int>(
            value: value,
            child: Text('保留原值 $value',
                style: const TextStyle(fontSize: 12)),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

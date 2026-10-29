import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_feedback.dart';
import '../../core/app_theme.dart';
import '../../core/error_text.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/workbench_controller.dart';
import '../../core/workbench_guard.dart';
import '../../core/workbench_scaffold.dart';
import '../../core/save_bar.dart';
import '../editor/section_card.dart';
import '../editor/synced_fields.dart';
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;
import '../resources/image_asset_picker.dart' show TexThumb;

/// 空间工作台 —— 导演布局下「空间」的专属界面（人物企鹅空间）。
///
/// 三栏：空间列表｜游戏内空间预览（主页/说说/留言板/个人档）｜空间设置 + 留言板。
///
/// 编辑两张表：`KZoneProfileCfg`（空间资料）与 `KZoneMessageBoardCfg`（留言板），
/// 各自整表读写（`expect_mtime_ns` 乐观锁）。`KZoneAvatarCfg` / `KZoneColorCfg` /
/// `KZoneFontCfg` 只读用于头像、主题与字体选择。
class SpaceWorkbench extends StatefulWidget {
  const SpaceWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<SpaceWorkbench> createState() => _SpaceWorkbenchState();
}

const _spacePages = <List<String>>[
  ['home', '主页'],
  ['posts', '说说'],
  ['board', '留言板'],
  ['profile', '个人档'],
];

class _SpaceWorkbenchState extends State<SpaceWorkbench>
    with WorkbenchLeaveGuard<SpaceWorkbench> {
  static const _profileCfg = 'KZoneProfileCfg';
  static const _messageCfg = 'KZoneMessageBoardCfg';

  // 可写主表由公共控制器管理（A3）；只读引用表仍是普通字段。
  late final WorkbenchController _ctl = WorkbenchController(
    cfgs: const [_profileCfg, _messageCfg],
    onConflict: _onConflict,
    onError: (e) {
      if (mounted) {
        AppFeedback.error(context, '保存失败：${humanizeErrorMessage(e)}',
            detail: e.toString());
      }
    },
    onSaved: (_) {},
  );

  Map<String, dynamic> get _profiles => _ctl.table(_profileCfg).data;
  Map<String, dynamic> get _messages => _ctl.table(_messageCfg).data;

  Map<String, dynamic> _avatars = {};
  Map<String, dynamic> _themes = {};
  Map<String, dynamic> _fonts = {};

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? _selected;
  String _search = '';
  String _page = 'home';
  String _rightTab = 'settings';

  List<RoleEntry> _roles = const [];

  final TextEditingController _searchCtrl = TextEditingController();

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
  String get guardSubject => '空间资料与留言板';

  Future<void> _loadAll() async {
    try {
      final res = await Future.wait([
        _ctl.load(),
        ApiClient.instance.get('/api/cfg/KZoneAvatarCfg'),
        ApiClient.instance.get('/api/cfg/KZoneColorCfg'),
        ApiClient.instance.get('/api/cfg/KZoneFontCfg'),
      ]);
      if (!mounted) return;
      _avatars = WorkbenchController.extractData(res[1]);
      _themes = WorkbenchController.extractData(res[2]);
      _fonts = WorkbenchController.extractData(res[3]);
      final ids = _sortedIds;
      if (_selected == null || !_profiles.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      setState(() {});
      _loadRoles();
    } catch (_) {
      // 错误已由控制器记录并经监听器反映到 _error / WorkbenchStatus.error。
    }
  }

  Future<void> _loadRoles() async {
    final list = await loadRoles('');
    if (!mounted) return;
    setState(() => _roles = list);
  }

  bool get _dirty => _ctl.dirtyDeep;

  Future<void> _saveAll() async {
    final ok = await _ctl.save();
    if (mounted && ok) {
      AppFeedback.success(context, '空间资料与留言板已保存');
    }
  }

  /// 409 冲突弹窗（复用统一的 [WorkbenchConflictChoice]）。
  Future<WorkbenchConflictChoice?> _onConflict(WorkbenchTable table) =>
      showWorkbenchConflictDialog(context, table);

  void _discard() {
    _ctl.discard();
    setState(() {
      final ids = _sortedIds;
      if (_selected == null || !_profiles.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
    });
  }


  // ------------------------------------------------------------------
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? _profileOf(String id) {
    final v = _profiles[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? get _profile =>
      _selected == null ? null : _profileOf(_selected!);

  List<String> get _sortedIds {
    final ids = _profiles.keys.toList();
    ids.sort((a, b) =>
        (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return ids;
  }

  int _intOf(Map<String, dynamic>? row, String field, [int fallback = 0]) {
    final v = row?[field];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? fallback;
  }

  String _roleName(int id) {
    for (final r in _roles) {
      if (r.id == id.toString()) return r.name.isEmpty ? '角色 $id' : r.name;
    }
    return id == 0 ? '白雨' : '角色 $id';
  }

  String _themeName(int id) {
    final v = _themes[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '主题 $id';
  }

  String _fontName(int id) {
    final v = _fonts[id.toString()];
    if (v is Map) {
      final n = v['name']?.toString().trim() ?? '';
      if (n.isNotEmpty) return n;
    }
    return '字体 $id';
  }

  Map<String, dynamic>? _themeRow(int id) {
    final v = _themes[id.toString()];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  String _avatarIcon(int avatarId) {
    final v = _avatars[avatarId.toString()];
    if (v is Map) return v['icon']?.toString() ?? '';
    return '';
  }

  List<String> _messagesOf(String ownerId) {
    final owner = int.tryParse(ownerId);
    final out = <String>[];
    for (final e in _messages.entries) {
      final row = e.value is Map ? (e.value as Map).cast<String, dynamic>() : null;
      final roles = _intList(row, 'roles');
      if (roles.length >= 2 && roles[1] == owner) out.add(e.key);
    }
    out.sort((a, b) =>
        (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return out;
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

  String _newMessageId() {
    var max = 0;
    for (final k in _messages.keys) {
      final v = int.tryParse(k);
      if (v != null && v > max) max = v;
    }
    return (max == 0 ? 1 : max + 1).toString();
  }

  Color? _hex(String? s) {
    if (s == null) return null;
    var t = s.trim();
    if (t.startsWith('#')) t = t.substring(1);
    if (t.length == 3) {
      t = '${t[0]}${t[0]}${t[1]}${t[1]}${t[2]}${t[2]}';
    }
    if (t.length != 6 && t.length != 8) return null;
    final v = int.tryParse(t, radix: 16);
    if (v == null) return null;
    return Color(t.length == 6 ? (0xFF000000 | v) : v);
  }

  // ------------------------------------------------------------------
  // 编辑操作
  // ------------------------------------------------------------------

  Future<void> _addSpace() async {
    final hasProfile = _profiles.keys.map(int.tryParse).toSet();
    final id = await _pickRole(
      title: '为人物添加企鹅空间',
      filter: (r) => !hasProfile.contains(int.tryParse(r.id)),
    );
    if (id == null || !mounted) return;
    setState(() {
      _profiles[id.toString()] = <String, dynamic>{
        'id': id,
        'name': _roleName(id),
        'desc': '',
        'marriage': <dynamic>[],
        'hometown': '',
        'living': '',
        'job': '',
        'school': '',
        'isVip': 0,
        'theme': 1,
        'bgm': 0,
        'font': 101,
        'fontColor': 0,
        'fontSize': 40,
        'icon': 0,
      };
      _selected = id.toString();
      _page = 'home';
    });
  }

  void _deleteSpace() {
    final id = _selected;
    if (id == null) return;
    setState(() {
      _profiles.remove(id);
      final ids = _sortedIds;
      _selected = ids.isNotEmpty ? ids.first : null;
    });
  }

  Future<void> _addMessage() async {
    final owner = _selected;
    if (owner == null) return;
    final author = await _pickRole(title: '选择留言人物');
    if (author == null || !mounted) return;
    final id = _newMessageId();
    setState(() {
      _messages[id] = <String, dynamic>{
        'id': int.tryParse(id),
        'roles': [author, int.tryParse(owner) ?? 0],
        'content': '',
        'isPrivate': 0,
        'round': 0,
        'reply': 0,
        'cond': <dynamic>[],
      };
    });
  }

  void _deleteMessage(String id) {
    setState(() => _messages.remove(id));
  }

  Future<int?> _pickRole({
    String title = '选择人物',
    bool Function(RoleEntry)? filter,
  }) async {
    var query = '';
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final rows = _roles
              .where((r) => (filter == null || filter(r)))
              .where((r) =>
                  r.id.toLowerCase().contains(query) ||
                  r.name.toLowerCase().contains(query))
              .toList();
          return AppContentDialog(
            title: Text(title),
            content: SizedBox(
              width: 440,
              height: 440,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索人物名称或编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final r in rows)
                          _pickerRow(ctx, int.tryParse(r.id) ?? 0, r.name,
                              sub: r.id),
                        if (rows.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('没有匹配的人物',
                                style: TextStyle(
                                    fontSize: 12, color: palette.textHint)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickAvatar() async {
    final profile = _profile;
    if (profile == null) return;
    var query = '';
    final entries = _avatars.entries.toList()
      ..sort((a, b) =>
          (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0));
    final picked = await fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final list = entries.where((e) {
            if (query.isEmpty) return true;
            final name = (e.value is Map ? (e.value as Map)['name'] : '')
                    ?.toString()
                    .toLowerCase() ??
                '';
            return e.key.contains(query) || name.contains(query);
          }).toList();
          return AppContentDialog(
            title: const Text('选择企鹅头像'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索头像编号',
                    onChanged: (v) =>
                        setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: GridView.count(
                      crossAxisCount: 6,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        _avatarTile(ctx, 0, '', '使用大头照'),
                        for (final e in list)
                          _avatarTile(
                            ctx,
                            int.tryParse(e.key) ?? 0,
                            (e.value is Map
                                    ? (e.value as Map)['icon']?.toString()
                                    : '') ??
                                '',
                            e.key,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => profile['icon'] = picked);
  }

  Widget _avatarTile(BuildContext ctx, int id, String icon, String label) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => Navigator.pop(ctx, id),
        child: Container(
          decoration: BoxDecoration(
            color: palette.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: icon.isEmpty
              ? Center(
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 10, color: palette.textMuted)),
                )
              : TexThumb(
                  keyName: icon,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return WorkbenchScaffold(
      errorTitle: '空间数据加载失败',
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
      rightLabel: '空间设置',
    );
  }

  // ---------- 左栏 ----------

  Widget _leftPanel(double w) {
    final q = _search.trim().toLowerCase();
    final ids = _sortedIds.where((id) {
      if (q.isEmpty) return true;
      final row = _profileOf(id);
      return id.contains(q) ||
          _roleName(int.tryParse(id) ?? 0).toLowerCase().contains(q) ||
          (row?['name']?.toString().toLowerCase() ?? '').contains(q);
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
                  placeholder: '搜索人物或企鹅昵称',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _addSpace,
                  child: const Text('＋ 为人物添加空间',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                WorkbenchMiniButton(
                  label: '删除此空间',
                  danger: true,
                  enabled: _selected != null,
                  onTap: _deleteSpace,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ids.isEmpty
                ? Center(
                    child: Text(
                      _profiles.isEmpty ? '还没有空间，点上方按钮添加。' : '没有匹配的空间。',
                      style:
                          TextStyle(fontSize: 12, color: palette.textHint),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    itemCount: ids.length,
                    itemBuilder: (context, i) {
                      final id = ids[i];
                      final row = _profileOf(id);
                      final pid = int.tryParse(id) ?? 0;
                      return _SpaceListItem(
                        id: id,
                        personName: _roleName(pid),
                        nickname: row?['name']?.toString() ?? '',
                        avatarIcon: _avatarIcon(_intOf(row, 'icon')),
                        personId: pid,
                        selected: id == _selected,
                        onTap: () => setState(() {
                          _selected = id;
                          _page = 'home';
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------- 中栏：空间预览 ----------

  Widget _center() {
    final profile = _profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: profile == null
              ? Center(
                  child: Text(
                    '选择或添加一个人物空间，中间预览、右侧编辑。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
                  child: Center(child: _previewCard(profile)),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _previewCard(Map<String, dynamic> profile) {
    final pid = int.tryParse(_selected ?? '') ?? 0;
    final theme = _themeRow(_intOf(profile, 'theme', 1));
    final headerColor =
        _hex(theme?['imgColor']?.toString()) ?? palette.catAudio;
    final pageBg = _hex(theme?['bg']?.toString()) ?? palette.card;
    final navBg = _hex(theme?['navBg']?.toString()) ?? headerColor;
    final nameColor = _hex(theme?['nameTxt']?.toString()) ?? palette.textHigh;
    final avatarIcon = _avatarIcon(_intOf(profile, 'icon'));

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      decoration: BoxDecoration(
        color: pageBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部（封面 + 头像 + 昵称 + 签名）
          Container(
            color: headerColor,
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 118,
                  height: 60,
                  decoration: BoxDecoration(
                    color: palette.scrimWeak,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text('空间封面',
                      style: TextStyle(
                          fontSize: 11, color: palette.onAccent)),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Avatar(
                      seed: pid,
                      name: _roleName(pid),
                      icon: avatarIcon,
                      size: 56,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile['name']?.toString().isNotEmpty == true
                                ? profile['name'].toString()
                                : _roleName(pid),
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: nameColor),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: palette.scrimWeak,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              profile['desc']?.toString().isNotEmpty == true
                                  ? profile['desc'].toString()
                                  : '请输入个性签名',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: nameColor,
                                  height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // 导航
          Container(
            color: navBg,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                for (final p in _spacePages)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => setState(() => _page = p[0]),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _page == p[0]
                                  ? palette.onAccent
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Text(
                          p[1],
                          style: TextStyle(
                            fontSize: 12.5,
                            color: _page == p[0]
                                ? palette.onAccent
                                : palette.onAccent.withValues(alpha: 0.7),
                            fontWeight: _page == p[0]
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 内容
          Padding(
            padding: const EdgeInsets.all(16),
            child: _pageBody(profile, pid),
          ),
        ],
      ),
    );
  }

  Widget _pageBody(Map<String, dynamic> profile, int pid) {
    switch (_page) {
      case 'board':
        final ids = _messagesOf(_selected ?? '');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ids.isEmpty)
              Text('还没有留言，右侧「留言板」添加。',
                  style: TextStyle(fontSize: 12, color: palette.textHint))
            else
              for (final id in ids) _previewMessage(id),
          ],
        );
      case 'profile':
        final marriage = _intList(profile, 'marriage');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow('家乡', profile['hometown']?.toString() ?? ''),
            _detailRow('现居地', profile['living']?.toString() ?? ''),
            _detailRow('职业', profile['job']?.toString() ?? ''),
            _detailRow('学校 / 公司', profile['school']?.toString() ?? ''),
            _detailRow(
              '感情状态',
              marriage.isEmpty
                  ? '未设置'
                  : (marriage.first == 1 ? '恋爱中' : '未恋爱'),
            ),
          ],
        );
      case 'posts':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('说说动态',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.textHigh)),
            const SizedBox(height: 8),
            Text(
              '这个人的说说（KZoneContentCfg）在「社交动态」工作台编辑；'
              '这里只管理空间资料与留言板。',
              style: TextStyle(
                  fontSize: 11.5, height: 1.7, color: palette.textMuted),
            ),
          ],
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              profile['desc']?.toString().isNotEmpty == true
                  ? profile['desc'].toString()
                  : '（还没有个性签名）',
              style: TextStyle(
                  fontSize: 12.5, height: 1.7, color: palette.textPrimary),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Tag(
                    text: _intOf(profile, 'isVip') == 1 ? '黄钻' : '普通',
                    color: _intOf(profile, 'isVip') == 1
                        ? palette.statusWarn
                        : palette.textMuted),
                const SizedBox(width: 8),
                _Tag(
                    text: '主题：${_themeName(_intOf(profile, 'theme', 1))}',
                    color: palette.statusInfo),
                const SizedBox(width: 8),
                if (_intOf(profile, 'bgm') != 0)
                  _Tag(
                      text: '背景音乐：${_intOf(profile, 'bgm')}',
                      color: palette.statusOk),
              ],
            ),
          ],
        );
    }
  }

  Widget _previewMessage(String id) {
    final row =
        _messages[id] is Map ? (_messages[id] as Map).cast<String, dynamic>() : null;
    final roles = _intList(row, 'roles');
    final author = roles.isNotEmpty ? roles.first : 0;
    final content = row?['content']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(
              seed: author,
              name: _roleName(author),
              icon: '',
              size: 34),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(_roleName(author),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: palette.textHigh)),
                    if (_intOf(row, 'isPrivate') == 1) ...[
                      const SizedBox(width: 6),
                      _Tag(text: '私密', color: palette.textMuted),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(content.isEmpty ? '（空白留言）' : content,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: palette.textPrimary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: palette.textMuted)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '未设置' : value,
                style: TextStyle(
                    fontSize: 12.5, color: palette.textPrimary)),
          ),
        ],
      ),
    );
  }

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
    final profile = _profile;
    return Container(
      width: w,
      color: palette.panel,
      child: profile == null
          ? Center(
              child: Text('选择左侧空间查看设置。',
                  style: TextStyle(fontSize: 12, color: palette.textHint)),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _SegButton(
                        label: '空间设置',
                        selected: _rightTab == 'settings',
                        onTap: () => setState(() => _rightTab = 'settings'),
                      ),
                      const SizedBox(width: 6),
                      _SegButton(
                        label: '留言板',
                        selected: _rightTab == 'board',
                        onTap: () => setState(() => _rightTab = 'board'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (_rightTab == 'settings')
                    _settingsBody(profile)
                  else
                    _boardBody(profile),
                ],
              ),
            ),
    );
  }

  Widget _settingsBody(Map<String, dynamic> profile) {
    final isVip = _intOf(profile, 'isVip') == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WorkbenchSectionCard(
          title: '资料',
          children: [
            _labeled('企鹅昵称', SyncedTextField(
              value: profile['name']?.toString() ?? '',
              hint: '企鹅昵称',
              onChanged: (v) => setState(() => profile['name'] = v),
            )),
            _labeled('个性签名', SyncedTextField(
              value: profile['desc']?.toString() ?? '',
              hint: '个性签名',
              maxLines: 3,
              onChanged: (v) => setState(() => profile['desc'] = v),
            )),
            Row(
              children: [
                Text('开通黄钻',
                    style: TextStyle(
                        fontSize: 12, color: palette.textPrimary)),
                const SizedBox(width: 10),
                _SegButton(
                  label: isVip ? '已开通' : '未开通',
                  selected: isVip,
                  onTap: () => setState(() => profile['isVip'] = isVip ? 0 : 1),
                ),
                const Spacer(),
                WorkbenchMiniButton(label: '更换头像', onTap: _pickAvatar),
              ],
            ),
          ],
        ),
        WorkbenchSectionCard(
          title: '个性化',
          subtitle: isVip ? null : '部分主题与字体需要黄钻（预览仍可切换）。',
          children: [
            _labeled(
              '空间主题',
              _Dropdown(
                value: _intOf(profile, 'theme', 1),
                options: {
                  for (final e in _themes.entries)
                    e.key: _themeName(int.tryParse(e.key) ?? 0),
                },
                onChanged: (v) => setState(() => profile['theme'] = v),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _labeled(
                    '字体',
                    _Dropdown(
                      value: _intOf(profile, 'font'),
                      options: {
                        for (final e in _fonts.entries)
                          e.key: _fontName(int.tryParse(e.key) ?? 0),
                      },
                      onChanged: (v) => setState(() => profile['font'] = v),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _labeled(
                    '字体颜色',
                    _Dropdown(
                      value: _intOf(profile, 'fontColor'),
                      options: {
                        for (final e in _fonts.entries)
                          e.key: _fontName(int.tryParse(e.key) ?? 0),
                      },
                      onChanged: (v) =>
                          setState(() => profile['fontColor'] = v),
                    ),
                  ),
                ),
              ],
            ),
            _labeled('签名字号', NumBox(
              intOnly: true, value: _intOf(profile, 'fontSize', 40),
              hint: '40 ~ 80',
              onChanged: (v) => setState(
                  () => profile['fontSize'] = (v ?? 40).toInt().clamp(40, 80)),
            )),
            _labeled('背景音乐（AudioCfg 编号）', NumBox(
              intOnly: true, value: _intOf(profile, 'bgm'),
              hint: '0 表示无背景音乐',
              onChanged: (v) => setState(() => profile['bgm'] = (v ?? 0).toInt()),
            )),
          ],
        ),
        WorkbenchSectionCard(
          title: '个人档',
          children: [
            _labeled('家乡', SyncedTextField(
              value: profile['hometown']?.toString() ?? '',
              hint: '家乡',
              onChanged: (v) => setState(() => profile['hometown'] = v),
            )),
            _labeled('现居地', SyncedTextField(
              value: profile['living']?.toString() ?? '',
              hint: '现居地',
              onChanged: (v) => setState(() => profile['living'] = v),
            )),
            _labeled('职业', SyncedTextField(
              value: profile['job']?.toString() ?? '',
              hint: '职业',
              onChanged: (v) => setState(() => profile['job'] = v),
            )),
            _labeled('学校 / 公司', SyncedTextField(
              value: profile['school']?.toString() ?? '',
              hint: '学校 / 公司',
              onChanged: (v) => setState(() => profile['school'] = v),
            )),
            _labeled(
              '感情状态',
              Row(
                children: [
                  _SegButton(
                    label: '未恋爱',
                    selected:
                        _intList(profile, 'marriage').isEmpty ||
                            _intList(profile, 'marriage').first != 1,
                    onTap: () => setState(() => profile['marriage'] = [0]),
                  ),
                  const SizedBox(width: 8),
                  _SegButton(
                    label: '恋爱中',
                    selected: _intList(profile, 'marriage').isNotEmpty &&
                        _intList(profile, 'marriage').first == 1,
                    onTap: () => setState(() => profile['marriage'] = [1]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _boardBody(Map<String, dynamic> profile) {
    final ids = _messagesOf(_selected ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WorkbenchSectionCard(
          title: '留言板（${ids.length}）',
          subtitle: '每一条留言包含留言人、内容与是否私密。',
          children: [
            for (final id in ids) _messageCard(id),
            const SizedBox(height: 4),
            WorkbenchMiniButton(label: '＋ 添加留言', onTap: _addMessage),
          ],
        ),
      ],
    );
  }

  Widget _messageCard(String id) {
    final row = _messages[id] is Map
        ? (_messages[id] as Map).cast<String, dynamic>()
        : null;
    if (row == null) return const SizedBox.shrink();
    final roles = _intList(row, 'roles');
    final author = roles.isNotEmpty ? roles.first : 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 10),
        decoration: BoxDecoration(
          color: palette.bgAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(
                    seed: author,
                    name: _roleName(author),
                    icon: '',
                    size: 26),
                const SizedBox(width: 8),
                Expanded(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () async {
                        final picked = await _pickRole(title: '更换留言人物');
                        if (picked == null || !mounted) return;
                        setState(() => row['roles'] = [picked, roles.length > 1 ? roles[1] : 0]);
                      },
                      child: Text('${_roleName(author)} · 更换',
                          style: TextStyle(
                              fontSize: 12, color: palette.textPrimary)),
                    ),
                  ),
                ),
                fluent.IconButton(
                  icon: Icon(FluentIcons.delete_24_regular,
                      size: 13, color: palette.statusDanger),
                  onPressed: () => _deleteMessage(id),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SyncedTextField(
              value: row['content']?.toString() ?? '',
              hint: '输入留言内容',
              maxLines: 2,
              onChanged: (v) => setState(() => row['content'] = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _SegButton(
                  label: _intOf(row, 'isPrivate') == 1 ? '私密' : '公开',
                  selected: _intOf(row, 'isPrivate') == 1,
                  onTap: () => setState(() =>
                      row['isPrivate'] = _intOf(row, 'isPrivate') == 1 ? 0 : 1),
                ),
                const SizedBox(width: 8),
                _SegButton(
                  label: _intOf(row, 'reply') == 1 ? '回复留言' : '普通留言',
                  selected: _intOf(row, 'reply') == 1,
                  onTap: () => setState(() =>
                      row['reply'] = _intOf(row, 'reply') == 1 ? 0 : 1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 通用 ----------

  Widget _pickerRow(BuildContext ctx, int id, String name, {String? sub}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(ctx, id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              if (sub != null)
                SizedBox(
                  width: 64,
                  child: Text(sub,
                      style:
                          TextStyle(fontSize: 10.5, color: palette.textHint)),
                ),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5, color: palette.textPrimary)),
              ),
            ],
          ),
        ),
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

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.seed,
    required this.name,
    required this.icon,
    this.size = 40,
  });

  final int seed;
  final String name;
  final String icon;
  final double size;

  List<Color> get _swatches => [
        accentColor,
        palette.catTexture,
        palette.catAudio,
        palette.catSprite,
        palette.statusOk,
        palette.statusWarn,
      ];

  @override
  Widget build(BuildContext context) {
    final c = _swatches[seed.abs() % _swatches.length];
    final ch = name.trim().isEmpty ? '?' : name.trim().substring(0, 1);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.22),
        shape: BoxShape.circle,
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: icon.isEmpty
          ? Text(
              ch,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
                color: c,
              ),
            )
          : TexThumb(
              keyName: icon,
              fit: BoxFit.cover,
              width: size,
              height: size,
            ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final int value;
  final Map<String, String> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final entries = options.entries.toList()
      ..sort((a, b) =>
          (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0));
    final has = options.containsKey(value.toString());
    return fluent.ComboBox<int>(
      value: has ? value : (entries.isNotEmpty ? int.tryParse(entries.first.key) ?? 0 : 0),
      isExpanded: true,
      items: [
        for (final e in entries)
          fluent.ComboBoxItem<int>(
            value: int.tryParse(e.key) ?? 0,
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

class _SpaceListItem extends StatefulWidget {
  const _SpaceListItem({
    required this.id,
    required this.personName,
    required this.nickname,
    required this.avatarIcon,
    required this.personId,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String personName;
  final String nickname;
  final String avatarIcon;
  final int personId;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SpaceListItem> createState() => _SpaceListItemState();
}

class _SpaceListItemState extends State<_SpaceListItem> {
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
          margin: const EdgeInsets.only(bottom: 7),
          padding: const EdgeInsets.all(10),
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
          child: Row(
            children: [
              _Avatar(
                seed: widget.personId,
                name: widget.personName,
                icon: widget.avatarIcon,
                size: 38,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.personName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: selected
                                ? palette.textHigh
                                : palette.textPrimary)),
                    const SizedBox(height: 3),
                    Text(
                      widget.nickname.trim().isEmpty
                          ? '未设置昵称'
                          : widget.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: palette.textMuted),
                    ),
                  ],
                ),
              ),
              Text(widget.id,
                  style:
                      TextStyle(fontSize: 10, color: palette.textHint)),
            ],
          ),
        ),
      ),
    );
  }
}
class _SegButton extends StatefulWidget {
  const _SegButton({
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_SegButton> createState() => _SegButtonState();
}

class _SegButtonState extends State<_SegButton> {
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
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.16)
                : _hover
                    ? palette.card
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.45)
                  : palette.border,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: selected ? palette.textHigh : palette.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

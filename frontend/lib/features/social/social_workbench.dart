import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_dialogs.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../../core/motion.dart';
import '../../core/workbench_guard.dart';
import '../../core/workbench_scaffold.dart';
import '../nocode/entity_picker.dart' show RoleEntry, loadRoles;
import '../resources/image_asset_picker.dart'
    show TexThumb, showImageAssetPicker;

/// 社交动态工作台 —— 导演布局下「社交」的专属界面（企鹅空间动态）。
///
/// 三栏：动态列表（搜索 / 发布 / 删除）｜动态正文 + 评论树｜动态·评论设置。
/// 数据来自 `KZoneContentCfg`（动态）/ `KZoneCommentCfg`（评论与回复），
/// 整表读取、整表写回（带 `expect_mtime_ns` 乐观锁，409 弹冲突选择）。
///
/// 评论 id 约定：`floor(commentId / 100) == postId`（与游戏一致），
/// 回复的 parent 指向所属根评论。
class SocialWorkbench extends StatefulWidget {
  const SocialWorkbench({
    super.key,
    required this.state,
    this.onOpenSearch,
  });

  final AppState state;
  final VoidCallback? onOpenSearch;

  @override
  State<SocialWorkbench> createState() => _SocialWorkbenchState();
}

class _SocialWorkbenchState extends State<SocialWorkbench>
    with WorkbenchLeaveGuard<SocialWorkbench> {
  static const _postCfg = 'KZoneContentCfg';
  static const _commentCfg = 'KZoneCommentCfg';

  Map<String, dynamic> _posts = {};
  Map<String, dynamic> _comments = {};
  String _postsSnap = '';
  String _commentsSnap = '';
  int? _postsM;
  int? _commentsM;

  bool _loading = true;
  bool _saving = false;
  String? _error;

  String? _selected;
  String? _target;
  String _search = '';

  List<RoleEntry> _roles = const [];

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 数据
  // ------------------------------------------------------------------

  Map<String, dynamic> _dataOf(dynamic r) {
    if (r is Map && r['data'] is Map) {
      return (r['data'] as Map).cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  int? _mtimeOf(dynamic r) =>
      (r is Map && r['mtime_ns'] is int) ? r['mtime_ns'] as int : null;

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
  String get guardSubject => '动态与评论';

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/api/cfg/$_postCfg'),
        ApiClient.instance.get('/api/cfg/$_commentCfg'),
      ]);
      if (!mounted) return;
      _posts = _dataOf(res[0]);
      _comments = _dataOf(res[1]);
      _postsM = _mtimeOf(res[0]);
      _commentsM = _mtimeOf(res[1]);
      _postsSnap = jsonEncode(_posts);
      _commentsSnap = jsonEncode(_comments);
      final ids = _sortedPostIds;
      if (_selected == null || !_posts.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      _target = null;
      setState(() => _loading = false);
      _loadRoles();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadRoles() async {
    final list = await loadRoles('');
    if (!mounted) return;
    setState(() => _roles = list);
  }

  bool get _dirty =>
      _postsSnap != jsonEncode(_posts) ||
      _commentsSnap != jsonEncode(_comments);

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveOne(_postCfg, _posts, _postsSnap);
      await _saveOne(_commentCfg, _comments, _commentsSnap);
      if (mounted) {
        _info('动态、评论和回复已一起保存', fluent.InfoBarSeverity.success);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveOne(
    String name,
    Map<String, dynamic> data,
    String snap,
  ) async {
    if (jsonEncode(data) == snap) return;
    var force = false;
    for (;;) {
      try {
        final body = <String, dynamic>{
          'data': data,
          if (force) 'force': true,
        };
        if (!force) {
          body['expect_mtime_ns'] = name == _postCfg ? _postsM : _commentsM;
        }
        final r = await ApiClient.instance.put('/api/cfg/$name', body: body);
        final freshSnap = jsonEncode(data);
        if (!mounted) return;
        setState(() {
          if (name == _postCfg) {
            _postsM = _mtimeOf(r);
            _postsSnap = freshSnap;
          } else {
            _commentsM = _mtimeOf(r);
            _commentsSnap = freshSnap;
          }
        });
        return;
      } on ApiException catch (e) {
        if (!mounted) return;
        if (e.statusCode == 409 && !force) {
          final act = await _conflictDialog(name);
          if (!mounted) return;
          if (act == 'reload') {
            await _loadAll();
            return;
          }
          if (act == 'force') {
            force = true;
            continue;
          }
          return;
        }
        _info('保存失败：$e', fluent.InfoBarSeverity.error);
        return;
      } catch (e) {
        if (!mounted) return;
        _info('保存失败：$e', fluent.InfoBarSeverity.error);
        return;
      }
    }
  }

  void _discard() {
    setState(() {
      _posts = (jsonDecode(_postsSnap) as Map).cast<String, dynamic>();
      _comments = (jsonDecode(_commentsSnap) as Map).cast<String, dynamic>();
      final ids = _sortedPostIds;
      if (_selected == null || !_posts.containsKey(_selected)) {
        _selected = ids.isNotEmpty ? ids.first : null;
      }
      _target = null;
    });
  }

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

  void _info(String msg, fluent.InfoBarSeverity severity) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: Text(msg),
        severity: severity,
      ),
    );
  }

  // ------------------------------------------------------------------
  // 行访问
  // ------------------------------------------------------------------

  Map<String, dynamic>? _row(Map<String, dynamic> tbl, String id) {
    final v = tbl[id];
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  Map<String, dynamic>? get _post =>
      _selected == null ? null : _row(_posts, _selected!);

  Map<String, dynamic>? get _comment =>
      _target == null ? null : _row(_comments, _target!);

  List<String> get _sortedPostIds {
    final ids = _posts.keys.toList();
    ids.sort((a, b) {
      final an = int.tryParse(a);
      final bn = int.tryParse(b);
      if (an != null && bn != null) return bn.compareTo(an); // 新动态在前
      return b.compareTo(a);
    });
    return ids;
  }

  int? _asId(dynamic v) {
    if (v is num) return v.toInt();
    if (v is List && v.isNotEmpty) {
      final f = v.first;
      if (f is num) return f.toInt();
      return int.tryParse(f.toString());
    }
    return int.tryParse(v.toString());
  }

  String _nextPostId() {
    var max = 0;
    for (final id in _posts.keys) {
      final v = int.tryParse(id);
      if (v != null && v > max) max = v;
    }
    return (max == 0 ? 1 : max + 1).toString();
  }

  String _nextCommentId(int postId) {
    var max = postId * 100;
    for (final id in _comments.keys) {
      final v = int.tryParse(id);
      if (v != null && v ~/ 100 == postId && v > max) max = v;
    }
    return (max + 1).toString();
  }

  List<dynamic> _listOf(Map<String, dynamic> row, String field) {
    final v = row[field];
    return v is List ? List<dynamic>.from(v) : <dynamic>[];
  }

  String _roleName(int id) {
    for (final r in _roles) {
      if (r.id == id.toString()) {
        return r.name.isEmpty ? '角色 $id' : r.name;
      }
    }
    return id == 0 ? '白雨' : '角色 $id';
  }

  int _commentCount(int postId) {
    var n = 0;
    for (final id in _comments.keys) {
      final v = int.tryParse(id);
      if (v != null && v ~/ 100 == postId) n++;
    }
    return n;
  }

  // ------------------------------------------------------------------
  // 动态 / 评论编辑
  // ------------------------------------------------------------------

  Future<int?> _pickRole({bool includeBaiyu = false}) async {
    var query = '';
    return fluent.showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final rows = _roles
              .where((r) =>
                  r.id.toLowerCase().contains(query) ||
                  r.name.toLowerCase().contains(query))
              .toList();
          return AppContentDialog(
            title: const Text('选择人物'),
            content: SizedBox(
              width: 460,
              height: 420,
              child: Column(
                children: [
                  fluent.TextBox(
                    placeholder: '搜索人物名称或编号',
                    onChanged: (v) => setLocal(() => query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        if (includeBaiyu)
                          _roleRow(0, '白雨', ctx),
                        for (final r in rows)
                          _roleRow(int.tryParse(r.id) ?? 0, r.name, ctx,
                              rawId: r.id),
                        if (!includeBaiyu && rows.isEmpty)
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

  Widget _roleRow(int id, String name, BuildContext ctx,
      {String? rawId}) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(ctx, id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              _Avatar(seed: id, name: name),
              const SizedBox(width: 10),
              Expanded(
                child: Text(name,
                    style: TextStyle(
                        fontSize: 12.5, color: palette.textPrimary)),
              ),
              if (rawId != null)
                Text(rawId,
                    style:
                        TextStyle(fontSize: 10.5, color: palette.textHint)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _newPost() async {
    final role = await _pickRole();
    if (role == null || !mounted) return;
    final id = _nextPostId();
    setState(() {
      _posts[id] = <String, dynamic>{
        'id': int.tryParse(id),
        'role': role,
        'title': '',
        'content': '',
        'imgs': <dynamic>[],
        'thumbs': <dynamic>[],
        'comments': <dynamic>[],
        'options': <dynamic>[],
        'cond': <dynamic>[],
      };
      _selected = id;
      _target = null;
    });
  }

  Future<void> _deletePost() async {
    final id = _selected;
    if (id == null) return;
    final ok = await confirmDelete(
      context,
      '确定删除这条动态及其评论吗？保存前可「放弃修改」回退。',
    );
    if (!ok || !mounted) return;
    final postId = int.tryParse(id) ?? -1;
    setState(() {
      final doomed = <String>{};
      for (final k in _comments.keys) {
        final v = int.tryParse(k);
        if (v != null && v ~/ 100 == postId) doomed.add(k);
      }
      _posts.remove(id);
      for (final d in doomed) {
        _comments.remove(d);
      }
      final ids = _sortedPostIds;
      _selected = ids.isNotEmpty ? ids.first : null;
      _target = null;
    });
  }

  Future<void> _addComment({String? parentId, bool player = false}) async {
    final id = _selected;
    if (id == null) return;
    final postId = int.tryParse(id) ?? -1;
    final int author;
    if (player) {
      author = 0;
    } else {
      final picked = await _pickRole();
      if (picked == null || !mounted) return;
      author = picked;
    }
    final owner = parentId != null ? _row(_comments, parentId) : _post;
    if (owner == null) return;
    final ownerRoles = _listOf(owner, 'roles');
    final ownerAuthor = ownerRoles.isNotEmpty ? _asId(ownerRoles.first) : 0;
    final cid = _nextCommentId(postId);
    setState(() {
      _comments[cid] = <String, dynamic>{
        'id': int.tryParse(cid),
        'roles': parentId != null
            ? [author, ownerAuthor ?? 0]
            : [author],
        'parent': parentId != null
            ? (_asId(owner['parent']) ?? 0) != 0
                ? _asId(owner['parent'])
                : int.tryParse(parentId)
            : 0,
        'content': '',
        'comments': <dynamic>[],
        'options': <dynamic>[],
        'effect': <dynamic>[],
        'condition': <dynamic>[],
      };
      final cidInt = int.tryParse(cid)!;
      if (player) {
        final opts = _listOf(owner, 'options')..add(cidInt);
        owner['options'] = opts;
      } else {
        final kids = _listOf(owner, 'comments')..add([cidInt, 0]);
        owner['comments'] = kids;
      }
      _target = cid;
    });
  }

  Set<String> _descendants(String rootId) {
    final set = <String>{};
    void visit(String id) {
      if (!set.add(id)) return;
      final row = _row(_comments, id);
      if (row == null) return;
      for (final pair in _listOf(row, 'comments')) {
        final cid = _asId(pair);
        if (cid != null) visit(cid.toString());
      }
      for (final o in _listOf(row, 'options')) {
        final oid = _asId(o);
        if (oid != null) visit(oid.toString());
      }
    }

    visit(rootId);
    return set;
  }

  void _deleteComment(String id) {
    setState(() {
      final doomed = _descendants(id);
      // 从所有 owner 的 comments / options 里解绑
      for (final tbl in [_posts, _comments]) {
        for (final e in tbl.entries) {
          final row = e.value is Map ? (e.value as Map).cast<String, dynamic>() : null;
          if (row == null) continue;
          final kids = _listOf(row, 'comments')
            ..removeWhere((pair) => doomed.contains(_asId(pair)?.toString()));
          row['comments'] = kids;
          final opts = _listOf(row, 'options')
            ..removeWhere((o) => doomed.contains(_asId(o)?.toString()));
          row['options'] = opts;
        }
      }
      for (final d in doomed) {
        _comments.remove(d);
      }
      if (_target != null && doomed.contains(_target)) _target = null;
    });
  }

  // ------------------------------------------------------------------
  // 构建
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: palette.bgDeep2,
        child: const Center(child: fluent.ProgressRing()),
      );
    }
    if (_error != null) {
      return Container(
        color: palette.bgDeep2,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.error_circle_24_regular,
                  size: 34, color: palette.statusDanger),
              const SizedBox(height: 10),
              Text('社交数据加载失败',
                  style: TextStyle(fontSize: 13, color: palette.textPrimary)),
              const SizedBox(height: 6),
              Text('$_error',
                  style: TextStyle(fontSize: 11, color: palette.textMuted)),
              const SizedBox(height: 12),
              fluent.Button(onPressed: _loadAll, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return WorkbenchScaffold(
      leftBuilder: (w) => _leftPanel(w),
      center: _center(),
      rightBuilder: (w) => _rightPanel(w),
      rightLabel: '动态设置',
    );
  }

  // ---------- 左栏：动态列表 ----------

  Widget _leftPanel(double w) {
    final q = _search.trim().toLowerCase();
    final ids = _sortedPostIds.where((id) {
      if (q.isEmpty) return true;
      final row = _row(_posts, id);
      final role = _roleName(_asId(row?['role'] ?? 0) ?? 0).toLowerCase();
      final title = row?['title']?.toString().toLowerCase() ?? '';
      final content = row?['content']?.toString().toLowerCase() ?? '';
      return id.contains(q) ||
          role.contains(q) ||
          title.contains(q) ||
          content.contains(q);
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
                  placeholder: '搜索动态或发布人物',
                  onChanged: (v) => setState(() => _search = v),
                ),
                const SizedBox(height: 10),
                fluent.FilledButton(
                  onPressed: _newPost,
                  child: const Text('＋ 发布动态',
                      style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(height: 6),
                _MiniBtn(
                  label: '删除这条动态',
                  danger: true,
                  enabled: _selected != null,
                  onTap: _deletePost,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.border),
          Expanded(
            child: ids.isEmpty
                ? Center(
                    child: Text(
                      _posts.isEmpty ? '还没有动态，点「发布动态」新建。' : '没有匹配的动态。',
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
                      final row = _row(_posts, id);
                      final role = _asId(row?['role'] ?? 0) ?? 0;
                      final title = row?['title']?.toString() ?? '';
                      final content = row?['content']?.toString() ?? '';
                      return _PostListItem(
                        id: id,
                        name: _roleName(role),
                        roleId: role,
                        title: title,
                        content: content,
                        commentCount: _commentCount(int.tryParse(id) ?? -1),
                        selected: id == _selected,
                        onTap: () => setState(() {
                          _selected = id;
                          _target = null;
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------- 中栏：正文 + 评论树 ----------

  Widget _center() {
    final post = _post;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: post == null
              ? Center(
                  child: Text(
                    '添加一条企鹅动态：先选发布人物，再写正文和评论。',
                    style: TextStyle(fontSize: 13, color: palette.textHint),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
                  child: _postBody(post),
                ),
        ),
        _saveBar(),
      ],
    );
  }

  Widget _postBody(Map<String, dynamic> post) {
    final id = _selected!;
    final role = _asId(post['role'] ?? 0) ?? 0;
    final imgs = _listOf(post, 'imgs');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 动态卡片
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Avatar(seed: role, name: _roleName(role), size: 42),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () async {
                            final picked = await _pickRole();
                            if (picked == null || !mounted) return;
                            setState(() => post['role'] = picked);
                          },
                          child: Text(
                            _roleName(role),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: palette.textHigh),
                          ),
                        ),
                      ),
                      Text('企鹅空间 · ID $id',
                          style: TextStyle(
                              fontSize: 11, color: palette.textHint)),
                    ],
                  ),
                  const Spacer(),
                  Text('${_commentCount(int.tryParse(id) ?? -1)} 条评论',
                      style: TextStyle(
                          fontSize: 11.5, color: palette.textMuted)),
                ],
              ),
              const SizedBox(height: 14),
              _SyncedText(
                value: post['title']?.toString() ?? '',
                hint: '说说标题（可留空）',
                onChanged: (v) => setState(() => post['title'] = v),
              ),
              const SizedBox(height: 10),
              _SyncedText(
                value: post['content']?.toString() ?? '',
                hint: '输入动态内容',
                maxLines: 5,
                onChanged: (v) => setState(() => post['content'] = v),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < imgs.length; i++)
                    _ImageTile(
                      path: imgs[i].toString(),
                      onRemove: () => setState(() {
                        final list = _listOf(post, 'imgs')..removeAt(i);
                        post['imgs'] = list;
                      }),
                    ),
                  _AddImageTile(onTap: () async {
                    final picked = await showImageAssetPicker(
                      context,
                      title: '选择动态配图',
                      multiSelect: true,
                      initialSelected: imgs.map((e) => e.toString()).toList(),
                    );
                    if (picked == null || !mounted) return;
                    setState(() {
                      final list = _listOf(post, 'imgs');
                      for (final p in picked) {
                        if (!list.contains(p)) list.add(p);
                      }
                      post['imgs'] = list;
                    });
                  }),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Icon(FluentIcons.chat_24_regular,
                size: 15, color: palette.goldText),
            const SizedBox(width: 6),
            Text('评论与回复',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.textHigh)),
            const Spacer(),
            _MiniBtn(label: '＋ 添加评论', onTap: () => _addComment()),
          ],
        ),
        const SizedBox(height: 10),
        ..._commentTree(),
        if (_commentCount(int.tryParse(id) ?? -1) == 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('还没有评论。',
                style: TextStyle(fontSize: 12, color: palette.textHint)),
          ),
      ],
    );
  }

  /// 展平评论树（含回复与白雨可选），按渲染顺序返回。
  List<Widget> _commentTree() {
    final out = <Widget>[];
    final post = _post;
    if (post == null) return out;

    void renderOwner(Map<String, dynamic> owner, int depth) {
      final kids = _listOf(owner, 'comments');
      for (final pair in kids) {
        final cid = _asId(pair);
        if (cid == null) continue;
        final row = _row(_comments, cid.toString());
        if (row == null) continue;
        final delay = (pair is List && pair.length > 1)
            ? _asId(pair[1]) ?? 0
            : 0;
        out.add(_commentCard(cid.toString(), row, depth, delay: delay));
        renderOwner(row, depth + 1);
      }
      final opts = _listOf(owner, 'options');
      if (opts.isNotEmpty) {
        out.add(Padding(
          padding: EdgeInsets.only(left: depth * 20.0, top: 6, bottom: 4),
          child: Row(
            children: [
              Icon(FluentIcons.bot_24_regular,
                  size: 12, color: accentColor),
              const SizedBox(width: 5),
              Text('白雨可选',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: accentColor)),
            ],
          ),
        ));
        for (final o in opts) {
          final cid = _asId(o);
          if (cid == null) continue;
          final row = _row(_comments, cid.toString());
          if (row == null) continue;
          out.add(_commentCard(cid.toString(), row, depth + 1,
              option: true));
          renderOwner(row, depth + 2);
        }
      }
    }

    renderOwner(post, 0);
    return out;
  }

  Widget _commentCard(
    String id,
    Map<String, dynamic> row,
    int depth, {
    bool option = false,
    int delay = 0,
  }) {
    final roles = _listOf(row, 'roles');
    final author = roles.isNotEmpty ? _asId(roles.first) ?? 0 : 0;
    final selected = id == _target;
    final parent = _asId(row['parent']) ?? 0;
    final isReply = parent != 0;
    return Padding(
      padding: EdgeInsets.only(left: depth * 20.0, bottom: 10),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _target = id),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: selected ? palette.card : palette.bgAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? accentColor.withValues(alpha: 0.5)
                    : palette.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Avatar(seed: author, name: _roleName(author), size: 30),
                    const SizedBox(width: 8),
                    Text(_roleName(author),
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: palette.textHigh)),
                    if (option) ...[
                      const SizedBox(width: 8),
                      _Tag(text: isReply ? '白雨可选回复' : '白雨可选评论',
                          color: accentColor),
                    ],
                    if (isReply && !option) ...[
                      const SizedBox(width: 8),
                      _Tag(text: '回复', color: palette.textMuted),
                    ],
                    if (delay > 0) ...[
                      const SizedBox(width: 8),
                      _Tag(text: '等待 $delay 秒', color: palette.statusWarn),
                    ],
                    const Spacer(),
                    _MiniBtn(
                      label: '设置',
                      onTap: () => setState(() => _target = id),
                    ),
                    const SizedBox(width: 6),
                    _MiniBtn(
                      label: '回复',
                      onTap: () => _addComment(parentId: id),
                    ),
                    const SizedBox(width: 6),
                    if (!option)
                      _MiniBtn(
                        label: '白雨可选',
                        onTap: () => _addComment(parentId: id, player: true),
                      ),
                    const SizedBox(width: 6),
                    _MiniBtn(
                      label: '删除',
                      danger: true,
                      onTap: () => _deleteComment(id),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SyncedText(
                  value: row['content']?.toString() ?? '',
                  hint: '输入评论内容',
                  maxLines: 3,
                  onChanged: (v) => setState(() => row['content'] = v),
                ),
                if ((_listOf(row, 'condition')).isNotEmpty ||
                    (_listOf(row, 'effect')).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (_listOf(row, 'condition').isNotEmpty)
                        _Tag(
                            text:
                                '出现条件 ${_listOf(row, 'condition').length} 条',
                            color: palette.statusInfo),
                      if (_listOf(row, 'condition').isNotEmpty &&
                          _listOf(row, 'effect').isNotEmpty)
                        const SizedBox(width: 6),
                      if (_listOf(row, 'effect').isNotEmpty)
                        _Tag(
                            text: '评论效果 ${_listOf(row, 'effect').length} 条',
                            color: palette.statusOk),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _saveBar() {
    final dirty = _dirty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Icon(
            dirty
                ? FluentIcons.circle_24_filled
                : FluentIcons.checkmark_circle_24_regular,
            size: 12,
            color: dirty ? palette.statusWarn : palette.statusOk,
          ),
          const SizedBox(width: 6),
          Text(dirty ? '有未保存的修改' : '已与磁盘同步',
              style: TextStyle(fontSize: 11.5, color: palette.textSecondary)),
          const Spacer(),
          if (widget.onOpenSearch != null)
            _MiniBtn(label: '检索剧情库', onTap: widget.onOpenSearch!),
          const SizedBox(width: 8),
          _MiniBtn(
            label: '放弃修改',
            enabled: dirty && !_saving,
            onTap: _discard,
          ),
          const SizedBox(width: 8),
          fluent.FilledButton(
            onPressed: (!dirty || _saving) ? null : _saveAll,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_saving)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: fluent.ProgressRing(strokeWidth: 2),
                  )
                else
                  const Icon(FluentIcons.save_24_regular, size: 13),
                const SizedBox(width: 6),
                const Text('保存修改', style: TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 右栏：设置 ----------

  Widget _rightPanel(double w) {
    return Container(
      width: w,
      color: palette.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: _target == null ? _postSettings() : _commentSettings(),
      ),
    );
  }

  Widget _postSettings() {
    final post = _post;
    if (post == null) return const SizedBox.shrink();
    final id = _selected!;
    final thumbs = _listOf(post, 'thumbs');
    final cond = _listOf(post, 'cond');
    final options = _listOf(post, 'options');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PanelTitle('动态设置', 'ID $id'),
        _SectionCard(
          title: '点赞人物',
          subtitle: '首次查看动态后等待指定秒数点赞；0 表示立即点赞。',
          children: [
            for (var i = 0; i < thumbs.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    _Avatar(
                        seed: _asId(thumbs[i]) ?? 0,
                        name: _roleName(_asId(thumbs[i]) ?? 0),
                        size: 26),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_roleName(_asId(thumbs[i]) ?? 0),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: palette.textPrimary)),
                    ),
                    SizedBox(
                      width: 70,
                      child: _NumBox(
                        value: _thumbDelay(thumbs[i]),
                        hint: '延迟秒',
                        onChanged: (v) => setState(() {
                          final list = _listOf(post, 'thumbs');
                          list[i] = [
                            _asId(thumbs[i]) ?? 0,
                            (v ?? 0).toInt()
                          ];
                          post['thumbs'] = list;
                        }),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _MiniBtn(
                      label: '移除',
                      danger: true,
                      onTap: () => setState(() {
                        final list = _listOf(post, 'thumbs')..removeAt(i);
                        post['thumbs'] = list;
                      }),
                    ),
                  ],
                ),
              ),
            _MiniBtn(
              label: '＋ 选择点赞人物',
              onTap: () async {
                final picked = await _pickRole();
                if (picked == null || !mounted) return;
                setState(() {
                  final list = _listOf(post, 'thumbs');
                  if (!list.any((t) => _asId(t) == picked)) {
                    list.add([picked, 0]);
                  }
                  post['thumbs'] = list;
                });
              },
            ),
          ],
        ),
        _SectionCard(
          title: '白雨可选评论',
          subtitle: '玩家从这些评论中选择一条；在左侧评论卡片上点「白雨可选」添加。',
          children: [
            if (options.isEmpty)
              Text('尚未设置白雨可选评论',
                  style: TextStyle(fontSize: 11.5, color: palette.textHint))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in options)
                    _Chip(
                      text: _commentSnippet(_asId(o)?.toString()),
                      onTap: () => setState(
                          () => _target = _asId(o)?.toString()),
                    ),
                ],
              ),
          ],
        ),
        _SectionCard(
          title: '发布条件',
          subtitle: '全部满足后才发布这条动态；空列表表示由剧情效果发布。',
          children: [
            Text('已设置 ${cond.length} 条条件',
                style: TextStyle(fontSize: 12, color: palette.textMuted)),
            const SizedBox(height: 6),
            Text(
              '复杂条件（金钱、好感、状态等）请在通用配置表的条件编辑器中维护；'
              '这里只做动态与评论的编排。',
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: palette.textHint),
            ),
          ],
        ),
      ],
    );
  }

  Widget _commentSettings() {
    final c = _comment!;
    final id = _target!;
    final roles = _listOf(c, 'roles');
    final author = roles.isNotEmpty ? _asId(roles.first) ?? 0 : 0;
    final cond = _listOf(c, 'condition');
    final effect = _listOf(c, 'effect');
    final options = _listOf(c, 'options');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _PanelTitle('评论设置', 'ID $id'),
            const Spacer(),
            _MiniBtn(
              label: '返回动态',
              onTap: () => setState(() => _target = null),
            ),
          ],
        ),
        _SectionCard(
          title: '发言者',
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () async {
                  final picked = await _pickRole(includeBaiyu: author == 0);
                  if (picked == null || !mounted) return;
                  setState(() {
                    final list = _listOf(c, 'roles');
                    if (list.isEmpty) {
                      list.add(picked);
                    } else {
                      list[0] = picked;
                    }
                    c['roles'] = list;
                  });
                },
                child: Row(
                  children: [
                    _Avatar(seed: author, name: _roleName(author), size: 30),
                    const SizedBox(width: 8),
                    Text(_roleName(author),
                        style: TextStyle(
                            fontSize: 12.5, color: palette.textPrimary)),
                    const Spacer(),
                    Text('更换', style: TextStyle(fontSize: 11, color: accentColor)),
                  ],
                ),
              ),
            ),
          ],
        ),
        _SectionCard(
          title: '白雨可回复',
          subtitle: '在这条评论后，玩家可从这些回复中选一条。',
          children: [
            if (options.isEmpty)
              Text('尚未设置白雨可回复',
                  style: TextStyle(fontSize: 11.5, color: palette.textHint))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in options)
                    _Chip(
                      text: _commentSnippet(_asId(o)?.toString()),
                      onTap: () =>
                          setState(() => _target = _asId(o)?.toString()),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            _MiniBtn(
              label: '＋ 添加白雨可选回复',
              onTap: () => _addComment(parentId: id, player: true),
            ),
          ],
        ),
        _SectionCard(
          title: '条件与效果',
          children: [
            Text('出现条件：${cond.length} 条　评论效果：${effect.length} 条',
                style: TextStyle(fontSize: 12, color: palette.textMuted)),
            const SizedBox(height: 6),
            Text(
              '条件与效果（金钱、好感、状态变化等）请在通用配置表中用条件 / 效果'
              '编辑器维护；这里负责评论与回复的编排。',
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: palette.textHint),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _MiniBtn(
          label: '删除这条评论',
          danger: true,
          onTap: () => _deleteComment(id),
        ),
      ],
    );
  }

  int _thumbDelay(dynamic pair) {
    if (pair is List && pair.length > 1) return _asId(pair[1]) ?? 0;
    return 0;
  }

  String _commentSnippet(String? id) {
    if (id == null) return '（评论）';
    final c = _row(_comments, id);
    final content = c?['content']?.toString() ?? '';
    if (content.trim().isEmpty) return 'ID $id';
    return content.length > 18 ? '${content.substring(0, 18)}…' : content;
  }
}

// ----------------------------------------------------------------------
// 通用小部件
// ----------------------------------------------------------------------

class _Avatar extends StatelessWidget {
  const _Avatar({required this.seed, required this.name, this.size = 36});

  final int seed;
  final String name;
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
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        ch,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          color: c,
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: palette.border),
          ),
          child: Text(widget.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.textPrimary)),
        ),
      ),
    );
  }
}

class _ImageTile extends StatefulWidget {
  const _ImageTile({required this.path, required this.onRemove});
  final String path;
  final VoidCallback onRemove;

  @override
  State<_ImageTile> createState() => _ImageTileState();
}

class _ImageTileState extends State<_ImageTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        width: 130,
        height: 96,
        decoration: BoxDecoration(
          color: palette.bgDeep2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: TexThumb(
                keyName: widget.path,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
            if (_hover)
              Positioned(
                top: 4,
                right: 4,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: widget.onRemove,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: palette.scrim,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Icon(FluentIcons.dismiss_24_regular,
                          size: 12, color: palette.statusDanger),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AddImageTile extends StatefulWidget {
  const _AddImageTile({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_AddImageTile> createState() => _AddImageTileState();
}

class _AddImageTileState extends State<_AddImageTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 130,
          height: 96,
          decoration: BoxDecoration(
            color: _hover ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: palette.borderHover),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(FluentIcons.add_24_regular,
                  size: 18, color: palette.textSecondary),
              const SizedBox(height: 6),
              Text('添加配图',
                  style: TextStyle(fontSize: 11, color: palette.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PostListItem extends StatefulWidget {
  const _PostListItem({
    required this.id,
    required this.name,
    required this.roleId,
    required this.title,
    required this.content,
    required this.commentCount,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String name;
  final int roleId;
  final String title;
  final String content;
  final int commentCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PostListItem> createState() => _PostListItemState();
}

class _PostListItemState extends State<_PostListItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final snippet = widget.title.isNotEmpty
        ? widget.title
        : (widget.content.isEmpty ? '空白动态' : widget.content);
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(seed: widget.roleId, name: widget.name, size: 36),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(widget.name,
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
                        ),
                        Text(widget.id,
                            style: TextStyle(
                                fontSize: 10, color: palette.textHint)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: palette.textMuted),
                    ),
                    const SizedBox(height: 4),
                    Text('${widget.commentCount} 条评论',
                        style: TextStyle(
                            fontSize: 10.5, color: palette.textHint)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.title, this.subtitle);
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: palette.textHigh)),
          const SizedBox(width: 8),
          Text(subtitle,
              style: TextStyle(fontSize: 11, color: palette.textHint)),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.goldText)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: TextStyle(
                    fontSize: 11, height: 1.6, color: palette.textMuted)),
          ],
          const SizedBox(height: 10),
          for (final c in children) ...[
            c,
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _SyncedText extends StatefulWidget {
  const _SyncedText({
    required this.value,
    required this.onChanged,
    this.hint,
    this.maxLines = 1,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final int maxLines;

  @override
  State<_SyncedText> createState() => _SyncedTextState();
}

class _SyncedTextState extends State<_SyncedText> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _SyncedText old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _c.text) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: _c,
      focusNode: _focus,
      maxLines: widget.maxLines,
      placeholder: widget.hint,
      onChanged: widget.onChanged,
    );
  }
}

class _NumBox extends StatefulWidget {
  const _NumBox({required this.value, required this.onChanged, this.hint});
  final num? value;
  final ValueChanged<num?> onChanged;
  final String? hint;

  @override
  State<_NumBox> createState() => _NumBoxState();
}

class _NumBoxState extends State<_NumBox> {
  late final TextEditingController _c =
      TextEditingController(text: widget.value?.toString() ?? '');
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _NumBox old) {
    super.didUpdateWidget(old);
    final cur = widget.value?.toString() ?? '';
    if (!_focus.hasFocus && cur != _c.text) _c.text = cur;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return fluent.TextBox(
      controller: _c,
      focusNode: _focus,
      placeholder: widget.hint,
      onChanged: (v) => widget.onChanged(
          v.trim().isEmpty ? null : int.tryParse(v)),
    );
  }
}

class _MiniBtn extends StatefulWidget {
  const _MiniBtn({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool danger;

  @override
  State<_MiniBtn> createState() => _MiniBtnState();
}

class _MiniBtnState extends State<_MiniBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? palette.iconDisabled
        : widget.danger
            ? palette.statusDanger
            : palette.textPrimary;
    return MouseRegion(
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _hover && widget.enabled ? palette.card : palette.bgAlt,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: widget.danger && widget.enabled
                  ? palette.statusDanger.withValues(alpha: 0.35)
                  : palette.border,
            ),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: color),
          ),
        ),
      ),
    );
  }
}

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/responsive.dart';
import '../settings/settings_page.dart';
import 'effect_hint_field.dart';
import 'field_utils.dart';
import 'section_card.dart';

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
  });
  final AppState state;
  final String cfgName;

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

  void _applyFilter() {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) {
      _filteredIds = List<String>.from(_sortedIds);
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
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SchemaEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cfgName != widget.cfgName) {
      _load();
    } else if (widget.selectedId != null && widget.selectedId != _selectedId) {
      setState(() => _selectedId = widget.selectedId);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loaded = false;
      _missing = false;
      _error = null;
    });
    try {
      final r = await ApiClient.instance.get('/api/cfg/${widget.cfgName}');
      if (!mounted) return;
    setState(() {
      _idCandidatesCache.clear(); // 配置表重载后候选缓存失效
      _data = (r['data'] as Map).cast<String, dynamic>();
        _missing = r['exists'] == false;
        _loaded = true;
        _rebuildSortedIds();
        if (widget.selectedId != null && _data.containsKey(widget.selectedId)) {
          _selectedId = widget.selectedId;
        } else {
          _selectedId = _sortedIds.isNotEmpty ? _sortedIds.first : null;
        }
        _dirty = false;
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

  Future<void> _save() async {
    // 保存前指南校验：请求失败（网络/后端旧版本）时静默降级，直接保存不阻塞
    List<Map<String, dynamic>>? issues;
    try {
      final r = await ApiClient.instance
          .post('/api/validate', body: {'cfg': widget.cfgName, 'data': _data})
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
        final force = await _showValidateConfirm(issues, nError, nWarn, nInfo);
        if (!force || !mounted) return;
      }
    }

    try {
      await ApiClient.instance.put(
        '/api/cfg/${widget.cfgName}',
        body: {'data': _data},
      );
      if (!mounted) return;
      setState(() => _dirty = false);
      // 结果提示：错误/警告优先于成功提示
      if (nError > 0) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: Text('已保存，但指南校验发现 $nError 个错误'),
            severity: fluent.InfoBarSeverity.warning,
          ),
        );
      } else if (nWarn > 0) {
        final extra = nInfo > 0 ? '、$nInfo 条提示' : '';
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: Text('已保存，但有 $nWarn 条警告$extra'),
            severity: fluent.InfoBarSeverity.warning,
          ),
        );
      } else {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => const fluent.InfoBar(
            title: Text('已保存'),
            severity: fluent.InfoBarSeverity.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        fluent.displayInfoBar(
          context,
          builder: (ctx, close) => fluent.InfoBar(
            title: Text('保存失败'),
            content: Text(e.toString()),
            severity: fluent.InfoBarSeverity.error,
          ),
        );
      }
    }
  }

  Future<void> _addEntry() async {
    final id = (await _nextId()).toString();
    if (!mounted) return;
    setState(() {
      _data[id] = {'id': id};
      _rebuildSortedIds();
      _selectedId = id;
      _dirty = true;
    });
  }

  void _deleteEntry(String id) {
    setState(() {
      _data.remove(id);
      _rebuildSortedIds();
      if (_selectedId == id) {
        _selectedId = _sortedIds.isNotEmpty ? _sortedIds.first : null;
      }
      _dirty = true;
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
          width: 480,
          height: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '发现 $nError 个错误、$nWarn 条警告、$nInfo 条提示'
                '（依据官方《学生时代》Mod 指南）。',
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFD4D4D8)),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1F),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF2A2A2E)),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: issues.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: Color(0xFF26262B)),
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
      color = const Color(0xFFE05A5A);
      label = '错误';
    } else if (level == 'warn') {
      color = const Color(0xFFFFA726);
      label = '警告';
    } else {
      color = const Color(0xFF9B9BA3);
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
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFD4D4D8),
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
          style: const TextStyle(color: Color(0xFF9B9BA3), fontSize: 13),
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
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9B9BA3),
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
                              color: const Color(0xFF2E2A45),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFF4A3DB8),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  FluentIcons.play_24_regular,
                                  size: 12,
                                  color: Color(0xFF8B7FEF),
                                ),
                                SizedBox(width: 4),
                                Text(
                                  '预览',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFA99FF4),
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
                        child: const Icon(
                          FluentIcons.add_24_regular,
                          size: 15,
                          color: Color(0xFF8B8B93),
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
                  color: const Color(0xFF2A2418),
                  child: const Text(
                    '该配置表尚不存在，添加条目并保存后将自动创建',
                    style: TextStyle(fontSize: 11, color: Color(0xFFE08A3C)),
                  ),
                ),
              // 筛选
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: fluent.TextBox(
                  placeholder: '筛选 ID/标题…',
                  onChanged: (v) => setState(() {
                    _filter = v;
                    _applyFilter();
                  }),
                  suffix: const Icon(FluentIcons.search_24_regular, size: 12),
                ),
              ),
              const Divider(height: 1, color: Color(0xFF2A2A2E)),
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
          const VerticalDivider(width: 1, color: Color(0xFF2A2A2E)),
          // 右侧字段表单
          Expanded(
          child: _selectedRecord == null
              ? const Center(
                  child: Text(
                    '选择左侧条目进行编辑',
                    style: TextStyle(color: Color(0xFF6E6E76), fontSize: 13),
                  ),
                )
              : Column(
                  children: [
                    Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Text(
                            '字段编辑',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF9B9BA3),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          if (_dirty) ...[
                            Text(
                              '有未保存修改',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFE08A3C),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          fluent.FilledButton(
                            onPressed: _save,
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
                    const Divider(height: 1, color: Color(0xFF2A2A2E)),
                    Expanded(
                      child: _FieldForm(
                        cfgName: widget.cfgName,
                        record: _selectedRecord!,
                        fieldKeys: _fieldKeys,
                        fieldType: _fieldType,
                        translator: translator,
                        gameDicts: widget.state.gameDicts,
                        loadIdCandidates: _loadIdCandidates,
                        onChanged: () => setState(() => _dirty = true),
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
          color: selected ? const Color(0xFF2B2B31) : Colors.transparent,
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
                            ? Colors.white
                            : const Color(0xFFD4D4D8),
                      ),
                    ),
                    Text(
                      'ID: $id',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6E6E76),
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => _deleteEntry(id),
                child: const Icon(
                  FluentIcons.delete_24_regular,
                  size: 14,
                  color: Color(0xFF6E6E76),
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
          onChanged: () => setState(() => _dirty = true),
          onSave: _save,
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
        const Text(
          '更多高级工具（剧本导入导出、批量处理等）请在创作布局中使用。',
          style: TextStyle(fontSize: 11, color: Color(0xFF8B8B93), height: 1.5),
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
                        color: const Color(0xFF2A2418),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '该配置表尚不存在，添加条目并保存后将自动创建',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFE08A3C),
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
                  ? const Center(
                      child: Text(
                        '选择左侧条目进行编辑',
                        style: TextStyle(
                          color: Color(0xFF6E6E76),
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
                            onChanged: () => setState(() => _dirty = true),
                            classic: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (_dirty)
                              const Text(
                                '有未保存修改',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFE08A3C),
                                ),
                              ),
                            const Spacer(),
                          ],
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: fluent.FilledButton(
                            onPressed: _save,
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
            const Icon(FluentIcons.edit_24_regular, size: 36, color: Color(0xFF4A4A52)),
            const SizedBox(height: 8),
            Text(
              _data.isEmpty ? '该配置表暂无数据，请新建条目' : '请在左侧选择条目进行编辑',
              style: const TextStyle(color: Color(0xFF6E6E76), fontSize: 13),
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
            onChanged: () => setState(() => _dirty = true),
            classic: true,
          ),
        ),
        const SizedBox(height: 8),
        if (_dirty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              '● 有未保存修改',
              style: TextStyle(fontSize: 11, color: Color(0xFFE08A3C)),
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 32,
          child: fluent.FilledButton(
            onPressed: _save,
            style: const fluent.ButtonStyle(
              backgroundColor: WidgetStatePropertyAll(Color(0xFF6C5CE7)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF131316),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1F),
        elevation: 0,
        leading: const BackButton(color: Colors.white),
        title: Text(
          entryTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, color: Colors.white),
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
    final bg = primary ? const Color(0xFF6C5CE7) : const Color(0xFF26262B);
    final fg = primary ? Colors.white : const Color(0xFFD4D4D8);
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
                  : Border.all(color: const Color(0xFF3A3A42)),
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

/// [dictName] 指向 /api/dicts 返回的 game_dicts 字典名；[fixed] 为固定选项（id → 名称）；
/// [singleArray] 为 true 时 1D Array 字段按单选处理（显示下拉），否则多值文本框 + 名称预览。
class _FieldRule {
  const _FieldRule({
    this.dictName,
    this.fixed,
    this.singleArray = false,
    this.idRefCfg,
  });
  final String? dictName;
  final Map<String, String>? fixed;
  final bool singleArray;

  /// ID 引用字段：指向的配置表名（如 TalkCfg），候选为「ID · 预览」。
  final String? idRefCfg;
}

/// 按 `cfgName:key` 精确匹配的下拉框规则（优先于全局 key 匹配，按配置表逐项处理）。
const _ruleByCfgField = <String, _FieldRule>{
  // EvtCfg 事件编辑：事件类型 / 事件表现形式
  'EvtCfg:type': _FieldRule(dictName: 'evt_types'),
  'EvtCfg:displayType': _FieldRule(fixed: {'0': '默认形式', '1': '弹窗形式'}),
  // ActionCfg 行动类型
  'ActionCfg:type': _FieldRule(
    fixed: {'0': '普通', '1': '场景(禁用)', '2': '功能(禁用)', '3': '恋爱', '4': '兼职'},
  ),
  // ShopCfg 商店物品类型
  'ShopCfg:type': _FieldRule(
    fixed: {'1': '消耗品', '2': '珍视物品', '3': '书籍', '4': '工具'},
  ),
  // PaperCfg 纸条类型
  'PaperCfg:type': _FieldRule(fixed: {'0': '收到纸条', '1': '玩家写的'}),
  // GiftEvtCfg 送礼：收下/拒收（1D Array）
  'GiftEvtCfg:type': _FieldRule(fixed: {'0': '收下', '1': '拒收'}),
  // EndingDatingCfg 约会对象性别要求
  'EndingDatingCfg:gender': _FieldRule(fixed: {'1': '要求男生', '2': '要求女生'}),
  // ExploreCfg 探索等级
  'ExploreCfg:lv': _FieldRule(fixed: {'1': '一级探索', '2': '二级探索', '3': '三级探索'}),
  // PersonStateCfg 状态可见性
  'PersonStateCfg:hide': _FieldRule(fixed: {'0': '状态', '1': '不可见', '2': '性格'}),
  // PersonAttrCfg 属性
  'PersonAttrCfg:tag': _FieldRule(fixed: {'10': '普通属性', '13': '性格关联属性'}),
  'PersonAttrCfg:consume': _FieldRule(
    fixed: {'0': '不能', '1': '能', '2': '能且在最终结算展示'},
  ),
  'PersonAttrCfg:valueInUI': _FieldRule(
    fixed: {'null': '保留一位小数', 'int': '整数', '{0:0.#%}': '百分比'},
  ),
  // MinigameActionCfg 小游戏动作：需要的关系
  'MinigameActionCfg:needRelation': _FieldRule(dictName: 'relations'),
  // MinigameCfg 小游戏：背景音乐
  'MinigameCfg:bgm': _FieldRule(dictName: 'audios'),
  // BadmintonModelCfg 羽毛球模型：url 为模型名数组，单选
  'BadmintonModelCfg:url': _FieldRule(
    dictName: 'badminton_models',
    singleArray: true,
  ),
  // ID 引用字段：候选来自对应配置表（「ID · 预览」，懒加载 /api/cfg_ids）
  'EvtCfg:talkId': _FieldRule(idRefCfg: 'TalkCfg'),
  'TalkCfg:nextTalk': _FieldRule(idRefCfg: 'TalkCfg'),
  'TalkCfg:nextTalk2': _FieldRule(idRefCfg: 'TalkCfg'),
  'TalkCfg:option': _FieldRule(idRefCfg: 'OptionCfg'),
  'OptionCfg:talkId': _FieldRule(idRefCfg: 'TalkCfg'),
  'OptionCfg:talkId2': _FieldRule(idRefCfg: 'TalkCfg'),
  'OptionCfg:nextEvtId': _FieldRule(idRefCfg: 'EvtCfg'), // Number 字段，下拉单选
};

/// 全局字段 key → 下拉框规则（兜底）。
const _ruleByField = <String, _FieldRule>{
  'role': _FieldRule(dictName: 'roles'), // 发布者ID / 发送者ID
  'roleIds': _FieldRule(dictName: 'roles'), // 说话人（群组，可多值）
  'npc': _FieldRule(dictName: 'roles'), // 指定对象
  'roleId': _FieldRule(dictName: 'roles'),
  'npcId': _FieldRule(dictName: 'roles'),
  'item': _FieldRule(dictName: 'items'),
  'itemId': _FieldRule(dictName: 'items'),
  'reward': _FieldRule(dictName: 'items'),
  'bgm': _FieldRule(dictName: 'audios'),
  'sound': _FieldRule(dictName: 'sound'),
  'bg': _FieldRule(dictName: 'bgs'), // 背景图
  'icon': _FieldRule(dictName: 'icons'),
  'face': _FieldRule(dictName: 'icons'),
  'map': _FieldRule(dictName: 'maps'),
  'mapId': _FieldRule(dictName: 'maps'),
  'job': _FieldRule(dictName: 'jobs'),
  'jobId': _FieldRule(dictName: 'jobs'),
  'attr': _FieldRule(dictName: 'attrs'),
  'attrId': _FieldRule(dictName: 'attrs'),
  'disappearTime': _FieldRule(dictName: 'turns'), // 消失回合
  'action': _FieldRule(dictName: 'actions'),
};

/// 取字段对应的下拉框规则：cfg 限定优先，其次全局 key。
_FieldRule? _ruleFor(String cfgName, String key) =>
    _ruleByCfgField['$cfgName:$key'] ?? _ruleByField[key];

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

  @override
  State<_FieldForm> createState() => _FieldFormState();
}

class _FieldFormState extends State<_FieldForm> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fieldKeys = widget.fieldKeys;
    final record = widget.record;
    final gameDicts = widget.gameDicts;
    if (widget.classic) {
      return _buildClassicTable(fieldKeys, record, gameDicts);
    }
    return fluent.Scrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(16),
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemCount: fieldKeys.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    'ID: ${record['id'] ?? record.keys.first}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    widget.cfgName,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6E6E76),
                    ),
                  ),
                ],
              ),
            );
          }
          final key = fieldKeys[i - 1];
          final type = widget.fieldType(key) ?? 'String';
          final label = widget.translator.translate(key, widget.cfgName);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      flex: 2,
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFFD4D4D8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF5E5E66),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '[$type]',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF5E5E66),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '「$label」字段的值：类型为 [$type]，按编码格式输入',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8B8B93),
                  ),
                ),
                const SizedBox(height: 4),
                _FieldInput(
                  fieldKey: key,
                  value: record[key],
                  type: type,
                  rule: _ruleFor(widget.cfgName, key),
                  gameDicts: gameDicts,
                  idCandidates: widget.loadIdCandidates,
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
    );
  }

  /// 经典布局：两列表格（属性名称 | 属性值）。
  Widget _buildClassicTable(
    List<String> fieldKeys,
    Map<String, dynamic> record,
    Map<String, dynamic> gameDicts,
  ) {
    return fluent.Scrollbar(
      controller: _scrollCtrl,
      child: ListView(
        controller: _scrollCtrl,
        padding: EdgeInsets.zero,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(
                    'ID: ${record['id'] ?? record.keys.first}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    widget.cfgName,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6E6E76),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 表头
          Container(
            color: const Color(0xFF26262B),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: const Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    '属性名称',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9B9BA3),
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
                      color: Color(0xFF9B9BA3),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 字段行
          for (final key in fieldKeys) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0xFF26262B), width: 1),
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
                        Text(
                          widget.translator.translate(key, widget.cfgName),
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFFD4D4D8),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          key,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF5E5E66),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 7,
                    child: _FieldInput(
                      fieldKey: key,
                      value: record[key],
                      type: widget.fieldType(key) ?? 'String',
                      rule: _ruleFor(widget.cfgName, key),
                      gameDicts: gameDicts,
                      idCandidates: widget.loadIdCandidates,
                      onChanged: (v) {
                        record[key] = v;
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FieldInput extends StatefulWidget {
  const _FieldInput({
    required this.value,
    required this.type,
    required this.onChanged,
    this.rule,
    this.gameDicts = const {},
    this.fieldKey,
    this.idCandidates,
  });
  final dynamic value;
  final String type;
  final ValueChanged<dynamic> onChanged;
  final _FieldRule? rule;
  final Map<String, dynamic> gameDicts;
  /// 原始字段 key，用于决定走 effect/condition/cost 哪套提示
  final String? fieldKey;

  /// ID 引用候选加载器（rule.idRefCfg 指定的配置表，懒加载 + 上层缓存）。
  final Future<List<(String, String)>> Function(String cfg)? idCandidates;
  @override
  State<_FieldInput> createState() => _FieldInputState();
}

class _FieldInputState extends State<_FieldInput> {
  late final TextEditingController _ctrl;
  // ID 引用候选（异步加载后填充）
  List<(String, String)> _idOpts = const [];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ValueCodec.encode(widget.value));
    _loadIdOpts();
  }

  @override
  void didUpdateWidget(covariant _FieldInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    final enc = ValueCodec.encode(widget.value);
    if (_ctrl.text != enc) {
      _ctrl.text = enc;
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
    super.dispose();
  }

  /// 下拉选项：(id, 名称)。来自固定选项或 game_dicts 字典。
  List<(String, String)> _options() {
    final rule = widget.rule;
    if (rule == null) return [];
    final out = <(String, String)>[];
    final fixed = rule.fixed;
    if (fixed != null) {
      for (final e in fixed.entries) {
        out.add((e.key, e.value));
      }
    } else if (rule.idRefCfg != null) {
      // ID 引用字段：候选由上层异步加载（本表数据或 /api/cfg_ids）
      out.addAll(_idOpts);
    } else {
      final name = rule.dictName;
      if (name == null || name == 'actions') return [];
      final dict = widget.gameDicts[name];
      if (dict is! Map) return [];
      for (final e in dict.entries) {
        final v = e.value;
        var label = v.toString();
        if (v is List && v.isNotEmpty) label = v.first.toString();
        out.add((e.key.toString(), label));
      }
    }
    out.sort((a, b) {
      final an = int.tryParse(a.$1);
      final bn = int.tryParse(b.$1);
      if (an != null && bn != null) return an.compareTo(bn);
      return a.$1.compareTo(b.$1);
    });
    return out;
  }

  /// 名称预览：把输入中的 ID 解析成「ID → 名称」（支持逗号/分号/顿号多值）。
  String? _namePreview(String text, List<(String, String)> opts) {
    if ((widget.rule?.dictName == null && widget.rule?.idRefCfg == null) ||
        opts.isEmpty) {
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
      final match = opts.where((o) => o.$1 == t).firstOrNull;
      if (match == null) {
        parts.add('$t → 未找到');
      } else {
        parts.add(match.$2.isEmpty ? t : '$t → ${match.$2}');
      }
    }
    return parts.join('，');
  }

  /// 弹出「ID · 预览」候选列表（可多选），确定后追加为逗号分隔多值。
  Future<void> _pickIdsFromList() async {
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
    final merged = [...existing, ...picked.where((e) => !existing.contains(e))];
    final newText = merged.join(', ');
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(offset: newText.length);
    try {
      widget.onChanged(ValueCodec.decode(newText, widget.type));
    } catch (_) {}
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 2D Array 优先走友商同款效果提示（候选+校验），与友商 SmartTemplateEditor 对齐
    final hasDictOptions = _options().isNotEmpty;
    final k = (widget.fieldKey ?? '').toLowerCase();
    final isEffectLikeKey = k.contains('effect') ||
        k == 'condition' || k == 'cond' || k == 'precondition' || k == 'check' ||
        k == 'cost' || k == 'effect2' || k == 'hideeffect' || k == 'usingeffect' ||
        k == 'pressure' || k == 'grow';
    // roles（TalkCfg.roles 指令行）/ screenEffect（1D 扁平代码）同样走效果提示
    final isActionOrScreen = k == 'roles' || k == 'screeneffect';
    final useEffectHint = !hasDictOptions &&
        ((widget.type == '2D Array' && (isEffectLikeKey || k.isEmpty)) ||
            (isActionOrScreen &&
                (widget.type == '2D Array' || widget.type == '1D Array')));

    if (useEffectHint) {
      final fieldKey = widget.fieldKey ?? 'effect';
      return EffectHintField(
        key: ValueKey('hint_${fieldKey}_${widget.type}'),
        value: widget.value,
        type: widget.type,
        fieldKey: fieldKey,
        // 显式指定模式，避免脆弱的 key 推断：roles→action、screenEffect→screen
        mode: k == 'roles' ? 'action' : (k == 'screeneffect' ? 'screen' : null),
        onChanged: widget.onChanged,
      );
    }
    final opts = _options();
    final isSingleArray =
        widget.type == '1D Array' && widget.rule?.singleArray == true;
    final isStringFixed = widget.type == 'String' && widget.rule?.fixed != null;
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
      final currentName = opts
          .where((o) => o.$1 == currentId)
          .map((o) => o.$2)
          .firstOrNull;
      return Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220, minWidth: 120),
            child: fluent.ComboBox<String>(
              value: opts.any((o) => o.$1 == currentId) ? currentId : null,
              isExpanded: true,
              placeholder: Text(
                currentName != null && currentName.isNotEmpty
                    ? '$currentId · $currentName'
                    : (currentId.isNotEmpty ? currentId : '选择或输入 ID'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              items: [
                for (final o in opts)
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
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                fluent.TextBox(
                  controller: _ctrl,
                  onChanged: (_) {
                    widget.onChanged(
                      ValueCodec.decode(_ctrl.text, widget.type),
                    );
                    setState(() {});
                  },
                ),
                if (_namePreview(_ctrl.text, opts) case final preview?)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      preview,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8B8B93),
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
    final preview = _namePreview(_ctrl.text, opts);
    // ID 引用的多值字段：文本框旁提供「从列表选择」入口
    final canPickIds = widget.type == '1D Array' &&
        widget.rule?.idRefCfg != null &&
        opts.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: fluent.TextBox(
                controller: _ctrl,
                maxLines: multiline ? 3 : 1,
                onChanged: (_) {
                  try {
                    widget.onChanged(ValueCodec.decode(_ctrl.text, widget.type));
                  } catch (_) {}
                  setState(() {});
                },
              ),
            ),
            if (canPickIds) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: fluent.Button(
                  onPressed: _pickIdsFromList,
                  child: const Text('从列表选择', style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ],
        ),
        if (preview != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              preview,
              style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
            ),
          ),
      ],
    );
  }
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

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  List<(String, String)> get _filtered {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty) return widget.options;
    return widget.options
        .where((o) => o.$1.contains(q) || o.$2.contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return fluent.ContentDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            fluent.TextBox(
              controller: _queryCtrl,
              placeholder: '筛选 ID 或内容…',
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text(
                        '无匹配候选',
                        style: TextStyle(fontSize: 12, color: Color(0xFF8B8B93)),
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
                                  ? const Color(0xFF2A3B52)
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
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFFD4D4D8),
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
                style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E76)),
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

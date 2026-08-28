import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../story/story_transfer_dialogs.dart';

/// 剧情库侧边栏：原版事件检索/提取 + 台词全文搜索。
/// FullTextSearchDialog）+ 故事剧本导入/导出入口。
class BaseSearchPage extends StatefulWidget {
  const BaseSearchPage({super.key, required this.state});
  final AppState state;
  @override
  State<BaseSearchPage> createState() => _BaseSearchPageState();
}

class _BaseSearchPageState extends State<BaseSearchPage> {
  String _tab = 'events'; // events | talks
  Map<String, dynamic> _status = {};
  bool _loadingBase = false;

  // 事件检索
  final TextEditingController _evtQuery = TextEditingController();
  final String _evtNpc = '';
  final String _evtType = '';
  int _page = 1;
  final int _perPage = 30;
  int _total = 0;
  List<Map<String, dynamic>> _events = [];
  final Set<String> _selected = {};
  bool _evtBusy = false;

  // 台词搜索
  final TextEditingController _talkQuery = TextEditingController();
  List<Map<String, dynamic>> _talks = [];
  bool _talkBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  @override
  void dispose() {
    _evtQuery.dispose();
    _talkQuery.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final r = await ApiClient.instance.get('/api/base/status');
      if (!mounted) return;
      setState(() => _status = (r as Map).cast<String, dynamic>());
    } catch (_) {}
  }

  Future<void> _loadBase({bool force = false}) async {
    setState(() => _loadingBase = true);
    try {
      await ApiClient.instance.post('/api/base/load', body: {'force': force});
      // 轮询直到加载完成
      for (var i = 0; i < 600; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        final st = await ApiClient.instance.get('/api/base/status');
        if (!mounted) return;
        setState(() => _status = (st as Map).cast<String, dynamic>());
        if (_status['status'] != 'loading') break;
      }
    } catch (e) {
      if (mounted) _err(e.toString());
    } finally {
      if (mounted) setState(() => _loadingBase = false);
    }
  }

  Future<void> _searchEvents() async {
    setState(() => _evtBusy = true);
    try {
      final r = await ApiClient.instance.get(
        '/api/base/events',
        query: {
          'q': _evtQuery.text.trim(),
          'npc': _evtNpc,
          'type': _evtType,
          'page': '$_page',
          'per_page': '$_perPage',
        },
      );
      if (!mounted) return;
      final m = (r as Map).cast<String, dynamic>();
      setState(() {
        _events = (m['events'] as List? ?? []).cast<Map<String, dynamic>>();
        _total = m['total'] as int? ?? 0;
        _selected.clear();
      });
    } catch (e) {
      if (mounted) _err(e.toString());
    } finally {
      if (mounted) setState(() => _evtBusy = false);
    }
  }

  Future<void> _searchTalks() async {
    final q = _talkQuery.text.trim();
    if (q.isEmpty) return;
    setState(() => _talkBusy = true);
    try {
      final r = await ApiClient.instance.get(
        '/api/search/talk',
        query: {'q': q},
      );
      if (!mounted) return;
      setState(
        () => _talks = ((r as Map)['results'] as List? ?? [])
            .cast<Map<String, dynamic>>(),
      );
    } catch (e) {
      if (mounted) _err(e.toString());
    } finally {
      if (mounted) setState(() => _talkBusy = false);
    }
  }

  Future<void> _extract(String evtId) async {
    try {
      final r = await ApiClient.instance.post(
        '/api/base/extract',
        body: {'evt_id': evtId},
      );
      final imported = (r as Map)['imported'] as Map? ?? {};
      final parts = imported.entries
          .map((e) => '${e.key}×${e.value}')
          .join('，');
      if (!mounted) return;
      fluent.displayInfoBar(
        context,
        builder: (ctx, close) => fluent.InfoBar(
          title: const Text('提取成功'),
          content: Text('事件 [$evtId] 已提取到当前 Mod（$parts）'),
          severity: fluent.InfoBarSeverity.success,
        ),
      );
      setState(() => _selected.remove(evtId));
    } catch (e) {
      if (mounted) _err(e.toString());
    }
  }

  Future<void> _extractSelected() async {
    for (final id in _selected.toList()) {
      await _extract(id);
    }
  }

  void _err(String msg) {
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: const Text('操作失败'),
        content: Text(msg),
        severity: fluent.InfoBarSeverity.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        _statusCard(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              _tabBtn('events', '原版事件'),
              const SizedBox(width: 4),
              _tabBtn('talks', '台词搜索'),
              const Spacer(),
              if (_tab == 'events')
                _iconBtn(
                  FluentIcons.arrow_sync_24_regular,
                  '重新加载原版数据',
                  () => _loadBase(force: true),
                ),
              _iconBtn(
                FluentIcons.arrow_import_24_regular,
                '导入剧本',
                () => showStoryImportDialog(context, widget.state),
              ),
              _iconBtn(
                FluentIcons.arrow_export_24_regular,
                '导出剧本',
                () => showStoryExportDialog(context, widget.state),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF2A2A2E)),
        Expanded(child: _tab == 'events' ? _eventsTab() : _talksTab()),
      ],
    );
  }

  Widget _header() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(
            FluentIcons.book_search_24_regular,
            size: 15,
            color: Color(0xFF6C5CE7),
          ),
          const SizedBox(width: 8),
          const Text(
            '剧情库',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF9B9BA3),
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          _iconBtn(FluentIcons.arrow_sync_24_regular, '刷新状态', _refreshStatus),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final status = _status['status'] ?? 'idle';
    final Widget content;
    if (status == 'loading') {
      content = const Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在加载原版配置表…',
              style: TextStyle(fontSize: 11, color: Color(0xFF9B9BA3)),
            ),
          ),
        ],
      );
    } else if (status == 'ready') {
      final loaded = (_status['loaded'] as List? ?? []).length;
      final missing = (_status['missing'] as List? ?? []).length;
      content = Text(
        '原版数据已就绪：${_status['dirs']?.length ?? 0} 个目录 / $loaded 表'
        '${missing > 0 ? ' / 缺 $missing 表' : ''}',
        style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
      );
    } else if (status == 'error') {
      content = Text(
        '加载失败：${_status['error']}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Color(0xFFE5484D)),
      );
    } else {
      content = const Text(
        '未加载原版数据：配置 editor_env.json 或点击扫描',
        style: TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF222228),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2E2E34)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: content),
          if (status == 'idle' || status == 'error')
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _loadingBase ? null : _loadBase,
                  child: const Icon(
                    FluentIcons.play_24_regular,
                    size: 14,
                    color: Color(0xFF6C5CE7),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _eventsTab() {
    if (_status['status'] != 'ready') {
      return const Center(
        child: Text(
          '加载原版数据后可用',
          style: TextStyle(fontSize: 12, color: Color(0xFF6E6E76)),
        ),
      );
    }
    final maxPage = (_total / _perPage).ceil().clamp(1, 1 << 31);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '输入事件标题关键词或 ID 前缀，从已加载的原版数据中检索',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: fluent.TextBox(
            controller: _evtQuery,
            placeholder: '搜索事件（标题模糊 / ID 前缀）',
            onSubmitted: (_) => _searchEvents(),
            suffix: _iconBtn(
              FluentIcons.search_24_regular,
              '搜索',
              _searchEvents,
            ),
          ),
        ),
        if (_total > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  '共 $_total 个事件',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8B8B93),
                  ),
                ),
                const Spacer(),
                _pagerBtn('<', () {
                  if (_page > 1) {
                    setState(() => _page--);
                    _searchEvents();
                  }
                }),
                Text(
                  '$_page/$maxPage',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9B9BA3),
                  ),
                ),
                _pagerBtn('>', () {
                  if (_page < maxPage) {
                    setState(() => _page++);
                    _searchEvents();
                  }
                }),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: _evtBusy
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListView.builder(
                  itemCount: _events.length,
                  itemBuilder: (context, i) {
                    final evt = _events[i];
                    final id = evt['id'] as String? ?? '';
                    final title = evt['title'] as String? ?? '';
                    final selected = _selected.contains(id);
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: Row(
                        children: [
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => setState(() {
                                if (!selected) {
                                  _selected.add(id);
                                } else {
                                  _selected.remove(id);
                                }
                              }),
                              child: Icon(
                                selected
                                    ? FluentIcons.checkbox_checked_24_filled
                                    : FluentIcons.checkbox_unchecked_24_regular,
                                size: 16,
                                color: selected
                                    ? const Color(0xFF6C5CE7)
                                    : const Color(0xFF6E6E76),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  if (!selected) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                }),
                                child: Text(
                                  '[$id] $title',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFD4D4D8),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _extract(id),
                              child: Tooltip(
                                message: '提取到 Mod',
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                    FluentIcons.arrow_download_24_regular,
                                    size: 14,
                                    color: const Color(0xFF6C5CE7),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (_selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: fluent.Button(
              onPressed: _extractSelected,
              style: fluent.ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(
                  const Color(0xFF6C5CE7),
                ),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
              child: Text('提取选中 ${_selected.length} 个事件到 Mod'),
            ),
          ),
      ],
    );
  }

  Widget _talksTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '输入任意台词片段（支持部分匹配），在本体与 Mod 的台词库中全文检索',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8B8B93)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: fluent.TextBox(
            controller: _talkQuery,
            placeholder: '输入台词片段（本体 + Mod 全文检索）',
            onSubmitted: (_) => _searchTalks(),
            suffix: _iconBtn(FluentIcons.search_24_regular, '搜索', _searchTalks),
          ),
        ),
        Expanded(
          child: _talkBusy
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListView.builder(
                  itemCount: _talks.length,
                  itemBuilder: (context, i) {
                    final t = _talks[i];
                    final src = t['src'] as String? ?? '';
                    final evtId = t['evt_id'] as String? ?? '';
                    final evtTitle = t['evt_title'] as String? ?? '';
                    final content = t['content'] as String? ?? '';
                    return Container(
                      margin: const EdgeInsets.fromLTRB(8, 2, 8, 2),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F1F24),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: src == 'Mod'
                                      ? const Color(0xFF3A2A4A)
                                      : const Color(0xFF26364A),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  src,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF9B9BA3),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '$evtId $evtTitle',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF9B9BA3),
                                  ),
                                ),
                              ),
                              if (src == '本体')
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => _extract(evtId),
                                    child: Tooltip(
                                      message: '提取事件到 Mod',
                                      child: Padding(
                                        padding: const EdgeInsets.all(2),
                                        child: Icon(
                                          FluentIcons.arrow_download_24_regular,
                                          size: 13,
                                          color: const Color(0xFF6C5CE7),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            content,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFE4E4E8),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _tabBtn(String key, String label) {
    final selected = _tab == key;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _tab = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2B2B31) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? Colors.white : const Color(0xFF9B9BA3),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: tip,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 14, color: const Color(0xFF8B8B93)),
          ),
        ),
      ),
    );
  }

  Widget _pagerBtn(String label, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF9B9BA3)),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/app_theme.dart';
import '../../core/mobile_widgets.dart';
import 'story_editor_mobile.dart';
import 'story_detail_mobile_page.dart';

/// 移动版事件列表页 - 单栏卡片式浏览
class StoryListMobilePage extends StatefulWidget {
  const StoryListMobilePage({super.key, required this.modName});

  final String modName;

  @override
  State<StoryListMobilePage> createState() => _StoryListMobilePageState();
}

class _StoryListMobilePageState extends State<StoryListMobilePage> {
  final _dataAccess = StoryDataAccess();
  
  List<MobileEvtCfg> _events = [];
  List<MobileEvtCfg> _filteredEvents = [];
  String? _selectedEventId;
  bool _loading = true;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  // 角色字典缓存（用于显示对话人数）
  Map<String, String> _roleNames = {};
  
  // 辅助函数
  Widget __flexibleText(String text) => Flexible(child: Text(text, style: TextStyle(fontSize: 10, color: AppTheme.palette.textHint), maxLines: 1, overflow: TextOverflow.ellipsis));

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _events = [];
    });

    try {
      final events = await _dataAccess.loadEvents(widget.modName);
      
      if (!mounted) return;

      // 加载角色字典（用于显示对话人数）
      try {
        final personResponse = await ApiClient.instance.get('/api/cfg/PersonCfg');
        final personData = personResponse['data'] as Map? ?? {};
        _roleNames = {
          for (var entry in personData.entries)
            entry.key: (entry.value is Map 
                ? (entry.value as Map)['name']?.toString() 
                : entry.value.toString()) ?? '',
        };
      } catch (_) {
        // 忽略错误，不影响主流程
      }

      setState(() {
        _events = events;
        _applyFilter();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      
      if (mounted) {
        fluent.showDialog(
          context: context,
          builder: (ctx) => fluent.ContentDialog(
            title: const Text('加载失败'),
            content: Text(e.toString()),
            actions: [
              fluent.Button(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }
    }
  }

  void _applyFilter() {
    final query = _searchQuery.toLowerCase().trim();
    
    if (query.isEmpty) {
      setState(() => _filteredEvents = _events);
      return;
    }

    setState(() {
      _filteredEvents = _events.where((event) {
        return event.id.toLowerCase().contains(query) ||
            event.title.toLowerCase().contains(query) ||
            event.type.toString().contains(query);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppTheme.palette.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(FluentIcons.arrow_left_24_regular, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Icon(FluentIcons.document_24_regular, size: 16, color: AppTheme.palette.textPrimary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '剧情库 · ${widget.modName}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.palette.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // 搜索按钮
          IconButton(
            icon: const Icon(FluentIcons.search_24_regular, color: Colors.white),
            onPressed: _toggleSearch,
          ),
          // 刷新按钮
          IconButton(
            icon: const Icon(FluentIcons.refresh_24_regular, color: Colors.white),
            onPressed: _loadData,
            tooltip: '刷新',
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框（展开时显示）
          if (_showSearch) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.palette.bgDeep,
                border: Border(bottom: BorderSide(color: AppTheme.palette.border)),
              ),
              child: SafeArea(
                child: MobileTextField(
                  controller: _searchController,
                  hintText: '搜索事件 ID、标题或类型...',
                  onChanged: (value) {
                    setState(() => _searchQuery = value);
                    _applyFilter();
                  },
                  autofocus: true,
                ),
              ),
            ),
          ],
          
          // 事件计数条
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppTheme.palette.panel,
              border: Border(
                bottom: BorderSide(color: AppTheme.palette.border),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  FluentIcons.event_request_24_regular,
                  size: 12,
                  color: AppTheme.palette.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  '${_filteredEvents.length} / ${_events.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.palette.textPrimary,
                  ),
                ),
                const Spacer(),
                // 快速筛选：按事件 ID 前缀聚合数量
                if (_events.isNotEmpty) ...[
                  _flexibleText('查看聚合统计'),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          
          // 事件列表
          Expanded(
            child: _loading
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: fluent.ProgressRing(strokeWidth: 2),
                        ),
                        SizedBox(height: 12),
                        Text(
                          '加载中...',
                          style: TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                  )
                : _events.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        itemCount: _filteredEvents.length,
                        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                        itemBuilder: (context, index) {
                          final event = _filteredEvents[index];
                          return _buildEventCard(event);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventCard(MobileEvtCfg event) {
    // 获取该事件的对白条数
    final prefix = event.id.toLowerCase();
    final talkCount = _dataAccess.cacheTalks.values.where((t) => t.id.toLowerCase().startsWith(prefix)).length;
    
    // 计算派生前缀对白数（使用官方规则）
    final derivedPrefixes = <String>{};
    for (final startId in event.talkId) {
      final s = startId.toString().toLowerCase().trim();
      if (s.length > 3) {
        derivedPrefixes.add(s.substring(0, s.length - 3));
      } else if (s.isNotEmpty) {
        derivedPrefixes.add(s);
      }
    }
    derivedPrefixes.add(prefix); // 事件 ID 本身也是前缀
    
    final talkDerivedCount = _dataAccess.cacheTalks.values.where((t) {
      final tid = t.id.toLowerCase().trim();
      if (tid.length > 3) {
        final prefix = tid.substring(0, tid.length - 3);
        return derivedPrefixes.contains(prefix);
      } else if (tid.isNotEmpty) {
        return derivedPrefixes.contains(tid);
      }
      return false;
    }).length;

    return InkWell(
      onTap: () => _onEventTap(event),
      borderRadius: BorderRadius.circular(12),
      splashColor: AppTheme.palette.hover.withValues(alpha: 0.3),
      highlightColor: AppTheme.palette.hover.withValues(alpha: 0.5),
      child: Container(
        margin: EdgeInsets.only(bottom: 12, left: 12, right: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.palette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: event.id == _selectedEventId ? const Color(0xFF4F6EF7) : AppTheme.palette.border,
            width: event.id == _selectedEventId ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 事件 ID + 操作区
            Row(
              children: [
                Icon(
                  FluentIcons.event_request_24_regular,
                  size: 16,
                  color: AppTheme.palette.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    event.id,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.palette.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            
            // 标题
            if (event.title.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                event.title,
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.palette.textPrimary,
                ),
              ),
            ],
            
            const SizedBox(height: 12),
            
            // 统计徽章
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _badge(
                  '对白条数',
                  talkDerivedCount > 0 ? '$talkDerivedCount' : '-',
                  const Color(0xFF4F6EF7),
                ),
                
                // Option 数量（需要额外 API 调用获取）
                // TODO: 从 _dataAccess 获取当前事件的 Option 数量
                const SizedBox(width: 4),
                _badge(
                  '选项数',
                  '-', // placeholder
                  Colors.grey,
                ),
                
                // 事件类型
                _badge(
                  '类型',
                  _formatEventType(event.type),
                  palette.statusWarn,
                ),
              ],
            ),
            
            // 备注字段（如果存在）
            if (event.note != null && event.note!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.palette.bgDeep2.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  event.note!,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.palette.textMuted,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatEventType(int type) {
    const types = {
      0: '回合开始触发',
      1: '可跳过',
      2: '只能社交触发',
      3: '回合后触发',
      4: '行动触发',
      10: '不可跳过',
      11: '约会',
      12: '篮球任务',
      13: '篮球任务 (不自动)',
      14: '羽毛球任务',
      15: '羽毛球任务 (不自动)',
      20: '关系任务',
      21: '打招呼',
      22: '话题',
      30: '场景物品',
      40: '考试',
      41: '看成绩',
      42: '学习',
      50: '通知',
      51: '流程',
      60: '状态',
      70: '打电话',
      71: '接电话',
      80: '新闻',
      90: '节日',
      101: '独立按钮',
      102: '精力≤20 显示',
      104: '捣蛋事件',
      110: '送礼',
      131: '社团活动',
      200: '人生轨迹',
      500: '高考',
      520: '表白',
      522: '恋爱社交',
      523: '生日礼物',
    };
    return types[type] ?? '类型 $type';
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            FluentIcons.folder_24_regular,
            size: 48,
            color: AppTheme.palette.borderHover,
          ),
          const SizedBox(height: 16),
          Text(
            widget.modName.isEmpty ? '请选择 Mod' : '暂无事件数据',
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.palette.textHint,
            ),
          ),
          if (widget.modName.isNotEmpty) ...[
            const SizedBox(height: 8),
            _flexibleText('点击右上角“刷新”重新加载'),
          ],
        ],
      ),
    );
  }

  Widget _badge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }

  void _toggleSearch() {
    setState(() => _showSearch = !_showSearch);
    if (_showSearch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchController.requestFocus();
      });
    }
  }

  void _onEventTap(MobileEvtCfg event) async {
    await MobileHaptic.mediumImpact();
    
    setState(() => _selectedEventId = event.id);

    // 直接导航到详情页面（不使用路由系统）
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => StoryDetailMobilePage(
          modName: widget.modName,
          eventId: event.id,
        ),
      ),
    );

    // 返回后刷新列表
    if (mounted && _selectedEventId == event.id) {
      setState(() => _selectedEventId = null);
      _loadData();
    }
  }

  bool _showSearch = false;
}

// 辅助函数
Widget _flexibleText(String text) {
  return Flexible(
    child: Text(
      text,
      style: TextStyle(fontSize: 10, color: AppTheme.palette.textHint),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

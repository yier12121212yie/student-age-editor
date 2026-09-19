/// 移动版剧情编辑器核心逻辑与数据模型（移植自 story_director_view.dart）
///
/// 设计原则：
/// - 只读取必要数据（单事件 + 相关对白/选项）
/// - 轻量级缓存层，避免重复 API 调用
/// - 复用 story_logic.dart 的纯函数进行剧情线计算

library;

import '../../core/api_client.dart';

// ============================================================
// 数据模型定义
// ============================================================

/// EvtCfg - 事件配置
class MobileEvtCfg {
  String id;
  String title; // 改为可写
  int type;
  List<dynamic> talkId;

  MobileEvtCfg({
    required this.id,
    this.title = '',
    this.type = 0,
    this.talkId = const [],
  });

  factory MobileEvtCfg.fromJson(Map<String, dynamic> json) {
    return MobileEvtCfg(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '新事件',
      type: json['type'] is int ? json['type'] : int.tryParse(json['type']?.toString() ?? '0') ?? 0,
      talkId: _normalizeList(json['talkId']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'type': type,
      'talkId': talkId.isNotEmpty ? talkId : null,
    };
  }

  static List<dynamic> _normalizeList(dynamic value) {
    if (value == null || value == '') return [];
    if (value is List) return value.map((e) => e.toString()).toList();
    return [value.toString()];
  }
}

/// TalkCfg - 对白配置
class MobileTalkCfg {
  String id;
  List<dynamic> roleIds;
  String roleName;
  dynamic content; // 改为 dynamic 以支持赋值
  List<dynamic> nextTalk;
  List<dynamic> nextTalk2;
  List<MobileOptionCfg> options;

  MobileTalkCfg({
    required this.id,
    this.roleIds = const [],
    this.roleName = '',
    required this.content,
    this.nextTalk = const [],
    this.nextTalk2 = const [],
    this.options = const [],
  });

  factory MobileTalkCfg.fromJson(String id, Map<String, dynamic> json) {
    final rawRoles = json['roleIds'];
    final roles = rawRoles is List 
        ? rawRoles.map((e) => e.toString()).toList()
        : rawRoles != null && rawRoles.toString().isNotEmpty
            ? [rawRoles.toString()]
            : <String>[];

    return MobileTalkCfg(
      id: id,
      roleIds: roles,
      roleName: json['roleName']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      nextTalk: _normalizeList(json['nextTalk']),
      nextTalk2: _normalizeList(json['nextTalk2']),
      options: (json['option'] as List?)?.map((o) {
        if (o is Map) return MobileOptionCfg.fromJson(o);
        return null;
      }).whereType<MobileOptionCfg>().toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': int.parse(id),
      'roleIds': roleIds.isNotEmpty ? roleIds : null,
      'roleName': roleName,
      'content': content,
      'nextTalk': nextTalk.isNotEmpty ? nextTalk : null,
      'nextTalk2': nextTalk2.isNotEmpty ? nextTalk2 : null,
      'option': options.isNotEmpty ? options.map((o) => o.toJson()).toList() : null,
    };
  }

  static List<dynamic> _normalizeList(dynamic value) {
    if (value == null || value == '') return [];
    if (value is List) return value.map((e) => e.toString()).toList();
    return [value.toString()];
  }
}

/// OptionCfg - 选项配置
class MobileOptionCfg {
  final String id;
  String text;
  List<dynamic> talkId;
  List<dynamic> talkId2;

  MobileOptionCfg({
    required this.id,
    this.text = '',
    this.talkId = const [],
    this.talkId2 = const [],
  });

  factory MobileOptionCfg.fromJson(Map<String, dynamic> json) {
    return MobileOptionCfg(
      id: json['id']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      talkId: _normalizeList(json['talkId']),
      talkId2: _normalizeList(json['talkId2']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': int.parse(id),
      'text': text,
      'talkId': talkId.isNotEmpty ? talkId : null,
      'talkId2': talkId2.isNotEmpty ? talkId2 : null,
    };
  }

  static List<dynamic> _normalizeList(dynamic value) {
    if (value == null || value == '') return [];
    if (value is List) return value.map((e) => e.toString()).toList();
    return [value.toString()];
  }
}

// ============================================================
// 数据访问层
// ============================================================

/// 移动版故事数据仓库
class StoryDataAccess {
  final ApiClient _api = ApiClient.instance;

  // 缓存键（按 Mod 隔离）
  String _getCacheKey(String modName) => 'story_v1:$modName';
  
  // 内存缓存
  Map<String, MobileEvtCfg> cacheEvents = {};
  Map<String, MobileTalkCfg> cacheTalks = {};
  Map<String, MobileOptionCfg> cacheOptions = {};
  
  bool _isLoading = false;

  bool get isLoading => _isLoading;

  /// 加载指定 Mod 的全部剧情数据
  /// 返回所有事件的列表（不含 Talk/Option 详情）
  Future<List<MobileEvtCfg>> loadEvents(String modName) async {
    if (_isLoading) return _cacheEvents.values.toList();

    setState(() => _isLoading = true);
    try {
      final response = await _api.get('/api/cfg/EvtCfg');
      final data = response['data'] as Map? ?? {};
      
      final events = data.entries.map((e) {
        final id = e.key;
        final value = e.value is Map ? e.value as Map<String, dynamic> : {'talkId': []};
        return MobileEvtCfg.fromJson(value)..id = id;
      }).toList();

      setState(() {
        _cacheEvents = {for (var evt in events) evt.id: evt};
      });

      return events;
    } catch (e) {
      rethrow;
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// 加载单个事件的完整详情（包含 Talk/Option）
  Future<_StoryEventDetails> loadEventDetails({
    required String modName,
    required String eventId,
  }) async {
    // 先检查缓存
    if (_cacheTalks.isNotEmpty && _cacheTalks.any((k, v) => k.startsWith(eventId))) {
      return _buildEventDetailsFromCache(modName, eventId);
    }

    setState(() => _isLoading = true);
    try {
      // 获取所有 TalkCfg 和 OptionCfg（整个表，但仅过滤当前事件的数据）
      final [talksResponse, optsResponse] = await Future.wait([
        _api.get('/api/cfg/TalkCfg'),
        _api.get('/api/cfg/OptionCfg'),
      ]);

      final talksData = talksResponse['data'] as Map? ?? {};
      final optsData = optsResponse['data'] as Map? ?? {};

      // 筛选属于当前事件的 Talk/Option
      final relatedTalks = <String, MobileTalkCfg>{};
      final prefix = eventId;

      for (final entry in talksData.entries) {
        final id = entry.key;
        final value = entry.value is Map ? entry.value as Map<String, dynamic> : {};
        
        // 判断是否属于该事件（ID 前缀匹配）
        if (id.toLowerCase().startsWith(prefix.toLowerCase())) {
          relatedTalks[id] = MobileTalkCfg.fromJson(id, value);
        }
      }

      final relatedOpts = <String, MobileOptionCfg>{};
      for (final entry in optsData.entries) {
        final id = entry.key;
        final value = entry.value is Map ? entry.value as Map<String, dynamic> : {};
        
        // Option ID 去后 2 位作为前缀
        if (id.length > 2 && id.substring(0, id.length - 2).toLowerCase().startsWith(prefix.toLowerCase())) {
          relatedOpts[id] = MobileOptionCfg.fromJson(value);
        }
      }

      // 构建详情对象
      return _StoryEventDetails(
        event: _cacheEvents[eventId],
        talks: relatedTalks.values.toList(),
        options: relatedOpts.values.toList(),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// 从缓存构建详情对象（当已部分加载过）
  _StoryEventDetails _buildEventDetailsFromCache(String modName, String eventId) {
    final event = _cacheEvents[eventId];
    final prefix = eventId.toLowerCase();
    
    final relatedTalks = _cacheTalks.values
        .where((t) => t.id.toLowerCase().startsWith(prefix))
        .toList();
    
    final relatedOpts = _cacheOptions.values
        .where((o) => o.id.length > 2 && o.id.substring(0, o.id.length - 2).toLowerCase().startsWith(prefix))
        .toList();

    return _StoryEventDetails(
      event: event,
      talks: relatedTalks,
      options: relatedOpts,
    );
  }

  /// 保存单个事件（增量更新 Talk/Option）
  Future<bool> saveEvent({
    required String modName,
    required String eventId,
    required List<MobileTalkCfg> talks,
    required List<MobileOptionCfg> options,
  }) async {
    try {
      final result = await _api.post('/api/story/event/save', body: {
        'mod_name': modName,
        'event_id': eventId,
        'talk_data': talks.map((t) => t.toJson()).toList(),
        'option_data': options.map((o) => o.toJson()).toList(),
      });

      return result['success'] == true || result['ok'] == true;
    } catch (e) {
      rethrow;
    }
  }

  /// 删除事件
  Future<void> deleteEvent(String eventId) async {
    await _api.delete('/api/story/event/$eventId');
  }
}

/// 事件详情数据类
class _StoryEventDetails {
  final MobileEvtCfg? event;
  final List<MobileTalkCfg> talks;
  final List<MobileOptionCfg> options;

  _StoryEventDetails({
    this.event,
    required this.talks,
    required this.options,
  });
}

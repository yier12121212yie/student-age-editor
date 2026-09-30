/// 移动版剧情编辑器核心逻辑与数据模型（移植自 story_director_view.dart）
///
/// 设计原则：
/// - 只读取必要数据（单事件 + 相关对白/选项）
/// - 轻量级缓存层，避免重复 API 调用
/// - 复用 story_logic.dart 的纯函数进行剧情线计算

library;

import '../../core/api_client.dart';
import 'story_logic.dart';

// ============================================================
// 数据模型定义
// ============================================================

/// EvtCfg - 事件配置
class MobileEvtCfg {
  String id;
  String title; // 改为可写
  int type;
  List<dynamic> talkId;
  String? note;

  MobileEvtCfg({
    required this.id,
    this.title = '',
    this.type = 0,
    this.talkId = const [],
    this.note,
  });

  factory MobileEvtCfg.fromJson(Map<String, dynamic> json) {
    return MobileEvtCfg(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '新事件',
      type: json['type'] is int ? json['type'] : int.tryParse(json['type']?.toString() ?? '0') ?? 0,
      talkId: _normalizeList(json['talkId']),
      note: json['note']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'type': type,
      'talkId': talkId.isNotEmpty ? talkId : null,
      if (note != null && note!.isNotEmpty) 'note': note,
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
        if (o is Map) return MobileOptionCfg.fromJson(o.cast<String, dynamic>());
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

/// 移动版故事数据仓库。
///
/// 单例：详情页/列表页各自 new 一个曾让「返回列表再进入」永远冷启动，
/// 缓存跨页面实例才有意义。
class StoryDataAccess {
  StoryDataAccess._();
  static final StoryDataAccess _shared = StoryDataAccess._();
  factory StoryDataAccess() => _shared;

  final ApiClient _api = ApiClient.instance;

  // 内存缓存（key = 行 ID）。cacheTalks/cacheOptions 由
  // loadEventDetails 的 ?prefix= 小批量填充，_loadedEvents 记录哪些
  // 事件的批次已进缓存。
  Map<String, MobileEvtCfg> cacheEvents = {};
  final Map<String, dynamic> _evtRaw = {};
  final Map<String, MobileTalkCfg> cacheTalks = {};
  final Map<String, MobileOptionCfg> cacheOptions = {};
  final Set<String> _loadedEvents = {};

  /// 缓存所属模组：后端按工作区当前模组回表，换模组必须整体作废，
  /// 否则数字 ID 撞段的事件会读到上一个模组的数据。
  String? _cacheMod;

  bool _isLoading = false;

  bool get isLoading => _isLoading;

  void _dropModCaches() {
    cacheEvents.clear();
    _evtRaw.clear();
    cacheTalks.clear();
    cacheOptions.clear();
    _loadedEvents.clear();
  }

  void _ensureModCache(String modName) {
    if (_cacheMod == modName) return;
    _dropModCaches();
    _cacheMod = modName;
  }

  /// 测试隔离用：清空全部内存缓存。
  void debugClearCache() {
    _cacheMod = null;
    _dropModCaches();
  }

  /// 加载指定 Mod 的全部剧情数据
  /// 返回所有事件的列表（不含 Talk/Option 详情）
  Future<List<MobileEvtCfg>> loadEvents(String modName) async {
    _ensureModCache(modName);
    if (_isLoading) return cacheEvents.values.toList();

    _isLoading = true;
    try {
      final response = await _api.get('/api/cfg/EvtCfg');
      final data = response['data'] as Map? ?? {};

      final events = data.entries.map((e) {
        final id = e.key;
        final value = e.value is Map ? e.value as Map<String, dynamic> : {'talkId': []};
        return MobileEvtCfg.fromJson(value)..id = id;
      }).toList();

      cacheEvents = {for (var evt in events) evt.id: evt};
      _evtRaw
        ..clear()
        ..addAll({for (final e in data.entries) e.key.toString(): e.value});

      return events;
    } catch (e) {
      rethrow;
    } finally {
      _isLoading = false;
    }
  }

  /// 加载单个事件的完整详情（包含 Talk/Option）。
  ///
  /// 与剧情图工作台（story_flow_workspace._selectEventInner）同口径：
  /// 只拉该事件相关的两小批（对白 prefix 默认 suffix=3、选项 suffix=2），
  /// 不再每次进入下载 TalkCfg/OptionCfg 全表——万行级大 mod 下这是
  /// 手机端头号卡顿源。
  Future<StoryEventDetails> loadEventDetails({
    required String modName,
    required String eventId,
  }) async {
    // 换模组先作废旧模组缓存，避免同数字 ID 撞段读到上一个模组的数据。
    _ensureModCache(modName);
    // 前缀要从 EvtCfg 的首句 talkId 推导（storyRelatedPrefixes 同源逻辑）；
    // 直达详情（列表页未走过）时先补一次小表 EvtCfg。
    if (!_evtRaw.containsKey(eventId)) {
      await loadEvents(modName);
    }
    final prefixes = storyRelatedPrefixes(eventId, _evtRaw);

    if (!_loadedEvents.contains(eventId)) {
      _isLoading = true;
      try {
        final p = prefixes.join(',');
        final results = await Future.wait([
          _api.get('/api/cfg/TalkCfg', query: {'prefix': p}),
          _api.get('/api/cfg/OptionCfg', query: {'prefix': p, 'suffix': '2'}),
        ]);
        final talksData = (results[0]['data'] as Map?) ?? const {};
        final optsData = (results[1]['data'] as Map?) ?? const {};
        // ?prefix= 返回的本身就只是该事件行；matcher 再过一遍是兜底：
        // MockClient / 旧后端忽略 query 返回全表时行为等价。
        final matcher = PrefixMatcher(prefixes);
        talksData.forEach((k, v) {
          final id = k.toString();
          if (!matcher.match(id)) return;
          cacheTalks[id] = MobileTalkCfg.fromJson(
              id, v is Map ? v.cast<String, dynamic>() : <String, dynamic>{});
        });
        optsData.forEach((k, v) {
          final id = k.toString();
          if (!matcher.match(id, isOption: true)) return;
          cacheOptions[id] = MobileOptionCfg.fromJson(
              v is Map ? v.cast<String, dynamic>() : <String, dynamic>{});
        });
        _loadedEvents.add(eventId);
      } finally {
        _isLoading = false;
      }
    }

    final event = cacheEvents[eventId];
    final matcher = PrefixMatcher(prefixes);
    return StoryEventDetails(
      event: event,
      talks:
          cacheTalks.values.where((t) => matcher.match(t.id)).toList(),
      options: cacheOptions.values
          .where((o) => matcher.match(o.id, isOption: true))
          .toList(),
    );
  }

  /// 丢弃该事件的 Talk/Option 缓存（保存/删除后磁盘与缓存已不一致）。
  void _invalidateEvent(String eventId) {
    _loadedEvents.remove(eventId);
    final matcher = PrefixMatcher(storyRelatedPrefixes(eventId, _evtRaw));
    cacheTalks.removeWhere((k, _) => matcher.match(k));
    cacheOptions.removeWhere((k, _) => matcher.match(k, isOption: true));
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

      final ok = result['success'] == true || result['ok'] == true;
      if (ok) _invalidateEvent(eventId);
      return ok;
    } catch (e) {
      rethrow;
    }
  }

  /// 删除事件
  Future<void> deleteEvent(String eventId) async {
    await _api.delete('/api/story/event/$eventId');
    cacheEvents.remove(eventId);
    _evtRaw.remove(eventId);
    _invalidateEvent(eventId);
  }
}

/// 事件详情数据类
class StoryEventDetails {
  final MobileEvtCfg? event;
  final List<MobileTalkCfg> talks;
  final List<MobileOptionCfg> options;

  StoryEventDetails({
    this.event,
    required this.talks,
    required this.options,
  });
}

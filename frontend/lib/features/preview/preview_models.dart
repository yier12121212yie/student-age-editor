/// 事件场景预览的数据模型（对应后端 /api/preview/event 返回结构）。
library;

/// 预览元信息：id → 名称 / 资源 key 映射。
class PreviewMeta {
  PreviewMeta({
    required this.roles,
    required this.bgs,
    required this.bgKeys,
    required this.charKeys,
  });
  final Map<String, String> roles; // 角色 id → 名称
  final Map<String, String> bgs; // 背景 id → 名称
  final Map<String, String> bgKeys; // 背景 id → tex key
  final Map<String, Map<String, dynamic>> charKeys; // 角色 id → {base, base2}

  factory PreviewMeta.fromJson(Map<String, dynamic> j) => PreviewMeta(
        roles: _strMap(j['roles']),
        bgs: _strMap(j['bgs']),
        bgKeys: _strMap(j['bgKeys']),
        charKeys: _mapMap(j['charKeys']),
      );

  String roleName(String? id) {
    if (id == null) return '';
    return roles[id] ?? id;
  }
}

Map<String, String> _strMap(dynamic v) {
  if (v is! Map) return {};
  return v.map((k, val) => MapEntry(k.toString(), val.toString()));
}

Map<String, Map<String, dynamic>> _mapMap(dynamic v) {
  if (v is! Map) return {};
  return v.map((k, val) => MapEntry(
      k.toString(), val is Map ? val.cast<String, dynamic>() : <String, dynamic>{}));
}

/// 背景快照。
class PreviewBg {
  PreviewBg({required this.id, required this.name, required this.key});
  final String id;
  final String name;
  final String key; // tex key（已去掉 bg/ 前缀）

  factory PreviewBg.fromJson(Map<String, dynamic> j) => PreviewBg(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        key: (j['key'] ?? '').toString(),
      );
}

/// 舞台上的一个立绘角色。
class PreviewChar {
  PreviewChar({
    required this.roleId,
    required this.tex,
    required this.pos,
    required this.expr,
    required this.flip,
  });
  final String roleId;
  final String tex; // 立绘 tex key（含表情变体）
  final String pos; // left | center | right
  final int expr;
  final bool flip;

  factory PreviewChar.fromJson(Map<String, dynamic> j) => PreviewChar(
        roleId: (j['roleId'] ?? '').toString(),
        tex: (j['tex'] ?? '').toString(),
        pos: (j['pos'] ?? 'center').toString(),
        expr: (j['expr'] as num?)?.toInt() ?? 0,
        flip: j['flip'] == true,
      );
}

/// 舞台快照（某条对白时刻的画面状态）。
class PreviewStage {
  PreviewStage({this.bg, required this.chars});
  final PreviewBg? bg; // null 表示沿用上一背景
  final List<PreviewChar> chars;

  factory PreviewStage.fromJson(Map<String, dynamic>? j) {
    if (j == null) return PreviewStage(bg: null, chars: const []);
    final rawBg = j['bg'];
    return PreviewStage(
      bg: rawBg is Map ? PreviewBg.fromJson(rawBg.cast<String, dynamic>()) : null,
      chars: [
        for (final c in (j['chars'] as List? ?? []))
          if (c is Map) PreviewChar.fromJson(c.cast<String, dynamic>()),
      ],
    );
  }
}

/// 单条对白（TalkCfg 条目 + 舞台快照）。
class PreviewTalk {
  PreviewTalk({
    required this.id,
    required this.content,
    required this.roleIds,
    required this.roleName,
    required this.options,
    required this.nextTalk,
    required this.nextTalk2,
    required this.check,
    required this.stage,
  });
  final String id;
  final String content;
  final List<String> roleIds;
  final String roleName;
  final List<String> options; // OptionCfg id 列表
  final List<String> nextTalk;
  final List<String> nextTalk2;
  final List<List<dynamic>> check;
  final PreviewStage stage;

  bool get isNarrator {
    if (roleName.isNotEmpty) return false;
    final ids = roleIds;
    return ids.isEmpty || (ids.length == 1 && ids.first == '-1');
  }

  /// 说话人显示名：roleName 优先；旁白（-1 / 空）显示「旁白」。
  String speakerLabel(PreviewEventData data) {
    if (roleName.isNotEmpty) return roleName;
    if (isNarrator) return '旁白';
    return roleIds.map((r) => data.meta.roleName(r)).join('、');
  }

  factory PreviewTalk.fromJson(Map<String, dynamic> j) => PreviewTalk(
        id: (j['id'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        roleIds: _strList(j['roleIds']),
        roleName: (j['roleName'] ?? '').toString(),
        options: _strList(j['option']),
        nextTalk: _strList(j['nextTalk']),
        nextTalk2: _strList(j['nextTalk2']),
        check: [
          for (final c in (j['check'] as List? ?? []))
            if (c is List) c.cast<dynamic>(),
        ],
        stage: PreviewStage.fromJson((j['stage'] as Map?)?.cast<String, dynamic>()),
      );
}

/// 选项（OptionCfg 条目）。
class PreviewOption {
  PreviewOption({required this.id, required this.content, required this.talkId});
  final String id;
  final String content;
  final List<String> talkId;

  factory PreviewOption.fromJson(Map<String, dynamic> j) => PreviewOption(
        id: (j['id'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        talkId: _strList(j['talkId']),
      );
}

/// 完整事件预览数据。
class PreviewEventData {
  PreviewEventData({
    required this.evtId,
    required this.title,
    required this.event,
    required this.starts,
    required this.talks,
    required this.options,
    required this.meta,
  });
  final String evtId;
  final String title;
  final Map<String, dynamic> event;
  final List<String> starts;
  final Map<String, PreviewTalk> talks;
  final Map<String, PreviewOption> options;
  final PreviewMeta meta;

  int get talkCount => talks.length;

  /// 当前对白在全部对白中的顺序索引（按加载顺序，用于进度显示）。
  int linearIndex(String? talkId) {
    if (talkId == null) return -1;
    var i = 0;
    for (final id in talks.keys) {
      if (id == talkId) return i;
      i++;
    }
    return -1;
  }

  factory PreviewEventData.fromJson(Map<String, dynamic> j) {
    final talks = <String, PreviewTalk>{};
    for (final e in (j['talks'] as Map? ?? {}).entries) {
      if (e.value is Map) {
        talks[e.key.toString()] =
            PreviewTalk.fromJson((e.value as Map).cast<String, dynamic>());
      }
    }
    final options = <String, PreviewOption>{};
    for (final e in (j['options'] as Map? ?? {}).entries) {
      if (e.value is Map) {
        options[e.key.toString()] =
            PreviewOption.fromJson((e.value as Map).cast<String, dynamic>());
      }
    }
    return PreviewEventData(
      evtId: (j['evt_id'] ?? '').toString(),
      title: (j['event_title'] ?? '事件预览').toString(),
      event: (j['event'] as Map?)?.cast<String, dynamic>() ?? {},
      starts: _strList(j['starts']),
      talks: talks,
      options: options,
      meta: PreviewMeta.fromJson((j['meta'] as Map?)?.cast<String, dynamic>() ?? {}),
    );
  }
}

List<String> _strList(dynamic v) {
  if (v is! List) return [];
  return [for (final x in v) x.toString()];
}

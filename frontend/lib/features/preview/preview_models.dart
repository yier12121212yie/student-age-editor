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

/// 音频条目（/api/preview/event 顶层新增的 audios 映射：id → {url,name,type}）。
///
/// [type]：1 = 背景音乐（循环播放），2 = 一次性音效；未知值按音效处理。
/// [url] 既是 AA 索引 key，也是 mod 相对路径候选（取字节两路先例见
/// [PreviewAudioController.loadBytes]）。
class PreviewAudio {
  PreviewAudio({required this.url, required this.name, required this.type});
  final String url;
  final String name;
  final int type;

  bool get isBgm => type == 1;

  factory PreviewAudio.fromJson(Map<String, dynamic> j) => PreviewAudio(
        url: (j['url'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        type: (j['type'] as num?)?.toInt() ?? 2,
      );
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

/// 屏幕效果指令（/api/preview/event 顶层 screen_effects 映射：talkId → {code,args}|null）。
///
/// 后端已按 BFS 把每条 talk 的 screenEffect 归一成「第 1 组码 + 参数数组」，
/// 例如 `{"code": 4015, "args": [900]}`；无效果的 talk 值为 null。
class PreviewScreenEffect {
  PreviewScreenEffect({required this.code, required this.args});
  final int code;
  final List<dynamic> args;

  factory PreviewScreenEffect.fromJson(Map<String, dynamic> j) =>
      PreviewScreenEffect(
        code: _asInt(j['code']),
        args: [for (final a in (j['args'] as List? ?? const [])) a],
      );
}

/// 舞台快照（某条对白时刻的画面状态）。
class PreviewStage {
  PreviewStage(
      {this.bg, required this.chars, this.bgmId, this.hasBgm = false});
  final PreviewBg? bg; // null 表示沿用上一背景
  final List<PreviewChar> chars;

  /// 该句的「最终态 BGM id」（后端 BFS 增量算出：type=1 切、-1 清、type=2 不改）。
  final String? bgmId;

  /// stage 里是否带 `bgm` 键（新契约恒带；旧数据无此键时前端回落 talk.audio）。
  final bool hasBgm;

  factory PreviewStage.fromJson(Map<String, dynamic>? j) {
    if (j == null) return PreviewStage(bg: null, chars: const []);
    final rawBg = j['bg'];
    final hasBgm = j.containsKey('bgm');
    return PreviewStage(
      bg: rawBg is Map ? PreviewBg.fromJson(rawBg.cast<String, dynamic>()) : null,
      chars: [
        for (final c in (j['chars'] as List? ?? []))
          if (c is Map) PreviewChar.fromJson(c.cast<String, dynamic>()),
      ],
      hasBgm: hasBgm,
      bgmId: hasBgm ? _bgmIdOf(j['bgm']) : null,
    );
  }

  static String? _bgmIdOf(dynamic v) {
    if (v is num) return v.toString();
    if (v is String && v.isNotEmpty) return v;
    return null;
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
    required this.audio,
    required this.vocalsId,
    required this.screenEffect,
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

  /// 音频指令（TalkCfg.audio 原值）：-1 = 停 BGM；0/缺失 = 不变；
  /// >0 = audios 映射中的 id（BGM 或音效按 [PreviewAudio.type] 区分）。
  final int audio;

  /// 人声（TalkCfg.vocals 首元素声 ID，遗留 [id, 音量] 扁平对）；0 = 无人声。
  final int vocalsId;

  /// 屏幕效果指令（TalkCfg.screenEffect 原值：1D 扁平如 [4015, CGid]，
  /// 亦兼容 2D 行列表）。语义解析见 stage_effects.dart。
  final List<dynamic> screenEffect;

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
        audio: _asInt(j['audio']),
        vocalsId: _firstNum(j['vocals']),
        screenEffect: [
          for (final x in (j['screenEffect'] as List? ?? const [])) x,
        ],
      );
}

/// num 宽容取值（含负数与字符串数字）；null/异常 → 0。
int _asInt(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// vocals 可能是 [声ID, 音量] 扁平对 / 数字 / null：取首个数作声 ID。
int _firstNum(dynamic v) {
  if (v is num) return v.toInt();
  if (v is List && v.isNotEmpty) return _asInt(v.first);
  return 0;
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
    this.audios = const {},
    this.bgmId = 0,
    this.screenEffects = const {},
  });
  final String evtId;
  final String title;
  final Map<String, dynamic> event;
  final List<String> starts;
  final Map<String, PreviewTalk> talks;
  final Map<String, PreviewOption> options;
  final PreviewMeta meta;

  /// 顶层新增：音频 id → 条目（TalkCfg.audio / vocals 指令引用的资源表）。
  final Map<String, PreviewAudio> audios;

  /// 初始/环境 BGM（顶层 stage.bgm，0 = 无）；无 stage.bgm 的旧数据兜底用。
  final int bgmId;

  /// 顶层新增：talkId → 该句屏幕效果（后端归一的 {code,args} 或 null）。
  /// 用 `containsKey` 区分「显式无效果(null)」与「旧数据缺字段(回退 talk.screenEffect)」。
  final Map<String, PreviewScreenEffect?> screenEffects;

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
    final audios = <String, PreviewAudio>{};
    for (final e in (j['audios'] as Map? ?? {}).entries) {
      if (e.value is Map) {
        audios[e.key.toString()] =
            PreviewAudio.fromJson((e.value as Map).cast<String, dynamic>());
      }
    }
    // screen_effects：talkId → {code,args}| null（保留 null 值以区分「显式无效果」）。
    final screenEffects = <String, PreviewScreenEffect?>{};
    final seRaw = j['screen_effects'];
    if (seRaw is Map) {
      for (final e in seRaw.entries) {
        final v = e.value;
        screenEffects[e.key.toString()] = v is Map
            ? PreviewScreenEffect.fromJson(v.cast<String, dynamic>())
            : null;
      }
    }
    // 初始 BGM：顶层 stage.bgm（数值或字符串 id）。
    final stageRaw = j['stage'];
    final bgmId = _asInt(
        j['bgm'] ?? (stageRaw is Map ? stageRaw['bgm'] : null));
    return PreviewEventData(
      evtId: (j['evt_id'] ?? '').toString(),
      title: (j['event_title'] ?? '事件预览').toString(),
      event: (j['event'] as Map?)?.cast<String, dynamic>() ?? {},
      starts: _strList(j['starts']),
      talks: talks,
      options: options,
      meta: PreviewMeta.fromJson((j['meta'] as Map?)?.cast<String, dynamic>() ?? {}),
      audios: audios,
      bgmId: bgmId,
      screenEffects: screenEffects,
    );
  }
}

List<String> _strList(dynamic v) {
  if (v is! List) return [];
  return [for (final x in v) x.toString()];
}

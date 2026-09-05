import '../../core/models.dart';

/// 英文 key → 中文翻译（等价于 Python 端 editor/utils.py 的 translate_key）。
class KeyTranslator {
  KeyTranslator(this.state);
  final AppState state;

  static const _commonWords = <String, String>{
    'id': 'ID', 'type': '类型', 'name': '名称', 'desc': '描述', 'content': '内容/文本',
    'rate': '概率', 'max': '最大', 'min': '最小', 'count': '数量', 'time': '时间',
    'cost': '消耗', 'effect': '效果', 'condition': '条件', 'precondition': '前提',
    'talk': '对话', 'option': '选项', 'reward': '奖励', 'price': '价格', 'sell': '售价',
    'value': '数值/价值', 'icon': '图标/立绘', 'bg': '背景', 'bgm': '音乐', 'sound': '音效',
    'scene': '场景', 'map': '地点', 'role': '角色', 'npc': 'NPC', 'item': '物品',
    'action': '动作', 'state': '状态', 'level': '等级', 'exp': '经验', 'skill': '技能',
    'buff': 'Buff', 'is': '是否', 'has': '拥有', 'can': '可', 'unlock': '解锁',
    'weight': '权重', 'probability': '几率', 'replace': '替换', 'display': '表现',
    'pressure': '压力', 'grow': '成长', 'attr': '属性', 'focus': '关注', 'trait': '特质',
    'speciality': '特长', 'gender': '性别', 'birthday': '生日', 'intro': '简介', 'introduction': '简介',
    'init': '初始', 'url': '路径', 'pic': '图片', 'image': '图像', 'music': '音乐',
    'next': '下一', 'num': '序号', 'cnt': '次数', 'group': '组别', 'duration': '持续时间',
    'mini': '迷你', 'game': '游戏', 'check': '检查', 'branch': '分支', 'fail': '失败',
    'success': '成功', 'start': '开始', 'end': '结束', 'target': '目标', 'source': '来源',
    'trigger': '触发', 'auto': '自动', 'manual': '手动', 'default': '默认', 'custom': '自定义',
  };

  String translate(String enKey, [String? cfgName]) {
    final maps = state.keyMaps;
    if (cfgName != null && maps[cfgName] is Map) {
      final m = (maps[cfgName] as Map).cast<String, dynamic>();
      final v = m[enKey];
      if (v is String && v.isNotEmpty) return v;
    }
    // camelCase 拆分
    final words = enKey
        .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    final cn = words.map((w) => _commonWords[w.toLowerCase()] ?? w).join();
    return cn == enKey ? enKey : cn;
  }

  /// 条目的显示名：优先 name/title/content/desc 字段。
  String entryName(String id, Map<String, dynamic> record) {
    for (final key in ['name', 'title', 'content', 'desc', 'text']) {
      final v = record[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is List && v.isNotEmpty) {
        final first = v.first;
        if (first is String && first.isNotEmpty) return first;
      }
    }
    return '#$id';
  }
}

/// JSON 值 <-> 展示文本。
/// 编码规则：1D 用逗号分隔；2D 行间用分号、行内用逗号（如 `1,2; 3,4`）。
class ValueCodec {
  static String encode(dynamic v) {
    if (v == null) return '';
    if (v is List) {
      final is2d = v.isNotEmpty && v.first is List;
      if (is2d) {
        return v
            .map((row) => (row as List).map((e) => _fmt(e)).join(', '))
            .join('; ');
      }
      return v.map(_fmt).join(', ');
    }
    return _fmt(v);
  }

  static String _fmt(dynamic v) {
    if (v == null) return '';
    return v.toString();
  }

  static dynamic decode(String text, String fieldType) {
    final t = text.trim();
    if (t.isEmpty) {
      if (fieldType == 'String') return '';
      if (fieldType == 'Number') return 0;
      return <dynamic>[];
    }
    if (fieldType == 'Number') {
      final n = num.tryParse(t.replaceAll(',', '').replaceAll('，', ''));
      return n ?? 0;
    }
    if (fieldType == 'String') return t;
    if (fieldType == '1D Array') {
      return _split1d(t).map(_toNum).toList();
    }
    if (fieldType == '2D Array') {
      // 分行：分号 / 换行；行内：逗号
      return _splitRows(t)
          .map((row) => _splitRow(row).map(_toNum).toList())
          .toList();
    }
    return t;
  }

  /// 现文本与值是否已语义等价（等价则不必回写，保护半截输入与光标）。
  /// decode 失败按"需要回写"处理。
  ///
  /// 用途：didUpdateWidget 回写文本前先判断。数组输入的中间态如 "1,"
  /// 已被 onChanged 解析成 [1]，语义上与现文本等价，回写会把文本
  /// 规范化成 "1" 并把光标弹到末尾，破坏连续输入。
  /// 注意空文本语义：decode('') 按 fieldType 得 ''/0/[]，
  /// 所以 "" vs [5] 不等价（返回 true，需要回写），而 "1," vs [1] 等价（返回 false）。
  static bool needsResync(String text, dynamic value, String fieldType) {
    dynamic decoded;
    try {
      decoded = decode(text, fieldType);
    } catch (_) {
      return true; // 解析异常：按需要回写处理
    }
    return !_deepEq(decoded, value);
  }

  /// 深比较：List/Map 逐元素；数值允许 int/double 相等（1 == 1.0）。
  static bool _deepEq(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is num && b is num) return a == b;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEq(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }

  static List<String> _splitRows(String s) => s
      .split(RegExp(r'[;\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  static List<String> _split1d(String s) => s
      .split(RegExp(r'[;，、,\n]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  static List<String> _splitRow(String s) => s
      .split(RegExp(r'[,，、]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  static dynamic _toNum(String s) {
    final n = num.tryParse(s);
    return n ?? s;
  }
}

/// 顶层便捷入口：与 [ValueCodec.needsResync] 完全等价（语义见该方法文档）。
bool valueCodecNeedsResync(String text, dynamic value, String type) =>
    ValueCodec.needsResync(text, value, type);

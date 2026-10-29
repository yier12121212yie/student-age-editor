/// 立绘候选链解析（表情变体优先、基础立绘兜底）。
///
/// 剧情工作台（StoryStudioEditor）与经典导演视图（StoryDirectorView）共用本
/// 函数，保证两处立绘解析口径完全一致。
///
/// 关键不变量：**任何表情变体候选都必须排在基础立绘之前**。历史 bug 把基础
/// 立绘和表情差分塞进同一组，当用户选择表情 N 时基础立绘会「抢跑」命中，
/// 真正的差分贴图（官方 `charKeys.faces[N]` 等）被永久遮蔽，表情看起来完全
/// 不变；本函数用「阶段 1 变体 → 阶段 2 基础」两段式彻底解耦。
library;

import '../resources/local_import.dart' show texKeyOfImportedPath;
import 'story_logic.dart' show cln;

/// 取列表首项或标量的字符串形式（PersonCfg/charKeys 的 url 字段既可能是
/// 字符串也可能是数组）。
String portraitFirstStr(dynamic v) {
  final raw = (v is List && v.isNotEmpty) ? cln(v.first) : cln(v);
  if (raw == '[]' || raw == 'null' || raw == 'None' || raw == '{}') return '';
  return raw;
}

/// 人物 ID + 表情编号 → 候选立绘 key 列表（变体优先，优雅回退到基础立绘）。
///
/// 分两阶段解析，杜绝基础立绘截断表情变体：
///   阶段 1（仅 [expr] > 0）：表情变体候选
///     1. [faceCfg] 中 pid 对应、`fid % 100 == expr` 的 ModFaceCfg 自定义表情图；
///     2. [catalogPortrait1] / [catalogPortrait2]（角色目录）的 `${p}_$expr`；
///     3. [personUrl1] / [personUrl2]（工作区 PersonCfg）的 `${u}_$expr`；
///     4. [charKeys] 的 `faces[expr]` 与 `${base}_$expr` / `${base2}_$expr`。
///   阶段 2：基础立绘兜底
///     1. [faceCfg] 中 pid 的 0 号默认脸（自定义角色绝不穿透回原版）；
///     2. [catalogPortrait1] / [catalogPortrait2]；
///     3. [personUrl1] / [personUrl2]；
///     4. [charKeys] 的 `base` / `base2`。
///
/// 同一阶段内工作区自定义素材始终优先于随包官方素材。中学阶段
/// （[stageIndex] == 1）与小学阶段（0）的 `url2`/`url` 主次顺序相反，与
/// 「人物资源库」的展示口径一致。
List<String> portraitKeyCandidates({
  required String roleId,
  int expr = 0,
  int stageIndex = 0,
  Map<String, dynamic> faceCfg = const {},
  String catalogPortrait1 = '',
  String catalogPortrait2 = '',
  String personUrl1 = '',
  String personUrl2 = '',
  Map<String, dynamic>? charKeys,
}) {
  final id = cln(roleId);
  if (id.isEmpty) return const [];
  final candidates = <String>[];

  void addCandidate(dynamic v) {
    final s = portraitFirstStr(v);
    if (s.isEmpty || candidates.contains(s)) return;
    candidates.add(s);
    // 导入素材的字段值可能是 `Textures/x.png`，同时登记去扩展名的 tex key。
    final stripped = texKeyOfImportedPath(s);
    if (stripped.isNotEmpty && !candidates.contains(stripped)) {
      candidates.add(stripped);
    }
  }

  // 中学（stageIndex == 1）url2/base2 优先；小学（0）url/base 优先。
  final middleFirst = stageIndex == 1;
  final p1 = portraitFirstStr(catalogPortrait1);
  final p2 = portraitFirstStr(catalogPortrait2);
  final u1 = portraitFirstStr(personUrl1);
  final u2 = portraitFirstStr(personUrl2);
  final base = charKeys == null ? '' : portraitFirstStr(charKeys['base']);
  final base2 = charKeys == null ? '' : portraitFirstStr(charKeys['base2']);
  final pid = int.tryParse(id);

  // 单个来源在两个阶段里的注入次序：变体阶段写 `${key}_$expr`，基础阶段写 key。
  void addVariantPair(String k) {
    if (k.isEmpty) return;
    final dot = k.lastIndexOf('.');
    final slash = k.lastIndexOf(RegExp(r'[/\\]'));
    if (dot > slash && dot > 0) {
      final stem = k.substring(0, dot);
      final ext = k.substring(dot);
      addCandidate('${stem}_$expr$ext');
      addCandidate('${stem}_$expr');
    } else {
      addCandidate('${k}_$expr');
    }
  }

  // ---------------- 阶段 1：表情变体（仅 expr > 0） ----------------
  if (expr > 0) {
    // 1. ModFaceCfg 自定义表情差分（id = pid*1000 + cloth*100 + expr，此处 cloth=0）。
    if (pid != null) {
      for (final e in faceCfg.values) {
        if (e is! Map) continue;
        final fid = (e['id'] as num?)?.toInt() ?? -1;
        if (fid ~/ 1000 != pid || fid % 100 != expr) continue;
        final primary = middleFirst ? 'icon' : 'icon_xx';
        final alt = middleFirst ? 'icon_xx' : 'icon';
        addCandidate(e[primary]);
        addCandidate(e[alt]);
        break;
      }
    }
    // 2. 角色目录差分。
    if (middleFirst) {
      addVariantPair(p2);
      addVariantPair(p1);
    } else {
      addVariantPair(p1);
      addVariantPair(p2);
    }
    // 3. 工作区 PersonCfg 差分。
    if (middleFirst) {
      addVariantPair(u2);
      addVariantPair(u1);
    } else {
      addVariantPair(u1);
      addVariantPair(u2);
    }
    // 4. 合并元数据 faces[expr] 与 base 差分。
    final faces = charKeys?['faces'];
    if (faces is Map) {
      final f = faces[expr.toString()];
      if (f is Map) {
        final primary = middleFirst ? 'icon' : 'icon_xx';
        final alt = middleFirst ? 'icon_xx' : 'icon';
        addCandidate(f[primary]);
        addCandidate(f[alt]);
      }
    }
    if (middleFirst) {
      addVariantPair(base2);
      addVariantPair(base);
    } else {
      addVariantPair(base);
      addVariantPair(base2);
    }
  }

  // ---------------- 阶段 2：基础立绘兜底 ----------------
  // 1. ModFaceCfg 0 号默认脸：有自定义表情配置的角色不穿透回原版。
  if (pid != null) {
    for (final e in faceCfg.values) {
      if (e is! Map) continue;
      final fid = (e['id'] as num?)?.toInt() ?? -1;
      if (fid ~/ 1000 != pid || fid % 100 != 0) continue;
      final primary = middleFirst ? 'icon' : 'icon_xx';
      final alt = middleFirst ? 'icon_xx' : 'icon';
      addCandidate(e[primary]);
      addCandidate(e[alt]);
      break;
    }
  }
  // 2. 角色目录基础立绘。
  if (middleFirst) {
    if (p2.isNotEmpty) addCandidate(p2);
    if (p1.isNotEmpty) addCandidate(p1);
  } else {
    if (p1.isNotEmpty) addCandidate(p1);
    if (p2.isNotEmpty) addCandidate(p2);
  }
  // 3. 工作区 PersonCfg 基础立绘。
  if (middleFirst) {
    if (u2.isNotEmpty) addCandidate(u2);
    if (u1.isNotEmpty) addCandidate(u1);
  } else {
    if (u1.isNotEmpty) addCandidate(u1);
    if (u2.isNotEmpty) addCandidate(u2);
  }
  // 4. 合并元数据基础立绘。
  if (middleFirst) {
    if (base2.isNotEmpty) addCandidate(base2);
    if (base.isNotEmpty) addCandidate(base);
  } else {
    if (base.isNotEmpty) addCandidate(base);
    if (base2.isNotEmpty) addCandidate(base2);
  }

  return candidates;
}

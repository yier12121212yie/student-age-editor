import '../../core/api_client.dart';

/// AI 面板自定义技能（提示词模板）：`.editor_skills/` 目录下的一个 md 文件，
/// 在输入框以 `/` 前缀唤起选择，选中后正文填入输入框。
///
/// 文件支持可选 frontmatter：
/// ```md
/// ---
/// name: 剧情扩写
/// description: 按指定风格扩写事件剧情
/// ---
/// 正文提示词…
/// ```
class AiSkill {
  const AiSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.body,
    required this.fromMod,
  });

  /// 稳定 id：scope + 文件名（同名时 mod 与 workspace 条目仍可区分）。
  final String id;

  /// 显示名：frontmatter `name:`，缺省为文件名去扩展名。
  final String name;

  /// 描述：frontmatter `description:`，缺省为正文首行截 60 字。
  final String description;

  /// 提示词正文（已去掉 frontmatter）。
  final String body;

  /// true = 来自当前模组（scope=mod），false = 来自工作区全局（scope=workspace）。
  final bool fromMod;
}

/// 技能存储：扫描两个 scope 的 [.editor_skills] 目录并解析 md 文件。
///
/// 容错策略：任何网络/解析失败静默跳过该文件（目录不存在 = 没有技能，
/// 不弹错、不抛出）；带 30s 内存缓存，编辑技能文件后可 [invalidate] 强制刷新。
class AiSkillStore {
  /// 技能目录名（mod 与工作区根下各可有一份）。
  static const dirName = '.editor_skills';

  /// 内存缓存有效期。
  static const Duration cacheTtl = Duration(seconds: 30);

  List<AiSkill>? _cache;
  DateTime? _cachedAt;

  /// 加载全部技能：先扫 workspace（全局），再扫 mod（[includeMod] 为 false 时
  /// 跳过）；mod 级与全局同名时 mod 覆盖全局。结果按名称排序。
  Future<List<AiSkill>> load({bool includeMod = true}) async {
    final now = DateTime.now();
    final cached = _cache;
    final at = _cachedAt;
    if (cached != null && at != null && now.difference(at) < cacheTtl) {
      return cached;
    }
    final byName = <String, AiSkill>{};
    await _scanScope(byName, scope: 'workspace', fromMod: false);
    if (includeMod) await _scanScope(byName, scope: 'mod', fromMod: true);
    final list = byName.values.toList()
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    _cache = list;
    _cachedAt = now;
    return list;
  }

  /// 丢弃缓存：下次 [load] 重新扫描。
  void invalidate() {
    _cache = null;
    _cachedAt = null;
  }

  /// 扫描一个 scope 的技能目录，失败静默跳过。
  Future<void> _scanScope(
    Map<String, AiSkill> out, {
    required String scope,
    required bool fromMod,
  }) async {
    dynamic listing;
    try {
      listing = await ApiClient.instance.get(
        '/api/tools/list',
        query: {'scope': scope, 'path': dirName, 'deep': '0'},
      );
    } catch (_) {
      return; // 目录不存在/后端未就绪：视为无技能
    }
    final entries = listing is Map ? listing['entries'] : null;
    if (entries is! List) return;
    for (final e in entries) {
      if (e is! Map) continue;
      final fileName = e['name']?.toString() ?? '';
      if (e['type']?.toString() != 'file') continue;
      if (!fileName.toLowerCase().endsWith('.md')) continue;
      try {
        final doc = await ApiClient.instance.get(
          '/api/tools/read',
          query: {'scope': scope, 'path': '$dirName/$fileName'},
        );
        // 非文本文件后端返回 text=null
        final text = doc is Map ? doc['text'] : null;
        if (text is! String) continue;
        final skill = parseFile(fileName, text, fromMod: fromMod);
        if (skill != null) out[skill.name.toLowerCase()] = skill;
      } catch (_) {
        continue; // 单文件读取/解析失败：跳过
      }
    }
  }

  /// 解析一个技能文件（纯函数，便于测试）。
  ///
  /// frontmatter 容错：仅识别 `---` 围栏内的 `name:`/`description:` 两键，
  /// 围栏未闭合或键缺失均回退——name=文件名去扩展名、
  /// description=正文首行截 60 字。正文为空时返回 null。
  static AiSkill? parseFile(
    String fileName,
    String content, {
    required bool fromMod,
  }) {
    final lower = fileName.toLowerCase();
    final stem = (lower.endsWith('.md')
            ? fileName.substring(0, fileName.length - 3)
            : fileName)
        .trim();
    final text = content.replaceAll('\r\n', '\n');
    final lines = text.split('\n');

    var name = stem;
    var description = '';
    var body = text;

    // 找闭合的 frontmatter 围栏（首行 `---`，其后最近一行 `---`）
    int? fenceEnd;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      for (var i = 1; i < lines.length; i++) {
        if (lines[i].trim() == '---') {
          fenceEnd = i;
          break;
        }
      }
    }
    if (fenceEnd != null) {
      final keyRe = RegExp(r'^\s*(name|description)\s*:\s*(.*)$');
      for (var i = 1; i < fenceEnd; i++) {
        final m = keyRe.firstMatch(lines[i]);
        if (m == null) continue;
        final v = _unquote(m.group(2)!.trim());
        if (v.isEmpty) continue;
        if (m.group(1) == 'name') {
          name = v;
        } else {
          description = v;
        }
      }
      body = lines.sublist(fenceEnd + 1).join('\n');
    }
    body = body.trim();
    if (body.isEmpty || name.isEmpty) return null;
    if (description.isEmpty) {
      // 回退：正文首个非空行截 60 字
      final firstLine = body
          .split('\n')
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
          .trim();
      description = firstLine.length > 60 ? firstLine.substring(0, 60) : firstLine;
    }
    return AiSkill(
      id: '${fromMod ? 'mod' : 'workspace'}/$fileName',
      name: name,
      description: description,
      body: body,
      fromMod: fromMod,
    );
  }

  /// `/` 命令联想过滤：按 name/description 包含匹配，大小写不敏感；
  /// [q] 为 `/` 之后的文本，空串返回全部。
  static List<AiSkill> filterQuery(List<AiSkill> all, String q) {
    final query = q.trim().toLowerCase();
    if (query.isEmpty) return List.of(all);
    return [
      for (final s in all)
        if (s.name.toLowerCase().contains(query) ||
            s.description.toLowerCase().contains(query))
          s,
    ];
  }

  /// 去掉 frontmatter 值的成对引号。
  static String _unquote(String v) {
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      return v.substring(1, v.length - 1).trim();
    }
    return v;
  }
}

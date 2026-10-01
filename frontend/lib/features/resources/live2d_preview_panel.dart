import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// Live2D 模型面板：模型库 + 表达式渲染预览。
///
/// 后端契约（native，见并行实现）：
///   * GET  /api/live2d/models  -> {models:[{path,name,expressions:[...]}]}
///   * POST /api/live2d/render  {path, expression} -> {ok,mime:'image/png',data:base64}
///
/// 渲染结果按 `path|expression` 内存缓存，重复点击零请求。旧的
/// `/plugin/live2d/models`（已退役的 Python 插件服务，后端无该路由）与
/// 「动画」假计时器一并移除——渲染是静态 PNG，无需本地帧循环。
class Live2DPreviewPanel extends StatefulWidget {
  const Live2DPreviewPanel({super.key});

  @override
  State<Live2DPreviewPanel> createState() => _Live2DPreviewPanelState();
}

class _Live2DPreviewPanelState extends State<Live2DPreviewPanel> {
  bool _isLoadingModels = true;
  String? _modelsError;
  List<Map<String, dynamic>> _models = const [];

  Map<String, dynamic>? _selected;
  String? _curExpr;

  /// `path|expression` → PNG 字节。会话级内存缓存。
  final Map<String, Uint8List> _renderCache = {};
  Uint8List? _renderBytes;
  bool _rendering = false;
  String? _renderError;

  /// 渲染序号：慢响应回来时若已切模型/表达式，直接丢弃（防串图）。
  int _renderSeq = 0;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  // ---------------- 模型列表 ----------------

  Future<void> _loadModels() async {
    setState(() {
      _isLoadingModels = true;
      _modelsError = null;
    });
    try {
      final res = await ApiClient.instance.get('/api/live2d/models');
      final list = (res is Map ? res['models'] : null);
      final models = <Map<String, dynamic>>[
        if (list is List)
          for (final m in list)
            if (m is Map) m.cast<String, dynamic>(),
      ];
      if (!mounted) return;
      setState(() {
        _models = models;
        _isLoadingModels = false;
      });
      if (models.isNotEmpty) {
        await _selectModel(models.first);
      } else {
        setState(() {
          _selected = null;
          _renderBytes = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingModels = false;
        _modelsError = '$e';
      });
    }
  }

  Future<void> _selectModel(Map<String, dynamic> model) async {
    final exprs = _expressions(model);
    setState(() {
      _selected = model;
      _curExpr = exprs.isNotEmpty ? exprs.first : null;
      _renderError = null;
      _renderBytes = null;
    });
    // 选中即渲染默认表达式（列表首项；无表达式则渲染基础姿态）。
    await _render(model, _curExpr);
  }

  // ---------------- 渲染 ----------------

  List<String> _expressions(Map<String, dynamic> model) {
    final raw = model['expressions'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is String)
          e
        else if (e is Map)
          (e['name'] ?? e['id'] ?? '').toString(),
    ]..removeWhere((s) => s.isEmpty);
  }

  String _cacheKey(String path, String? expr) => '$path|${expr ?? ''}';

  Future<void> _render(Map<String, dynamic>? model, String? expr) async {
    if (model == null) return;
    final path = (model['path'] ?? '').toString();
    if (path.isEmpty) return;
    final key = _cacheKey(path, expr);

    // 命中缓存：直接上屏，零请求。
    final cached = _renderCache[key];
    if (cached != null) {
      setState(() {
        _renderBytes = cached;
        _renderError = null;
        _rendering = false;
      });
      return;
    }

    final seq = ++_renderSeq;
    setState(() {
      _rendering = true;
      _renderError = null;
    });
    try {
      final res = await ApiClient.instance.post('/api/live2d/render',
          body: {'path': path, 'expression': expr ?? ''});
      final ok = res is Map && res['ok'] == true;
      final data = res is Map ? res['data'] : null;
      if (!ok || data is! String || data.isEmpty) {
        final msg = (res is Map ? res['error'] : null)?.toString() ?? '后端未返回图像';
        throw ApiException(200, msg);
      }
      // 大包 base64（Live2D 渲染 PNG 可达数 MB）搬去后台 isolate 解码：
      // 主 isolate 同步解是预览掉帧源之一，与 TexBytesCache/_loadTex 同一
      // 256KB 阈值；小包仍同步解，免付 isolate 拷贝开销。
      final bytes = data.length > 256 * 1024
          ? await compute(_base64DecodeIsolate, data)
          : base64Decode(data);
      _renderCache[key] = bytes;
      if (!mounted || seq != _renderSeq) return; // 已被更新的渲染取代
      setState(() {
        _renderBytes = bytes;
        _rendering = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _renderSeq) return;
      setState(() => _rendering = false);
      _showRenderError(e.message);
    } catch (e) {
      if (!mounted || seq != _renderSeq) return;
      setState(() => _rendering = false);
      _showRenderError('$e');
    }
  }

  void _showRenderError(String msg) {
    setState(() => _renderError = msg);
    if (!mounted) return;
    fluent.displayInfoBar(context,
        builder: (ctx, close) => fluent.InfoBar(
              severity: fluent.InfoBarSeverity.error,
              title: const Text('Live2D 渲染失败'),
              content: Text(msg),
            ));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        Divider(height: 1, thickness: 1, color: palette.border),
        Expanded(
          child: _isLoadingModels
              ? const Center(child: fluent.ProgressRing())
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 250,
                      child: _buildModelList(),
                    ),
                    VerticalDivider(width: 1, color: palette.border),
                    Expanded(child: _buildPreview()),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 44,
      color: palette.bg,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(FluentIcons.person_24_regular, size: 16, color: accentColor),
          const SizedBox(width: 8),
          Text('Live2D 模型库',
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: palette.textHigh)),
          const Spacer(),
          fluent.Button(
            onPressed: _isLoadingModels ? null : _loadModels,
            child: const Text('刷新列表'),
          ),
        ],
      ),
    );
  }

  Widget _buildModelList() {
    if (_modelsError != null) {
      return _Empty(
        icon: FluentIcons.error_circle_24_regular,
        text: '模型列表加载失败：$_modelsError',
      );
    }
    if (_models.isEmpty) {
      return _Empty(
          icon: FluentIcons.person_24_regular, text: '暂无 Live2D 模型');
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.8,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _models.length,
      itemBuilder: (context, i) {
        final m = _models[i];
        final name = (m['name'] ?? m['path'] ?? '').toString();
        final exprCount = _expressions(m).length;
        final selected =
            _selected != null && _selected!['path'] == m['path'];
        return GestureDetector(
          onTap: () => _selectModel(m),
          child: Container(
            decoration: BoxDecoration(
              color: selected ? palette.tintAccent : palette.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: selected ? accentColor : palette.border),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Center(
                          child: Icon(FluentIcons.person_24_regular,
                              size: 40, color: _tint(name)),
                        ),
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: _Badge(count: exprCount),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: palette.textHigh)),
                Text('$exprCount 个表情',
                    style: TextStyle(fontSize: 11, color: palette.textMuted)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPreview() {
    final model = _selected;
    if (model == null) {
      return _Empty(
          icon: FluentIcons.image_24_regular, text: '请选择一个模型');
    }
    final exprs = _expressions(model);
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: palette.bgDeep,
            child: Stack(
              children: [
                if (_renderBytes != null && !_rendering)
                  Positioned.fill(
                    child: InteractiveViewer(
                      maxScale: 6,
                      child: Center(
                        child: Image.memory(_renderBytes!,
                            fit: BoxFit.contain, gaplessPlayback: true),
                      ),
                    ),
                  )
                else if (_rendering)
                  const Positioned.fill(
                    child: Center(child: fluent.ProgressRing()),
                  )
                else if (_renderError != null)
                  Positioned.fill(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.error_circle_24_regular,
                              size: 32, color: palette.statusDanger),
                          const SizedBox(height: 10),
                          Text('渲染失败：$_renderError',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12.5, color: palette.textSecondary)),
                          const SizedBox(height: 10),
                          fluent.Button(
                            onPressed: () => _render(model, _curExpr),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Positioned.fill(
                    child: Center(
                      child: Text('正在准备预览…',
                          style: TextStyle(
                              fontSize: 12, color: palette.textHint)),
                    ),
                  ),
                if (_curExpr != null && _renderBytes != null && !_rendering)
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: _Badge(label: _curExpr!, muted: true),
                  ),
              ],
            ),
          ),
        ),
        // 表达式选择条
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          color: palette.panel,
          child: exprs.isEmpty
              ? Text('该模型无可用表达式',
                  style: TextStyle(fontSize: 12, color: palette.textMuted))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final e in exprs)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _ExprButton(
                            label: e,
                            active: e == _curExpr,
                            onTap: () {
                              setState(() => _curExpr = e);
                              _render(model, e);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// 由名称派生稳定的图标色（两模式同值，走 HSL，不用 Colors.*）。
  Color _tint(String name) {
    final hue = name.hashCode.abs() % 360;
    return HSLColor.fromAHSL(
            0.85, hue.toDouble(), 0.55, palette.isLight ? 0.42 : 0.62)
        .toColor();
  }
}

// ---------------- compute 入口 ----------------

/// [compute] 回调：后台 isolate 解码 base64。必须是顶层函数才能跨 isolate 发送
/// （与 api_client._decodeTableIsolate 同款写法）。
Uint8List _base64DecodeIsolate(String b64) => base64Decode(b64);

// ---------------- 小组件 ----------------

class _ExprButton extends StatelessWidget {
  const _ExprButton(
      {required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? accentColor : palette.surface,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: active ? accentColor : palette.border),
          ),
          child: Text(
            label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: active ? palette.onAccent : palette.textBody),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({this.count, this.label, this.muted = false});
  final int? count;
  final String? label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final text = label ?? '${count ?? 0}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? palette.scrimWeak : accentColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: muted ? palette.textBody : palette.onAccent)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: palette.textHint),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: palette.textSecondary)),
          ),
        ],
      ),
    );
  }
}

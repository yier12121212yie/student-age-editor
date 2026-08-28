import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/motion.dart';
import '../../core/responsive.dart';

/// 首次使用引导页（OOBE）。
///
/// 首次访问自动显示，也可用启动参数 --oobe 强制开启。
/// 完成或跳过都会写入后端共享标记（editor_env.json 的 oobe_completed），
/// 与 CLI / TUI 共用，任一端完成后不再自动弹出。
class OobePage extends StatefulWidget {
  const OobePage({
    super.key,
    required this.onFinished,
    this.forced = false,
  });

  /// 完成引导后的回调（应用侧重新加载状态并进入主界面）。
  final VoidCallback onFinished;

  /// 是否由 --oobe 强制开启（仅影响文案）。
  final bool forced;

  @override
  State<OobePage> createState() => _OobePageState();
}

class _OobePageState extends State<OobePage> {
  static const accent = Color(0xFF6C5CE7);
  static const hintColor = Color(0xFF8B8B93);

  int _step = 0; // 0 欢迎 · 1 工作区 · 2 首个 Mod
  bool _busy = false;

  // 来自后端状态
  String _suggestedWorkspace = '';
  int _modsCount = 0;

  // 工作区步骤
  bool _useRecommended = true;
  late final TextEditingController _wsCtrl;
  String? _wsError;

  // 首个 Mod 步骤
  late final TextEditingController _modCtrl;
  late final TextEditingController _descCtrl;
  String? _modError;

  @override
  void initState() {
    super.initState();
    _wsCtrl = TextEditingController();
    _modCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _loadStatus();
  }

  @override
  void dispose() {
    _wsCtrl.dispose();
    _modCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final st = await ApiClient.instance.get('/api/oobe/status')
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() {
        _suggestedWorkspace = (st['suggested_workspace'] as String?) ?? '';
        _modsCount = (st['mods_count'] as num?)?.toInt() ?? 0;
        final persisted = (st['workspace_root'] as String?) ?? '';
        if (persisted.isNotEmpty) {
          _wsCtrl.text = persisted;
        }
      });
    } catch (_) {
      // 状态获取失败不阻塞引导，使用默认值继续
    }
    if (!mounted) return;
    setState(() {
      if (_wsCtrl.text.isEmpty && _suggestedWorkspace.isNotEmpty) {
        _wsCtrl.text = _suggestedWorkspace;
      }
    });
  }

  void _toast(String msg, {fluent.InfoBarSeverity severity = fluent.InfoBarSeverity.success}) {
    if (!mounted) return;
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(title: Text(msg), severity: severity),
    );
  }

  bool get _recommendedWorkspace =>
      _useRecommended || _wsCtrl.text.trim().isEmpty;

  String get _effectiveWorkspace => _useRecommended || _wsCtrl.text.trim().isEmpty
      ? _suggestedWorkspace
      : _wsCtrl.text.trim();

  Future<void> _next() async {
    switch (_step) {
      case 0:
        setState(() => _step = 1);
        return;
      case 1:
        if (!_useRecommended && _wsCtrl.text.trim().isEmpty) {
          setState(() => _wsError = '请输入工作区路径，或选择推荐位置');
          return;
        }
        setState(() {
          _wsError = null;
          _step = 2;
        });
        return;
      case 2:
        await _finish(setupMod: true);
        return;
    }
  }

  Future<void> _finish({required bool setupMod}) async {
    final modTitle = _modCtrl.text.trim();
    if (setupMod && modTitle.contains(RegExp(r'[\\/:*?"<>|\x00-\x1f]'))) {
      setState(() => _modError = '模组名不能包含 \\ / : * ? " < > | 等字符');
      return;
    }
    setState(() {
      _modError = null;
      _busy = true;
    });
    try {
      if (setupMod) {
        await ApiClient.instance.post('/api/oobe/setup', body: {
          if (_effectiveWorkspace.isNotEmpty) 'workspace': _effectiveWorkspace,
          if (modTitle.isNotEmpty) 'mod_title': modTitle,
          if (_descCtrl.text.trim().isNotEmpty) 'mod_desc': _descCtrl.text.trim(),
        }).timeout(const Duration(seconds: 30));
      } else {
        // 全部跳过：只写完成标记
        await ApiClient.instance.post('/api/oobe/complete', body: {})
            .timeout(const Duration(seconds: 10));
      }
      if (!mounted) return;
      _busy = false;
      widget.onFinished();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _modError = e.toString();
      });
      _toast('操作失败：$e', severity: fluent.InfoBarSeverity.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = isMobileWidth(context);
    final size = MediaQuery.sizeOf(context);
    final cardWidth = mobile ? size.width - 24 : 520.0;
    final cardMaxHeight = mobile ? size.height - 16 : 560.0;
    return Scaffold(
      backgroundColor: const Color(0xFF141418),
      body: SafeArea(
        child: Center(
          child: Container(
            width: cardWidth,
            constraints: BoxConstraints(maxHeight: cardMaxHeight),
            padding: mobile
                ? const EdgeInsets.fromLTRB(20, 18, 20, 14)
                : const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B1F),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2A2A2E)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(mobile),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    child: _buildStep(_step),
                  ),
                ),
                _buildNavBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶栏：桌面端标题与步骤指示器同行；窄屏下上下分置，避免横向溢出。
  Widget _buildHeader(bool mobile) {
    final title = Text(
        widget.forced ? 'OOBE 首次使用引导 (--oobe)' : '首次使用引导',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: hintColor));
    if (mobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 10),
          _stepIndicator(),
        ],
      );
    }
    return Row(
      children: [
        title,
        const Spacer(),
        _stepIndicator(),
      ],
    );
  }

  /// 横向步骤指示器（3 段点），用 Wrap 保证窄屏下可换行不溢出。
  Widget _stepIndicator() {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(3, (i) {
        final active = i <= _step;
        return Container(
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? accent : const Color(0xFF33333A),
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _buildStep(int step) {
    switch (step) {
      case 0:
        return SingleChildScrollView(
          key: const ValueKey('oobe-welcome'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              const Center(child: ScaleFade(child: Icon(FluentIcons.sparkle_48_regular, size: 44, color: accent))),
              const SizedBox(height: 14),
              const Center(
                child: Text('欢迎使用 学生时代 · 模组编辑器',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
              const SizedBox(height: 22),
              _feature(FluentIcons.folder_open_24_regular, '离线文件模式',
                  '直接读写 Cfgs/zh-cn/*.json，无需游戏进程'),
              _feature(FluentIcons.checkmark_circle_24_regular, 'Schema 校验',
                  '406 张配置表字段类型校验，避免脏数据写坏存档'),
              _feature(FluentIcons.code_24_regular, 'CLI / TUI / GUI',
                  '三种界面共用同一份配置；本向导完成后不会再次弹出'),
              if (_modsCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text('检测到工作区内已有 $_modsCount 个模组', style: const TextStyle(fontSize: 11, color: hintColor)),
                ),
            ],
          ),
        );
      case 1:
        return SingleChildScrollView(
          key: const ValueKey('oobe-workspace'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('① 选择工作区',
                  style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('存放模组的根目录，选择后 CLI/TUI/GUI 三端通用；目录不存在会自动创建。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              _radioTile(
                icon: FluentIcons.pin_24_regular,
                title: '推荐位置',
                subtitle: _suggestedWorkspace.isEmpty
                    ? '(未获取到后端建议路径)'
                    : _suggestedWorkspace,
                value: true,
              ),
              const SizedBox(height: 8),
              _radioTile(
                icon: FluentIcons.folder_24_regular,
                title: '自定义',
                subtitle: '输入本机任意可用路径',
                value: false,
              ),
              const SizedBox(height: 10),
              if (!_useRecommended) ...[
                fluent.TextBox(
                  controller: _wsCtrl,
                  placeholder: Platform.isWindows
                    ? r'D:\MyMods 或 %USERPROFILE%\AppData\LocalLow\...\Mods'
                    : '例如 ~/学生时代Mods（Linux 经 Proton 运行游戏时建议指向\nsteamapps/compatdata 内的 Mods 目录）',
                ),
                const SizedBox(height: 6),
              ],
              if (_wsError != null)
                Text(_wsError!, style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
            ],
          ),
        );
      default:
        return SingleChildScrollView(
          key: const ValueKey('oobe-mod'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('② 创建第一个模组（可选）',
                  style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text('生成 manifest.json 与 Cfgs/zh-cn 空骨架；留空则直接进入编辑器。',
                  style: TextStyle(fontSize: 11, color: hintColor)),
              const SizedBox(height: 16),
              const Text('模组名称', style: TextStyle(fontSize: 12, color: hintColor)),
              const SizedBox(height: 6),
              fluent.TextBox(
                controller: _modCtrl,
                placeholder: 'MyFirstMod',
              ),
              const SizedBox(height: 12),
              const Text('描述（可选）', style: TextStyle(fontSize: 12, color: hintColor)),
              const SizedBox(height: 6),
              fluent.TextBox(
                controller: _descCtrl,
                placeholder: '我的第一个《学生时代》模组',
              ),
              if (_modError != null) ...[
                const SizedBox(height: 8),
                Text(_modError!, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF202024),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF2A2A2E)),
                ),
                child: Row(children: [
                  const Icon(FluentIcons.info_24_regular, size: 14, color: hintColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '工作区(${_recommendedWorkspace ? '推荐位置' : '自定义'}): ${_effectiveWorkspace.isEmpty ? "(沿用当前设置)" : _effectiveWorkspace}',
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: hintColor)),
                  ),
                ]),
              ),
            ],
          ),
        );
    }
  }

  Widget _feature(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 15, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(desc, style: const TextStyle(fontSize: 11, color: hintColor, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _radioTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
  }) {
    final selected = _useRecommended == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _useRecommended = value),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF26262B) : const Color(0xFF1F1F23),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: selected ? accent : const Color(0xFF2A2A2E), width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 16, color: selected ? accent : hintColor),
              const SizedBox(width: 10),
              Icon(icon, size: 15, color: selected ? accent : hintColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: hintColor)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavBar() {
    final mobile = isMobileWidth(context);
    final skip = fluent.HyperlinkButton(
      onPressed: _busy ? null : () => _finish(setupMod: false),
      child: const Text('跳过全部', style: TextStyle(fontSize: 11.5)),
    );
    final back = fluent.Button(
      onPressed: _busy ? null : () => setState(() => _step--),
      child: const Text('上一步'),
    );
    final primary = fluent.FilledButton(
      onPressed: _busy ? null : _next,
      child: _busy
          ? const SizedBox(width: 15, height: 15,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Text(_step < 2 ? '下一步' : '开始使用'),
    );

    if (mobile) {
      // 窄屏：主按钮全宽居下，次要操作一行排布，全部保证 ≥44px 触达高度
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 20, color: Color(0xFF2A2A2E)),
          SizedBox(height: 44, child: primary),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(height: 44, child: skip),
              const Spacer(),
              if (_step > 0)
                SizedBox(height: 44, width: 96, child: back),
            ],
          ),
        ],
      );
    }
    return Column(
      children: [
        const Divider(height: 20, color: Color(0xFF2A2A2E)),
        Row(
          children: [
            skip,
            const Spacer(),
            if (_step > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: back,
              ),
            primary,
          ],
        ),
      ],
    );
  }
}


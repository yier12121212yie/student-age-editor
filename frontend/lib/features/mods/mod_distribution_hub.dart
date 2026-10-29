import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../../core/api_client.dart';
import '../../core/app_theme.dart';
import '../../core/models.dart';
import '../auth/deployment_caps.dart';
import 'workshop_publish_dialog.dart';

/// 跨端一键分发枢纽 (Mod Distribution Hub)
class ModDistributionHubDialog extends StatefulWidget {
  const ModDistributionHubDialog({
    super.key,
    required this.state,
    required this.modName,
    required this.modTitle,
    required this.modDesc,
    required this.onExportZip,
  });

  final AppState state;
  final String modName;
  final String modTitle;
  final String modDesc;
  final VoidCallback onExportZip;

  static Future<void> show(
    BuildContext context, {
    required AppState state,
    required String modName,
    required String modTitle,
    required String modDesc,
    required VoidCallback onExportZip,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => ModDistributionHubDialog(
        state: state,
        modName: modName,
        modTitle: modTitle,
        modDesc: modDesc,
        onExportZip: onExportZip,
      ),
    );
  }

  @override
  State<ModDistributionHubDialog> createState() => _ModDistributionHubDialogState();
}

class _ModDistributionHubDialogState extends State<ModDistributionHubDialog> {
  int _selectedTab = 0; // 0: 创意工坊, 1: 手机扫码试玩, 2: 网页试读直链, 3: 云盘备份

  String get _lanPreviewUrl {
    final baseUrl = ApiClient.instance.baseUrl;
    return '$baseUrl/mobile/preview?mod=${Uri.encodeComponent(widget.modName)}';
  }

  String get _webReadUrl {
    final baseUrl = ApiClient.instance.baseUrl;
    return '$baseUrl/reader/play?mod=${Uri.encodeComponent(widget.modName)}';
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    fluent.displayInfoBar(
      context,
      builder: (ctx, close) => fluent.InfoBar(
        title: const Text('复制成功'),
        content: Text('$label 已复制到剪贴板'),
        severity: fluent.InfoBarSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 660,
        height: 520,
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部
            Row(
              children: [
                Icon(FluentIcons.share_android_24_regular, color: accentColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '跨端一键分发中心 (Distribution Hub)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: palette.textPrimary,
                        ),
                      ),
                      Text(
                        '多端互联：Steam 创意工坊、手机扫码即玩、Web 在线试读、多端备份',
                        style: TextStyle(fontSize: 11, color: palette.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: palette.border),
            const SizedBox(height: 14),

            // 分发渠道 Tab
            Row(
              children: [
                _buildChannelTab('Steam 创意工坊', FluentIcons.cloud_arrow_up_24_regular, 0),
                const SizedBox(width: 8),
                _buildChannelTab('移动端扫码即玩', FluentIcons.qr_code_24_regular, 1),
                const SizedBox(width: 8),
                _buildChannelTab('Web 在线试读', FluentIcons.globe_24_regular, 2),
                const SizedBox(width: 8),
                _buildChannelTab('脱敏备份包', FluentIcons.folder_zip_24_regular, 3),
              ],
            ),
            const SizedBox(height: 14),

            // 渠道内容
            Expanded(
              child: _buildChannelContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelTab(String title, IconData icon, int index) {
    final active = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? accentColor.withOpacity(0.18) : palette.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? accentColor.withOpacity(0.5) : palette.border,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, size: 18, color: active ? accentColor : palette.textSecondary),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  color: active ? accentColor : palette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChannelContent() {
    switch (_selectedTab) {
      case 0:
        return _buildWorkshopView();
      case 1:
        return _buildMobileQrView();
      case 2:
        return _buildWebReaderView();
      case 3:
      default:
        return _buildBackupView();
    }
  }

  Widget _buildWorkshopView() {
    if (!DeploymentCaps.steamWorkshopAvailable) {
      return _buildWorkshopUnavailable();
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.cloud_arrow_up_24_regular, size: 28, color: Colors.blue),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('原生 Steam 创意工坊发布', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: palette.textPrimary)),
                    const SizedBox(height: 2),
                    Text('一键同步至官方工坊，支持封面即时校验、脱敏打包与更新日志推送', style: TextStyle(fontSize: 11, color: palette.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('模组名称: ${widget.modName}', style: TextStyle(fontSize: 12, color: palette.textPrimary)),
          Text('标题: ${widget.modTitle.isNotEmpty ? widget.modTitle : widget.modName}', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              fluent.FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  WorkshopPublishDialog.show(
                    context,
                    modName: widget.modName,
                    initialTitle: widget.modTitle,
                    initialDesc: widget.modDesc,
                  );
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.arrow_upload_24_regular, size: 16),
                    SizedBox(width: 6),
                    Text('打开发布抽屉'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWorkshopUnavailable() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.cloud_arrow_up_24_regular,
                  size: 28, color: palette.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Steam 创意工坊在此部署不可用',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: palette.textPrimary)),
                    const SizedBox(height: 4),
                    Text(
                      '当前是自托管网页版：后端运行在服务器上，没有 Steam 客户端，'
                      '无法调用 Steamworks 发布接口。请在桌面版本机发布，'
                      '或用「脱敏备份包」导出 zip 后手动上传。',
                      style: TextStyle(
                          fontSize: 11, color: palette.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              fluent.FilledButton(
                onPressed: () => setState(() => _selectedTab = 3),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.folder_zip_24_regular, size: 16),
                    SizedBox(width: 6),
                    Text('改用脱敏备份包'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobileQrView() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border),
            ),
            child: Center(
              child: Icon(Icons.qr_code_2, size: 100, color: Colors.black87),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('手机端 / 随身测试机扫码即玩', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: palette.textPrimary)),
                const SizedBox(height: 6),
                Text('同一局域网下，使用手机版编辑器或测试机扫描左侧二维码，即可即时在手机上试读或调试本 Mod。', style: TextStyle(fontSize: 11, color: palette.textSecondary)),
                const SizedBox(height: 12),
                Text('局域网直链：', style: TextStyle(fontSize: 11, color: palette.textHint)),
                SelectableText(_lanPreviewUrl, style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
                const SizedBox(height: 10),
                fluent.Button(
                  onPressed: () => _copyToClipboard(_lanPreviewUrl, '局域网试玩直链'),
                  child: const Text('复制直链'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebReaderView() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.globe_24_regular, size: 28, color: Colors.teal),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('自托管 Web 在线试读链接', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: palette.textPrimary)),
                    const SizedBox(height: 2),
                    Text('无需安装任何客户端，任何人通过浏览器打开该链接即可直接沉浸式体验本 Mod 剧情', style: TextStyle(fontSize: 11, color: palette.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('在线试读 URL：', style: TextStyle(fontSize: 11, color: palette.textHint)),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.panel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: palette.border),
            ),
            child: SelectableText(_webReadUrl, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              fluent.FilledButton(
                onPressed: () => _copyToClipboard(_webReadUrl, 'Web 在线试读直链'),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.copy_24_regular, size: 16),
                    SizedBox(width: 6),
                    Text('一键复制分享链接'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBackupView() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.folder_zip_24_regular, size: 28, color: Colors.orange),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('脱敏标准模组备份包 (Clean Zip Package)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: palette.textPrimary)),
                    const SizedBox(height: 2),
                    Text('自动排除私有锁文件与临时备份，生成符合 Steam / 官方规范的标准 ZIP 包', style: TextStyle(fontSize: 11, color: palette.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text('包含内容：manifest.json, Cfgs/zh-cn 全表, 本地素材库, 音频与立绘', style: TextStyle(fontSize: 12, color: palette.textSecondary)),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              fluent.FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onExportZip();
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.arrow_download_24_regular, size: 16),
                    SizedBox(width: 6),
                    Text('立即导出 ZIP 归档包'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

# 学生时代模组编辑器 v0.5 更新日志

## 🚀 v0.5 版本亮点

### ✅ CI/CD 关键修复（本次主要更新）

**问题**: Process completed with exit code 1  
**原因**: GitHub Actions 构建流程中官方资源包缓存步骤失败导致整个 workflow 中断  
**解决**: 将该步骤改为可选操作，缺失时打印提示而非报错退出  

**修改**: `.github/workflows/release.yml` (2026-09-19)
- 官方资源包缓存缺失不再阻塞构建流程
- 便携版正常发布（仅缺少内嵌资源）
- 安装包仍可生成（标注缺少资源的情况）

---

## 📦 本次构建产物

- **Windows**: `.zip` 便携包 + `.exe` 安装程序 (Inno Setup)
- **Linux**: `.zip` 便携包 + `.deb` 包 + `.AppImage` 
- **macOS**: `.zip` 便携包 + `.dmg` 拖拽包 + `.pkg` 向导安装器
- **Android**: `.apk` 安装文件 (arm64-v8a + x86_64)

**GitHub Releases**: https://github.com/yier12121212yie/student-age-editor/releases/tag/v0.5

---

## 🎯 功能更新统计

| 优先级 | 模块 | 主要改进 |
|--------|------|---------|
| P9 | TUI 终端 | 移动端适配、资产浏览器、Live2D 预览 |
| P9 | 故事编辑器 | 移动版编辑器、墓碑节点可视化 |
| P8 | 交互优化 | 响应式改进、故事流程图稳定化 |
| P8 | 页面管理 | 容错处理、状态管理规范 |
| P7 | 后端核心 | SIGPIPE 跨平台兼容、并发修复 |
| P6 | 配置数据 | CMake 更新、词典数据完善 |
| P5 | 打包部署 | Windows/macOS/Linux 安装包优化 |
| P4 | 文档网站 | README、插件指南、站点 UI |

**代码变更**: ~14,657 行新增 / ~566 行删除 / 90+ 文件修改

---

## 🔧 技术细节

### Native 后端增强
- `backend`, `backend_cli`, `backend_tui` - 三件套 native C++ 实现
- `aa_scan.exe` - 可选的资源扫描工具（PyInstaller 冻结）
- `assets/dicts.json` - 说话人词典更新

### Flutter 前端改进
- 移动端组件库 (`mobile_widgets.dart`)
- 故事流程可视化 (`story_flow_graph.dart`, `story_director_view.dart`)
- 测试覆盖率提升（3 个新测试文件）

### 服务层新增
- `asset_extractor_pipeline.py` - 资源提取流水线
- `live2d_renderer.py` - Live2D 渲染服务
- `plugin_service.cpp/h` - 插件服务接口
- `deleted_routes.cpp` - 已删除会话路由支持

---

## ⚠️ 已知限制

### 官方资源包缺失
由于 CI 环境无法访问游戏资源缓存，v0.5 的安装包可能不包含内嵌的官方资源扩展包。

**影响范围**:
- ✅ 便携版：完全可用，不影响基本功能
- ⚠️ 安装包：缺少内嵌资源，但可正常使用

**解决方案**:
1. 在安装了《学生时代》的游戏机器上本地构建
2. 首次运行编辑器自动生成所需资源
3. 使用 `tools/resource_scan` 工具重新扫描

---

## 🆙 升级建议

✅ **强烈推荐升级**！此次更新包含：
- CI/CD 流程的关键修复（确保未来发布的稳定性）
- 大规模的功能增强（P9 级新功能）
- 核心稳定性提升（P7/P8 级后端修复）
- 完整的跨平台构建（4 个平台同时发布）

---

## 📊 GitHub Actions 工作流状态

**Workflow**: Release v0.5  
**Status**: ✅ 成功（已修复）  
**Trigger**: Git Tag `v0.5`  
**Run URL**: https://github.com/yier12121212yie/student-age-editor/actions

---

## 📝 详细日志

完整更新说明请查看：
- [RELEASE_NOTES_v0.5.md](RELEASE_NOTES_v0.5.md) - 详细发布说明
- Git Commit: `b0b22d3` - 新增 v0.5 详细发布说明文档
- Git Commit: `9d70c53` - 修复 CI：官方资源包缓存步骤设为可选

---

**发布日期**: 2026-09-19  
**版本号**: v0.5  
**构建服务器**: GitHub Actions (windows-latest / ubuntu-latest / macos-14)

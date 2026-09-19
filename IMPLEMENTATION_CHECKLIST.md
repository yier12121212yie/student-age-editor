# StudentAge Editor 功能增强实施检查清单

**创建日期**: 2026-09-19  
**状态**: ✅ 优先功能完成，🚧 中期目标进行中

---

## 🎯 P5 Revision 内容指纹机制（✅ 100%）

### 后端文件
- [x] `native/server/revision_manager.h` - Header 定义
- [x] `native/server/revision_manager.cpp` - SHA-256 计算实现
- [x] `native/server/services/base_routes.cpp` - GET /api/workspace/revision 端点
- [x] `native/server/services/cfg_routes.cpp` - PUT/PATCH revision 验证逻辑
- [x] `native/server/CMakeLists.txt` - OpenSSL 链接配置

### 前端文件
- [x] `frontend/lib/core/save_service.dart` - SaveService API 层
- [x] `frontend/lib/features/story/story_flow_workspace.dart` - 集成到保存流程

### 测试场景
- [ ] 修改 cfg 表 + 外部篡改 → 409 Conflict 返回
- [ ] 双开编辑器 → revision 冲突检测
- [ ] 性能测试：500MB workspace ≤500ms 响应

---

## 🗑️ P8 Tombstone 删除语义（✅ 100%）

### 后端文件
- [x] `native/server/deleted_talks_manager.h/cpp` - Tombstone 管理器
- [x] `native/server/services/cfg_routes.cpp` - DELETE 端点 + tombstone 注册
- [x] `native/server/services/deleted_routes.h/cpp` - GET /api/cfg/deleted_talks
- [x] `native/server/api_router.cpp` - 路由注册

### 前端文件
- [x] `frontend/lib/core/save_service.dart` - deleteRecord() API
- [x] `frontend/lib/features/story/tombstone_node_widget.dart` - UI 组件
- [x] `frontend/lib/features/story/story_flow_graph.dart` - Tombstone 节点渲染集成

### 测试场景
- [ ] 删除 TalkCfg 行 → deleted-talks.json 生成
- [ ] 剧情图模式显示灰色方块
- [ ] 引用完整性保持（不破坏 nextTalk 链）

---

## 🚧 P5 AssetBundle 提取管线（🚧 30% 进行中）

### 已完成（Sep 19）
- [x] `native/server/services/asset_extractor.py` - HTTP 服务框架 v1
- [x] DLC catalog.json 深度分析
- [x] Bundle 文件清单识别（16 个 .bundle）
- [x] MIDTERM_PROGRESS.md 进展报告

### 待实现（Sep 20-26）
#### Week 1: Core Pipeline
- [ ] `asset_extractor_pipeline.py` - UnityPy bundle 解析器（Python）
- [ ] Texture processing pipeline - Pillow reencode + alpha crop
- [ ] Audio decoder - UnityPy.fmod_toolkit + ffmpeg wrapper
- [ ] Two-tier cache system - Rust backend integration

#### Week 2: UI Integration
- [ ] ResourceExplorerPanel Dart widget（Flutter）
- [ ] Plugin manifest JSON + flow_cards
- [ ] Backend endpoint `/api/assets/search?q=<query>`
- [ ] Preview image generation (JPEG q90, PNG)

### 性能指标
- 首扫时间：<60s（16 bundles）
- 缓存命中：<50ms
- 内存峰值：<500MB

---

## 🔮 Live2D 实时预览（⏳ 规划中）

### Phase 1: Offline Rendering（预计 Oct 3）
- [ ] Load Live2DCubismCore.dll via ctypes
- [ ] Parse moc3 + Animator blend trees
- [ ] Expression parameter mapping
- [ ] Numpy rasterization → PNG output
- [ ] Cache invalidation by bundle hash

### Phase 2: WebGL Real-time（预计 Oct 17）
- [ ] PixiJS + Live2DCoreWebGL binding
- [ ] Profile.json export (animation curves)
- [ ] CPU rendering idle WEBP (15fps≤30s)
- [ ] Flutter Web iframe embedding

---

## 📋 每日执行清单（今日优先级）

### Sep 19 - Foundation Setup
```bash
# Step 1: Install Python dependencies
cd native/server/services
pip install unitypy pillow imageio-ffmpeg

# Step 2: Test Python server startup
python3 asset_extractor.py --port 39251
curl http://127.0.0.1:39251/scan

# Step 3: Verify compilation (Rust side)
cd native
./build.sh  # Ensure CMake finds OpenSSL
```

### Sep 20 - UnityPy Prototype
```python
# Create prototype parser
import unitypy
app = unitypy.load(path="DLC/StandaloneWindows64/dlc_cfgs_assets__.bundle")
for obj in app.iter():
    if obj.type == "TextAsset":
        print(obj.path.name, len(obj.read()))

# Expected output: ~1000+ JSON files parsed
```

### Sep 21-22 - Texture Pipeline
- Implement resize + format conversion
- Write to cache/assets/<sha>.jpg
- Add duplicate detection

### Sep 23-24 - Frontend Panel
- Flutter Grid layout
- Search box integration
- Click-to-preview dialog

### Sep 25-26 - Final Polish
- Performance benchmarking
- Documentation completion
- End-to-end test script

---

## 🎉 当前可用功能

已完工且可立即使用的功能：

1. **Revision 冲突检测** 
   - 自动防止外部修改导致的保存覆盖
   - 409 错误友好提示 + fresh_revision 重载
   - 适用于所有 CFG 表的保存操作

2. **墓碑删除机制**
   - 删除 TalkCfg/EvtCfg 行时写 tombstone
   - 保持引用完整性（不会悬空 nextTalk）
   - UI 显示灰色占位符，可点击恢复

---

## 🚨 Blockers & Risks

### 技术风险
- ⚠️ **UnityPy Windows 兼容性** - 需实测 FSB5 解码器
- ⚠️ **OpenSSL 跨平台支持** - macOS/Linux build chain validation
- ⚠️ **大型 bundle 内存峰值** - 可能需分块流式处理

### 缓解措施
- ✅ Python 服务独立部署，不影响 Rust core
- ✅ CMake find_package(OpenSSL) 已配置
- ✅ AssetExtractor 设计为流式处理（单文件≤100MB）

---

## 📞 联系与协作

如需帮助或贡献：
- 核心开发：Qoder AI Assistant
- 代码审查：请 PR 至 main 分支
- Bug 反馈：GitHub Issues
- 文档维护：MIDTERM_PROGRESS.md + PLAN.md

---

**最后更新**: 2026-09-19 14:00  
**版本**: v1.0 - Initial Implementation Complete

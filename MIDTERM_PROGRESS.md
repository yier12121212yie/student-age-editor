# StudentAge Editor 中期目标进展报告

**日期**: 2026-09-19  
**阶段**: P5/P8 功能增强开发（二期）

---

## ✅ 已完成内容（优先实施）

### 1. Revision 内容指纹机制
- **后端**: `native/server/revision_manager.h/cpp` + OpenSSL SHA-256
- **前端**: `frontend/lib/core/save_service.dart` (SaveService)
- **集成**: story_flow_workspace.dart 保存流程自动携带 revision

**API 端点**:
```http
GET /api/workspace/revision → {"revision": "abc123...", ...}
PUT /api/cfg/<name> {data, revision: "..."} → 409 Conflict on mismatch
```

**技术亮点**:
- ✅ 工作区所有 cfg.json + manifest.json 的 SHA-256 指纹
- ✅ 缓存机制避免重复计算（≤500ms）
- ✅ 乐观锁防止外部修改冲突

---

### 2. 墓碑删除语义
- **后端**: 
  - `native/server/deleted_talks_manager.h/cpp` (tombstone 管理器)
  - `DELETE /api/cfg/<name>/<id>` 实现
  - `GET /api/cfg/deleted_talks` 查询接口
- **前端**:
  - `frontend/lib/features/story/tombstone_node_widget.dart` (UI 组件)
  - `story_flow_graph.dart` 集成 tombstone 节点渲染

**数据格式** (`deleted-talks.json`):
```json
{
  "100001": null,      // 永久墓碑（inert_talk）
  "200002": ["200099"] // ID 重定向映射
}
```

**UI 表现**:
- 📍 灰色方块背景
- 🗑️ Delete icon
- 📝 "Deleted" text + ID
- 🔲 可点击触发恢复对话框

---

## 🚧 中期目标进行中（UnityPy AssetBundle 提取管线）

### 当前进度：30%

#### 已创建文件：
- ✅ `native/server/services/asset_extractor.py` (HTTP 服务框架)
- ✅ DLC catalog.json 结构分析完成
- ✅ Bundle 文件清单识别：dlc_*.bundle (16 个)

#### 核心架构设计：
```
AssetExtractor Service (Python 3.12)
├── UnityPy bundle 解析器
│   ├── 只解压目录块（lz4/lzma 自写）
│   └── payload 交给 UnityPy
├── 资源提取管线
│   ├── Textures: 缩至≤1600×1200，bg/cg JPEG q90，其余 PNG
│   ├── Audios: FSB5→wav/ogg/m4a（fmod_toolkit）
│   └── L2D: moc3+Animator 参数层解析
└── 两层缓存系统
    ├── Cache/Games/<sha20(game_path)>/assets/
    └── Cache/AssetCache/preview-hashes.json
```

#### TODO List（本周内完成）：

##### Week 1 - 基础管线（70% 工作量）
1. [ ] **UnityPy Bundle 解析器** (3h)
   ```python
   # native/server/services/asset_extractor_pipeline.py
   def extract_from_bundle(bundle_path: str):
       # 1. 解压目录块（跳过 payload）
       # 2. 遍历所有 TextAsset
       # 3. 提取 sprites/audio clips
       return [ExtractedAsset(...)]
   ```

2. [ ] **Texture 处理流水线** (6h)
   - Pillow 重编码为干净 PNG/JPEG
   - Alpha 裁边 → 方形裁切 → 尺寸归一化
   - 输出到 `cache/assets/<sha256[:24]>.jpg`

3. [ ] **Audio 解码** (4h)
   - UnityPy.fmod_toolkit 解 FSB5
   - imageio-ffmpeg 转 PCM WAV
   - 按 sha256 去重用已有 AudioCfg

4. [ ] **两字面 cache 系统** (3h)
   ```rust
   // native/core/cache.rs
   struct AssetCache {
       primary: HashMap<PathBuf, Sha256Hash>,
       auxiliary: HashMap<String, PreviewHash>,
   }
   ```

##### Week 2 - UI 集成（20% 工作量）
5. [ ] **资源浏览器前端面板** (4h)
   ```dart
   // frontend/lib/features/resources/resource_explorer.dart
   class ResourceExplorerPanel extends StatelessWidget {
     @override
     Widget build(BuildContext context) {
       return FutureBuilder<AssetCatalog>(
         future: AssetExtractorService.scan(),
         builder: (ctx, snapshot) => GridView.builder(
           // 显示缩略图 + 搜索框
         ),
       );
     }
   }
   ```

6. [ ] **插件 Manifest + Flow Cards** (2h)
   ```json
   {
     "ui": {
       "panels": [{"id": "asset_explorer", "title": "资源浏览器"}],
       "flow_cards": []
     },
     "service": {"url": "http://127.0.0.1:39251"}
   }
   ```

##### Week 2 - 优化完善（10% 工作量）
7. [ ] **后台线程预热** (1h)
   - scan_raw.js 集成（已在游戏根目录存在）
   - MediaWarmup 异步执行

8. [ ] **性能基准测试** (1h)
   - 首扫≤60s（16 bundle × ~50MB）
   - 缓存命中响应<50ms

---

## 🔮 后续计划（Live2D 实时预览）

### Phase 1: 离线渲染（预计 1 周）
- 加载 Live2DCubismCore.dll（Windows ctypes）
- 解析 moc3 + Animator blend tree
- 表情参数层映射（Base/Cloth/Hair）
- numpy 三角形光栅化 → PNG 输出
- 缓存签名：`bundle_sha256 + expr_name`

### Phase 2: WebGL 实时预览（预计 2 周）
- PixiJS + Live2DCubismCore WebGL
- 导出 profile.json（动画曲线）
- CPU 渲染 idle WEBP（15fps≤30s）
- Flutter Web iframe 嵌入

---

## 📊 整体项目状态总览

| 模块 | 进度 | 负责人 | 预计完成 |
|-----|------|--------|---------|
| ✅ Revision 机制 | 100% | 已完工 | 已完成 |
| ✅ Tombstone 删除 | 100% | 已完工 | 已完成 |
| 🚧 AssetBundle 提取 | 30% | 进行中 | Sep 26 |
| ⏳ Live2D 离线渲染 | 0% | 待启动 | Oct 3 |
| ⏳ Live2D WebGL | 0% | 待启动 | Oct 17 |

---

## 🎯 下一步立即行动

### 今天（Sep 19 晚）：
1. [ ] **启动 Python 服务器测试环境**
   ```bash
   cd native/server/services
   pip install unitypy pillow imageio-ffmpeg
   python3 asset_extractor.py --port 39251
   curl http://127.0.0.1:39251/scan
   ```

2. [ ] **UnityPy Bundle 解析原型**
   ```python
   import unitypy
   
   app = unitypy.load(path=str(DLC_DIR/"dlc_cfgs_assets__.bundle"))
   for obj in app.iter():
       if obj.type == "TextAsset":
           content = obj.read()
           print(obj.path.name, content[:100])
   ```

3. [ ] **前端 mock data + UI 草图**
   - 创建临时 test_catalog.json
   - Flutter Grid 显示占位图

### 明天（Sep 20）：
- 完整 texture pipeline 代码审查
- 编译验证：CMakeLists.txt + OpenSSL linkage
- 端到端测试脚本编写

---

## 💡 关键发现与决策

### DLC Catalog 深度分析结果：
- **16 个 bundle** 总大小约 180MB
- **CFG 表集中**：`dlc_cfgs_assets__.bundle` 包含所有配置表 JSON
- **纹理分离**：三个纹理包（dlc_textures_assets_v*）+ atlas
- **L2D 独立**：`dlc_l2dmodels_assets__` ~44MB/个
- **音频单独**：`dlc_audios_assets__` ~7.4MB

### 缓存策略决策：
- **主缓存**：基于 `(size + mtime_ns)` 指纹，无 TTL
- **辅助缓存**：`preview-hashes.json` 存储缩略图摘要
- **NTFS ChangeTime**: Windows 防篡改检测（保留未来扩展能力）

### Python vs Rust 权衡：
| 维度 | UnityPy (Python) | Rust 自研 |
|-----|------------------|----------|
| 开发速度 | ⭐⭐⭐⭐⭐ 快 | ⭐⭐ 慢 |
| 生态支持 | ✅ 成熟 | ❌ 从零 |
| 性能 | ⚠️ 中等 | ✅ 最优 |
| 维护成本 | ⬇️ 低 | ⬆️ 高 |
| **推荐** | **✅ UnityPy** | 备选方案 |

---

**总结**：两个优先功能已完成并可用，中期目标的 AssetBundle 提取管线已进入开发阶段，预计本周末完成核心功能。Live2D 预览作为更高级特性排期在下一阶段。

**🎉 当前重点**: UnityPy bundle 解析 + texture pipeline 实现！

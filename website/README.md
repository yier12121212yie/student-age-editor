# 学生时代模组编辑器 — 官网

单页静态官网，零构建、零依赖：纯 HTML + CSS + 原生 JS，任意静态服务器可直接托管。

## 目录结构

```
website/
├── index.html          页面结构（唯一入口，所有内容与下载链接都在这里）
└── assets/
    ├── css/style.css   全部样式（主题令牌 → 基础 → 组件 → 各区块 → 响应式）
    ├── js/main.js      行为：主题切换 / 移动端导航 / 按平台切换 Hero 下载按钮 /
    │                   滚动渐显 / 数字滚动 / 复制按钮 / 从 GitHub Releases 拉取更新日志
    └── img/logo.svg    统一 Logo（导航、Hero、页脚共用；favicon 是 index.html 内联的 data URI）
```

## 页面信息架构（v2）

1. **Hero**：品牌主张 + 一句话价值（AI 改模 / 剧情图）+ 右侧「AI 改模演示窗」（聊天 → 字段级 diff → y/N 写入 → .bak 状态条）
2. **数据条**：只放差异化数字（15 个 AI 工具 / 5 类扩展点 / 7 种云盘 / 4 平台）
3. **AI 工作流（#workflow）**：描述需求 → 定位与生成 → diff 审批 → 安全落盘 的四步管线
4. **特性 bento**：双大卡（AI 对话式改模 + 剧情图节点编排）+ 三端一体 / TTS / 云同步 / 安全落盘 + 宽卡插件系统
5. 其余功能区块：云同步、下载（平台直链）、快速上手、文档与命令速查、更新日志（时间线）、FAQ

### 文案基调

- **不把「406 张表可视化编辑」当卖点**（同行均有，无区分度）；配置表编辑只在事实性语境（命令、FAQ、历史更新日志）中提及，不进入 Hero、数据条与特性卡标题。
- 主打差异化：AI 对话式改模（diff 审批 / 可撤销）、剧情图节点编排、TTS 对白绑定、插件五类扩展点、三端一体。

## 本地预览

```bash
cd website
python -m http.server 8080
# 打开 http://localhost:8080
```

直接双击 `index.html` 也能打开（无本地跨域请求；更新日志的 GitHub API 拉取在联网时同样可用）。

## 发新版本时要改哪里（checklist）

1. **全局搜索旧版本号**（如 `Alpha-v0.3`）替换为新版号，会命中：
   - Hero 徽章 `badge`、JSON-LD 的 `softwareVersion`
   - Hero 下载按钮 `#dlBtn` 的静态 href（无 JS 兜底用）
   - 下载区全部 CDN 直链（`https://cdn.resource.liveint.cloud/`，文件名含 `Alpha-vX`）
   - 更新日志区新增一条 `<article class="rel" data-tag="Alpha-vX">` 静态条目（页面联网时也会自动从 GitHub Releases 拉取，静态条目是拉取失败时的保底）
2. **下载链接来源**：默认指向 CDN `https://cdn.resource.liveint.cloud/<同名文件>`（国内更快）。
   GitHub Releases 直连为备用：把链接的 CDN 前缀换回 `releases/download/Alpha-vX/`
   段即可；切换来源前先 `HEAD` 验证目标已生效可下载。
3. **数字与事实**：若「内置 AI 工具数 / 插件扩展点类别 / 云盘驱动数 / 平台数」有变化，同步改
   数据条 `data-count`、工作流与特性卡文案（AI 工具数以 `backend/editor/agent/tools.py`
   中工具定义为准）。
4. **HTML 校验**：改完可用任意 HTML 校验器过一遍，重点看下载区与更新日志区（改动最频繁）。

## 维护注意

- 站点目前被 `.gitignore` 第 59 行的 `website/` 规则忽略，**未纳入版本控制**；如需随仓库管理，先移除该行再 `git add website`。
- Hero 主按钮的平台切换逻辑在 `main.js` 的「平台检测 + Hero 下载按钮」段：它借用下载区里带
  `data-hero="windows|macos|linux|android"` 的链接，因此新增平台时记得给对应首选链接加 `data-hero`。

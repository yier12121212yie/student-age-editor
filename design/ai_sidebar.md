# AI 侧栏功能文档

「学生时代模组编辑器」的 AI 助手:右侧停靠的模组创作助手面板,以及围绕它的外设(MCP 客户端、对外桥接)。面向使用者与二次开发者,内容以代码实况为准,关键处标注源文件(相对仓库根)。

---

## 1. AI 侧栏布局

### 停靠区(AiDock)

桌面端 AI 面板停靠在窗口右侧,由 `frontend/lib/features/shell/ai_dock.dart` 的 `AiDock` 实现,三个桌面壳共用:创作模式壳(`editor_shell.dart`)、经典模式壳(`classic_shell.dart`)、剧情图壳(`story_flow_shell.dart`)。

- **开合**:`ShellState.aiOpen`(默认打开)。选左侧「设置」面板时会自动收起 AI 区,避免双开挤压编辑区。
- **宽度**:`ShellState.aiWidth`,常量定义在 `shell/shell_state.dart`——默认 `defaultAiWidth = 380`,拖拽范围 `minAiWidth = 280` ~ `maxAiWidth = 640`。面板实际占宽 = aiWidth + 5px 拖拽条命中宽(`AiDock.handleWidth`)。
- **拖拽调宽**:面板左缘的 `ResizeHandle`(`shell/shell_widgets.dart`),**双击复位**到默认 380。拖拽经 `aiWidthV` ValueNotifier 只局部重建 AiDock 子树,不触发整壳重绘。
- **收起态折叠条**:收起后右侧保留一条宽 `AiDock.railWidth = 36` 的竖排图标条(`AiCollapsedRail`),点击即展开。图标右上角有小角标:
  - **呼吸点**(accent 色,约 900ms 一次明暗脉动)= AI 正在流式回复;
  - **实心警示点**(黄色)= 有审批/提问弹窗在等你应答(`hasPendingPrompt`,优先于呼吸点显示)。
- **持久化**:开合状态与 AI 宽度(连同左侧栏宽度)以 key `shell_layout_v1` 存入 SharedPreferences,冷启动 `loadLayout()` 恢复;连续拖拽在同一事件轮次内合并落盘一次。

### 应用级会话单例

会话本体不在侧栏里,而在 `ShellState.chatControllerFor()` 返回的**应用级 `AiChatController` 单例**(`frontend/lib/features/ai/ai_chat_controller.dart`)。三个桌面壳、移动端的底部滑出 sheet 与 AI 全屏页(`shell/mobile_shell.dart`)挂的都是同一实例,并通过对话框宿主栈把审批弹窗委托给当前最上层的面板视图。因此:

- 切换布局风格(创作/经典/剧情图)、收起/展开侧栏、移动端 sheet↔全屏,**都不会中断**在途的流式回复与工具审批;
- 流式回复进行中也可以切会话、换视图,在途流按对象引用继续写入其所属会话。

## 2. 会话与输入

### 多会话

- 顶栏「历史对话」打开**滑入浮层**(非整屏替换,聊天列表保活不丢滚动位):按更新时间降序列出全部会话,点击恢复、可逐条删除、可新建,顶部搜索框按标题或内容关键词过滤。
- 会话数上限 **50**(`_maxSessions`):超限时淘汰最久未更新的会话,当前会话永不删。会话标题自动取第一条用户消息前 30 字。
- 持久化 key `ai_sessions_v1` + `ai_active_session_v1`;每会话最多保留 100 条消息 / 300 条结构化历史条目,超长文本截断,图片 base64 不落盘(恢复后显示为「图片附件」占位)。旧版单会话数据启动时自动迁移为第一个历史会话。

### 消息排队(outbox)

AI 回复进行中(busy)时发送键变为「**排队**」:文本输入队列,当前轮结束(完成或出错)后自动依次续发;点停止则不再续发。队列条显示在输入框上方,每条一枚 chip:

- **点 chip 文字** = 提到队首立即发送;**点 ×** = 删除该条;
- 纯附件消息(无文本)不入队,附件仍留在输入框。

### 附件

回形针按钮选文件(可多选),单个文件上限 **10MB**,超出提示并跳过。支持:文档 `docx / txt / md / xlsx`(解析文本拼入消息正文)、图片 `png / jpg / jpeg`(转多模态 image_url)。上传经后端 `/api/ai/upload`,发送前可逐个移除。

### 审批模式

顶栏的权限开关(需已配置 AI 才可用)在两档间切换,随设置持久化:

- **变更前确认**(默认):AI 每次改/建/删条目、改舞台、生图/改图、调用带 `confirm` 标记的插件工具,都先弹审批框展示 diff/预览,拒绝即停止;
- **完全访问**:以上写操作直接执行不再弹窗;但 `ask_user` 提问**仍然会问**(它不是写操作)。

### 模型快捷切换

输入框下方的模型标签点开菜单:**最近使用的模型**(最新在前,上限 8 个,面板切换与设置页修改都会记录)→ 点选即切;**「输入模型名…」**手输;**「AI 设置…」**进设置页。尚未配置 AI 时点标签直接进设置;Web 版平台网关通道下点标签改为打开「通道切换」菜单(模型由服务端决定)。

### 其他输入行为

- `Enter` 发送,`Shift+Enter` 换行,`/` 唤起技能模板(见下);
- 发送前强制校验「已选定模组」并同步前后端当前模组——AI 默认只操作当前模组,不会误改其他模组;
- 生成中断会在原气泡内「重试」续写;向上翻阅自动暂停跟随,出现「回到最新」按钮。

## 3. 技能模板(`/` 唤起)

自定义提示词模板,解析实现见 `frontend/lib/features/ai/ai_skills.dart`:

- 存放位置:模组根目录与工作区根目录各一份 `.editor_skills/*.md`;**模组级与工作区级同名时,模组级覆盖**(按名称去重,结果按名称排序)。
- 文件格式:可选 frontmatter(`---` 围栏内仅识别 `name:` / `description:` 两键,值可带成对引号),其后为正文。
- 回退规则:`name` 缺省取文件名去扩展名;`description` 缺省取正文首个非空行截 60 字;正文为空的文件直接跳过。解析失败静默忽略,目录不存在视为无技能,不报错。
- 使用:输入框输入 `/` 开头且未输空格时弹出联想菜单(按名称/描述过滤,`Esc` 关闭),选中项把**正文填入输入框**,可继续编辑后发送。列表有 30 秒内存缓存,改文件后稍等或重开面板即生效。

## 4. 内置工具

`frontend/lib/features/ai/ai_tools.dart` 的 `kBuiltinTools` 共 **16** 个领域工具(编译期常量,每次请求随消息发送):

| 工具 | 一句话职责 |
|---|---|
| `list_domains` | 列出可修改的创作领域及各领域配置表(domain 参数来源) |
| `get_game_dicts` | 查游戏内置字典(角色/物品/地点等)的 id→名称对照 |
| `list_domain_items` | 按领域(可加关键词/表名)列出条目 |
| `get_domain_item` | 读单个条目完整内容(修改前必读) |
| `update_domain_item` | 按 patch 修改条目字段(先展示 diff 待确认) |
| `create_domain_item` | 新建条目(id 重复报错,需确认) |
| `delete_domain_item` | 删除条目(不可恢复,需确认) |
| `list_files` | 列模组/工作区文件(只读探索) |
| `read_file` | 读模组原始文件(只读;改配置一律走领域工具) |
| `list_mods` | 列出所有模组 |
| `get_stage_dicts` | 查舞台调度字典(表情/动作/站位/角色) |
| `get_talk_stage` | 读某条对白当前人物舞台安排 |
| `set_talk_stage` | 改对白人物舞台(语义指令数组,预览需确认) |
| `generate_image` | OpenAI 协议生图(审批后保存至模组 `Art/ai/`) |
| `edit_image` | OpenAI 协议改图(同上,支持蒙版) |
| `ask_user` | 向用户提问等待回答(完全访问模式同样会问) |

此外两类扩展工具:**插件工具**——启动时从后端 `GET /api/plugins/agent/tools` 拉取,声明 `confirm: true` 的在执行前弹「本机权限风险」审批,执行走 `POST /api/plugins/agent/exec`;**MCP 工具**——见第 6 节。未知工具名按 mcp__ 前缀 → 插件工具顺序兜底路由。

## 5. 提示词与自定义指令

- **系统提示词正文单源**:`frontend/lib/features/ai/ai_prompts.dart` 的 `buildSystemPrompt()`。结构为「角色定位 → 8 步标准操作流程 → 内容条目规则 → 跨类联动 → 修改纪律 → 回答要求」,尾部自动追加**工具参数速查**(由实际发送的工具定义生成,参数不与 schema 漂移)、当前模组范围约束、用户附加指令。关键句式受 `frontend/test/ai_client_test.dart` 断言约束。
- **终端版同步副本**:`native/tui/tui/app.cpp` 的 `kSystemPrompt` 有一份同正文静态拷贝,唯一差异是**无第 6 步生图段**(generate_image/edit_image 为 GUI 专属)。**改正文必须同步该拷贝**。
- **自定义附加指令**:设置页「附加指令」项(`customInstructions`),注入在正文后、参数速查前,标注「优先级低于内置规则」。它属于 AI 设置,与 API Key/模型等一起**写穿三端共享文件 `.editor_ai.json`**(GUI 设置页 ↔ 后端 ↔ CLI/TUI 唯一数据源;Web 端密钥仅存浏览器本地不外发)。

## 6. MCP 客户端(编辑器连别人)

编辑器 AI 可连接外部 MCP 服务器,扩展可用工具。实现:`frontend/lib/features/ai/mcp/`(`mcp_types.dart` 配置模型,`mcp_client.dart` JSON-RPC 客户端与 http 传输,`mcp_stdio_transport.dart` stdio 子进程传输,`mcp_transport_factory*.dart` 按平台条件装配——把依赖 `dart:io` 的 stdio 隔离在 web 编译依赖图之外)。

- 设置页「MCP 服务器」区添加:名称、启用开关、传输二选一——**stdio**(command + args,拉起本地子进程;**桌面端专属**,Android/Web 隐藏该选项)或 **http**(streamable HTTP 端点 URL)。
- 启动与设置变更时自动同步连接(`initialize` 握手 → `tools/list`),连接失败静默摘除,不阻塞聊天;断开/退出时终止子进程不留孤儿。
- 工具命名 **`mcp__<服务器id>__<工具名>`** 做多服务器命名空间隔离(id 经 `sanitizeId` 清洗为 `[A-Za-z0-9_]`);这些工具与内置/插件工具一起发给模型,调用按最长 id 前缀匹配路由回对应服务器。

## 7. MCP 桥接(别人连编辑器)

`tools/mcp_bridge/mcp_bridge.py` 把编辑器模组读写能力经 **MCP 协议(stdio)** 暴露给外部 agent(Claude Code、ZCode 等):agent 的工具调用被翻译成编辑器本地后端 REST 请求(默认 `http://127.0.0.1:8765`,前提后端已在运行)。仅依赖 Python 3 标准库,无需安装。

```bash
python tools/mcp_bridge/mcp_bridge.py                # 只读(默认):仅 9 个查询工具
python tools/mcp_bridge/mcp_bridge.py --allow-write  # 追加 4 个写工具(update/create/delete_domain_item、set_talk_stage)
python tools/mcp_bridge/mcp_bridge.py --backend http://127.0.0.1:9000  # 后端地址,优先级 --backend > 环境变量 EDITOR_BACKEND > 默认
```

要点:**默认只读**——不带 `--allow-write` 时 `tools/list` 只列 9 个只读工具,调用写工具直接报 JSON-RPC 错误、请求不落后端(带上共 13 个)。桥接路径**没有 GUI 审批**,写工具一经调用即落盘,确认环节在 agent 侧;生图/改图与 `ask_user` 不桥接。另有 `--timeout`(单次 REST 超时,默认 30 秒)。Claude Code / ZCode 的 `.mcp.json` 配置示例(stdio 型)见 [tools/mcp_bridge/README.md](../tools/mcp_bridge/README.md),此处不重复。

## 8. 代码地图(二次开发)

`frontend/lib/features/ai/`:

| 文件 | 职责 |
|---|---|
| `ai_chat_controller.dart` | 应用级单例控制器:会话持久化、发送循环与工具循环、排队、附件上传、MCP 连接、停止/重试 |
| `ai_panel.dart` | 面板视图:输入框、历史浮层、审批/提问对话框、技能菜单、模型/权限快捷开关 |
| `ai_client.dart` | 服务商协议层:OpenAI Chat / OpenAI Responses / Anthropic 三协议、Web 平台网关通道、流式 SSE 解析与工具调用拼装 |
| `ai_models.dart` | 纯数据模型:AiAttachment / AiChatMessage / ToolRecord / AiSession 及序列化 |
| `ai_tools.dart` | 16 个内置工具定义(`kBuiltinTools`,改参数描述需与提示词同步)+ PluginAiTool |
| `ai_prompts.dart` | 系统提示词正文、新会话欢迎语、工具参数速查生成(TUI 有同步副本,见第 5 节) |
| `ai_skills.dart` | 技能扫描与解析(`.editor_skills`,见第 3 节) |
| `ai_chat_widgets.dart` | 纯展示组件:消息气泡、Markdown 渲染、工具卡片、历史条目、图片缩略图 |
| `ai_policy.dart` | Web 版双通道策略与网关调用(仅 kIsWeb 消费,桌面不受影响) |
| `tts_panel.dart` | 配音面板(与聊天共用 `.editor_ai.json` 里的 TTS 配置) |
| `mcp/mcp_types.dart` | McpServerConfig:id 清洗、stdio/http 字段 |
| `mcp/mcp_client.dart` | MCP JSON-RPC 客户端 + HttpTransport(streamable) |
| `mcp/mcp_stdio_transport.dart` | StdioTransport:拉起本地子进程(dart:io,桌面/Android) |
| `mcp/mcp_transport_factory*.dart` | 按平台条件导出装配传输;Web 下 stdio 不可用、http 保持报错如实 |

`frontend/lib/features/shell/`:

| 文件 | 职责 |
|---|---|
| `shell_state.dart` | 三壳共享界面状态:`aiOpen`/`aiWidth` 与范围常量、`shell_layout_v1` 持久化、AiChatController 单例持有 |
| `ai_dock.dart` | 右侧停靠区 AiDock 与收起态 36px 折叠条 |
| `shell_widgets.dart` | ResizeHandle(拖拽调宽、双击复位) |
| `editor_shell.dart` / `classic_shell.dart` / `story_flow_shell.dart` | 三个桌面壳,均内嵌 AiDock |
| `mobile_shell.dart` | 移动端壳:AI 底部滑出 sheet ↔ 全屏页,共用同一控制器 |

`tools/mcp_bridge/`:`mcp_bridge.py`(对外桥接)、`test_mcp_bridge.py`(内置 mock 后端的单测,`python tools/mcp_bridge/test_mcp_bridge.py` 直跑)。

# mcp_bridge — 「学生时代」模组编辑器 MCP 桥接

把模组编辑器的模组读写能力经 **MCP 协议**（stdio + 换行分隔 JSON-RPC 2.0）暴露给外部
agent（Claude Code / ZCode 等）：agent 的工具调用被翻译成编辑器本地后端
（C++/HTTP，默认 `http://127.0.0.1:8765`）的 REST 请求。工具定义与前端
`frontend/lib/features/ai/ai_tools.dart` 保持一致（精简版）。

- `mcp_bridge.py` — 桥接服务器，仅依赖 Python 3 标准库（无需 pip 安装任何东西）。
- `test_mcp_bridge.py` — 单元测试（内置 mock 后端，不依赖真实编辑器）：
  `python tools/mcp_bridge/test_mcp_bridge.py`

## 前提

模组编辑器后端必须已在运行（默认 `127.0.0.1:8765`），桥本身不含任何数据。

## 启动方式

```bash
# 只读模式（默认）：仅暴露查询类工具
python tools/mcp_bridge/mcp_bridge.py

# 开放写入：额外暴露 update/create/delete_domain_item、set_talk_stage
python tools/mcp_bridge/mcp_bridge.py --allow-write

# 指定后端地址（优先级：--backend > 环境变量 EDITOR_BACKEND > http://127.0.0.1:8765）
python tools/mcp_bridge/mcp_bridge.py --backend http://127.0.0.1:8765
```

stdout 只输出 JSON-RPC 报文，日志走 stderr。其余参数：`--timeout 秒数`（单次 REST 超时，默认 30）。

## MCP 客户端配置示例

Claude Code（项目根 `.mcp.json`）与 ZCode 等客户端通用，均为 stdio 型：

```json
{
  "mcpServers": {
    "student-age-editor": {
      "command": "python",
      "args": ["D:/workspace/editor/tools/mcp_bridge/mcp_bridge.py"]
    }
  }
}
```

开放写入 + 后端不在默认端口时：

```json
{
  "mcpServers": {
    "student-age-editor": {
      "command": "python",
      "args": [
        "D:/workspace/editor/tools/mcp_bridge/mcp_bridge.py",
        "--allow-write",
        "--backend", "http://127.0.0.1:9000"
      ],
      "env": { "EDITOR_BACKEND": "http://127.0.0.1:9000" }
    }
  }
}
```

命令行 `--backend` 与环境变量 `EDITOR_BACKEND` 二选一即可（命令行优先）。

## 工具清单与读写开关

### 只读工具（默认全部暴露）

| 工具 | 后端 REST |
|---|---|
| `list_domains` | GET `/api/ai/domains` |
| `get_game_dicts` | GET `/api/ai/dicts` |
| `list_domain_items` | GET `/api/ai/domain/items` |
| `get_domain_item` | GET `/api/ai/domain/item` |
| `list_files` | GET `/api/tools/list` |
| `read_file` | GET `/api/tools/read` |
| `list_mods` | GET `/api/mods` |
| `get_stage_dicts` | GET `/api/ai/stage/dicts` |
| `get_talk_stage` | GET `/api/ai/stage/roles` |

### 写工具（默认不暴露，需 `--allow-write`）

| 工具 | 后端 REST |
|---|---|
| `update_domain_item` | PUT `/api/ai/domain/item` |
| `create_domain_item` | POST `/api/ai/domain/item` |
| `delete_domain_item` | DELETE `/api/ai/domain/item`（查询参数） |
| `set_talk_stage` | POST `/api/ai/stage/encode` + PUT `/api/ai/domain/item`（写回 `TalkCfg.roles`） |

语义说明：

- **读写开关**：不带 `--allow-write` 时，`tools/list` 只列出 9 个只读工具，调用写工具会得到
  JSON-RPC 错误（并提示加开关），请求不会打到后端。带上后共 13 个工具。
- **无 GUI 审批**：编辑器前端的「展示改动并等待用户确认」流程在桥接路径上不存在，写工具一经
  调用即直接写入模组——请把确认环节交给外部 agent 侧（提示词/人工审查），或保持默认只读。
- `generate_image` / `edit_image` 需要 GUI 弹窗审批与图片模型配置，桥接中**一律不提供**；
  `ask_user` 属于前端 AI 面板的交互能力，外部 agent 用自己的提问机制，同样不桥接。
- `tools/call` 成功时返回 `{content:[{type:"text",text:<后端 JSON>}],isError:false}`；
  后端非 2xx / 不可达 / 参数缺失时 `isError:true`，text 为状态码与响应体摘要。

## 协议

实现 MCP 2025-03-26 的子集：`initialize`、`notifications/initialized`（忽略）、`ping`、
`tools/list`、`tools/call`；未知方法返回 JSON-RPC 错误 `-32601`，未知通知静默忽略。

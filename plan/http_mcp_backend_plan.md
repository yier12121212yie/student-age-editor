# Web 端 HTTP MCP 与令牌鉴权 — 后端对接简明 Plan

> 前端（设置页「生成令牌」卡片、Agent 配置生成、HTTP MCP 客户端鉴权头）已全部实现，见 [`mcp_token_section.dart`](../frontend/lib/features/settings/mcp_token_section.dart)。后端需完成以下 3 个点的对接：

## 1. 传输层鉴权请求头兼容 (`native/server/httpd.cpp`)
- **改动**：扩展 `token_ok()`，除原有的 `X-Backend-Token` 外，支持解析 `Authorization: Bearer <token>` 请求头与实例令牌比对。
- **CORS**：预检允许头补充 `Authorization, Mcp-Session-Id`，暴露头补充 `Mcp-Session-Id`。

## 2. Streamable HTTP MCP 路由 (`native/server/services/mcp_routes.cpp`)
- **新增端点**：`POST /api/mcp` 与 `GET /api/mcp`（GET 可直接返回 405 或健康状态）。
- **协议方法**（MCP `2025-03-26` JSON-RPC 2.0）：
  - `initialize` / `notifications/initialized`（回 202/204）/ `ping`
  - `tools/list`：默认返回 13 个工具（9 读 + 4 写，对齐 `tools/mcp_bridge/mcp_bridge.py`）；当 URL 带 `?readonly=1` 时只返回 9 个只读工具。
  - `tools/call`：复用现有 C++ 领域服务执行工具；`?readonly=1` 时拦截写工具并返回 JSON-RPC 错误。

## 3. 令牌管理接口与网关路由 (`native/gateway/gw_proxy.cpp`)
前端「生成令牌」卡片调用以下 3 个接口（需当前登录会话鉴权，落盘 `<state_dir>/api_tokens.json` 只存 SHA-256 哈希）：

| 接口 | 请求参数 | 响应结构 |
| --- | --- | --- |
| `GET /api/auth/tokens` | 无 | `{"tokens": [{"id", "label", "masked_token", "created_at", "expires_at", "readonly"}]}` |
| `POST /api/auth/tokens` | `{"label": "Cursor", "expires_in_days": 30, "readonly": false}`（`0` 为永不过期） | `{"id", "token": "sa_mcp_...", "masked_token", "label", "created_at", "expires_at", "readonly"}`（明文 `token` 仅此一次返回） |
| `DELETE /api/auth/tokens/:id` | URL 路径 `:id` | `{"ok": true}` |

- **网关代理 (`gw_proxy.cpp`)**：`bearer_account()` 除校验登录 session 外，支持校验上述生成的长期 API 令牌；若令牌 `readonly == true`，转发 `/api/mcp` 时强制追加 `?readonly=1`。

# -*- coding: utf-8 -*-
"""hello_plugin —— 插件系统完整示例。

演示四类贡献：
1. 路由    GET  /api/plugins/hello_plugin/greet
2. 面板    register_panel("main") + GET panel/main 内容路由 + 表单/动作 POST
3. Agent 工具 hello_plugin__dice（只读）
4. CLI 命令 hello_plugin.greet
"""
import random
import time

# 演示用计数器：模块加载时清零，reload 后重新累计
_greets = 0
_pings = 0
_submits = 0


def setup(ctx):
    # 顺手演示 ctx 上的便利 API：log / plugin_dir / manifest / data_dir
    ctx.log("setup 开始：%s v%s @ %s" % (
        ctx.manifest.get("name"),
        ctx.manifest.get("version") or "?",
        ctx.plugin_dir))
    ctx.log("数据目录（懒创建）：%s" % ctx.data_dir)

    # 面板 stats 用的「启用时间」（插件加载时刻）
    started_at = time.strftime("%Y-%m-%d %H:%M:%S")

    # ---------------------------------------------------------------- 路由
    def greet(query, body):
        global _greets
        _greets += 1
        return 200, {"message": "Hello from hello_plugin！", "query": query}

    ctx.register_route("GET", "greet", greet)

    # ---------------------------------------------------------------- 面板
    def panel_main(query, body):
        blocks = []
        blocks.append({
            "type": "markdown",
            "text": "## 你好！\n\n"
                    "这是 **hello_plugin** 的声明式面板，仅用一个 `panel/main` "
                    "GET 路由返回 `{\"title\", \"blocks\"}` 即可渲染。\n\n"
                    "下方展示了 markdown / stats / table / form / actions 五种块。",
        })
        blocks.append({
            "type": "stats",
            "items": [
                {"label": "启用时间", "value": started_at},
                {"label": "招呼次数", "value": str(_greets)},
                {"label": "Ping 次数", "value": str(_pings)},
                {"label": "提交次数", "value": str(_submits)},
            ],
        })
        blocks.append({
            "type": "table",
            "columns": ["贡献类型", "全名 / 说明"],
            "rows": [
                ["路由", "GET /api/plugins/hello_plugin/greet"],
                ["Agent 工具", "hello_plugin__dice（只读）"],
                ["CLI 命令", "hello_plugin.greet"],
            ],
        })
        blocks.append({
            "type": "form",
            "fields": [
                {"name": "nickname", "label": "昵称", "type": "text",
                 "default": "同学"},
                {"name": "level", "label": "等级", "type": "number",
                 "default": 3},
                {"name": "theme", "label": "主题", "type": "select",
                 "options": ["校园", "科幻", "古代"]},
                {"name": "news", "label": "订阅更新", "type": "checkbox",
                 "default": True},
            ],
            "submit": {"url": "panel/main/hello", "label": "提交"},
        })
        blocks.append({
            "type": "actions",
            "buttons": [
                {"label": "Ping", "url": "panel/main/ping"},
                {"label": "确认动作",
                 "url": "panel/main/confirm_action",
                 "confirm": "确定要执行这个演示动作吗？"},
            ],
        })
        return 200, {"title": "Hello 面板", "blocks": blocks}

    ctx.register_route("GET", "panel/main", panel_main)

    def form_hello(query, body):
        global _submits
        _submits += 1
        msg = "已收到表单：昵称「%s」，等级 %s，主题「%s」，订阅=%s" % (
            body.get("nickname"), body.get("level"),
            body.get("theme"), body.get("news"))
        return 200, {"message": msg, "refresh": False}

    ctx.register_route("POST", "panel/main/hello", form_hello)

    def ping(query, body):
        global _pings
        _pings += 1
        return 200, {"message": "pong！第 %d 次 ping" % _pings, "refresh": False}

    ctx.register_route("POST", "panel/main/ping", ping)

    def confirm_action(query, body):
        return 200, {"message": "已确认并执行示例动作", "refresh": False}

    ctx.register_route("POST", "panel/main/confirm_action", confirm_action)

    ctx.register_panel("main", "Hello 面板", "extension",
                       "演示 markdown / stats / table / form / actions 五种块")

    # ---------------------------------------------------------------- Agent 工具
    def roll(args, confirm):
        # confirm 参数可能为 None（只读/免确认工具），本工具不使用它
        try:
            sides = int(args.get("sides") or 6)
        except (TypeError, ValueError):
            sides = 6
        if sides < 1:
            sides = 1
        return "🎲 掷出 %d（%d 面骰）" % (random.randint(1, sides), sides)

    ctx.register_tool(
        "dice", "掷骰子演示只读工具",
        {"type": "object",
         "properties": {"sides": {"type": "integer",
                                  "description": "骰子面数，默认 6"}}},
        roll, readonly=True,
    )

    # ---------------------------------------------------------------- CLI 命令
    def cmd_greet(args):
        who = (args or "").strip() or "世界"
        print("[hello_plugin] 你好，%s！这条消息来自插件注册的 CLI 命令。" % who)

    ctx.register_command("greet", "打个招呼", cmd_greet)
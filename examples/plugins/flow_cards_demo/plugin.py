# -*- coding: utf-8 -*-
"""流程卡片示例：注册对白卡与选项卡（声明型贡献，无执行体）。

启用后打开「剧情图」模式的流程图：
- 命中 match 的对白/选项自动按卡型着色并加名称后缀；
- 「添加节点」菜单出现对应插件卡片项，新建节点时预置 match 字段。
"""


def setup(ctx):
    # 对白卡：screenEffect 含 4007（打电话）的对白按此卡渲染
    ctx.register_flow_card("phone", {
        "name": "打电话",
        "applies_to": "talk",
        "color": "#3498DB",
        "match": {"field": "screenEffect", "equals": [4007]},
        "body_fields": ["content"],
        "description": "屏幕效果 4007（打电话）模式的对白卡",
    })

    # 选项卡：content 为「表白」的选项按此卡渲染
    ctx.register_flow_card("confess", {
        "name": "告白选项",
        "applies_to": "option",
        "color": "#E91E63",
        "match": {"field": "content", "equals": "表白"},
        "description": "表白类选项卡",
    })

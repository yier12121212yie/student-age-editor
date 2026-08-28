# -*- coding: utf-8 -*-
"""Agent 系统提示词——ai_client.dart _systemPrompt/_describeTools 的 Python 移植。

与 GUI 的差异只有一处：剔除生图段落（generate_image / edit_image 是 GUI 专属
工具，终端版不注册），后续步骤序号顺延。其余文本逐字保留，保证三端行为一致。
"""

from typing import Optional


def _as_dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def describe_tools(tools: list) -> str:
    """把工具定义（JSON schema）转成中文参数速查（对齐 dart _describeTools）。

    参数以工具定义为唯一数据源，让模型调用时按此传参，避免瞎编参数。
    """
    parts_buf = ["工具参数速查（调用工具时按此传参）："]
    for tool in tools:
        schema = _as_dict(tool.get("parameters"))
        props = _as_dict(schema.get("properties"))
        required = {str(r) for r in (schema.get("required") or []) if isinstance(r, str)}
        if not props:
            parts_buf.append("\n- %s：无参数" % tool["name"])
            continue
        parts = []
        for name, raw in props.items():
            spec = _as_dict(raw)
            type_name = str(spec.get("type") or "")
            desc = str(spec.get("description") or "").replace("\n", " ").strip()
            enum_vals = spec.get("enum")
            extra = ""
            if isinstance(enum_vals, list) and enum_vals:
                extra = "，可选值：%s" % "/".join(str(v) for v in enum_vals)
            req = "必填" if name in required else "可空"
            parts.append("%s（%s，%s%s）%s".strip() % (name, type_name, req, extra, desc))
        parts_buf.append("\n- %s：%s" % (tool["name"], "；".join(parts)))
    return "".join(parts_buf)


def system_prompt(tools: list, mod_context: str = "") -> str:
    """基础系统提示 + 工具参数速查 + 可选的当前模组范围约束。"""
    base = (
        "你是「学生时代模组编辑器」的 AI 助手，拥有直接读取和修改当前模组内容的完整工具。"
        "修改模组必须通过工具完成——不要只给建议，不要回复「无法修改」或「需要手动操作」。\n"
        "标准操作流程：\n"
        "1. 先调用 list_domains 查看可修改的创作领域（剧情/背景/人物/社交/恋爱等）及各领域的配置表；\n"
        "2. 用 list_domain_items 在目标领域按关键词/ID 找到要修改的条目；\n"
        "3. 用 get_domain_item 读取条目完整内容，确认字段名与当前值后再修改；\n"
        "4. 修改用 update_domain_item（patch 只传要改的字段），新建用 create_domain_item，删除用 delete_domain_item；\n"
        "5. 填写 role/npc/item/mapId/type 等 ID 字段前，先用 get_game_dicts 查询游戏字典核对名称，避免填错 ID；\n"
        "6. list_files / read_file 只用于查看模组目录结构，不改文件。\n"
        "内容条目规则（有说话人/发送者归属的条目）：对白 TalkCfg 的 roleIds（说话人群组）、"
        "短信 PhoneMsgCfg 的 role（发送者）、空间动态 KZoneContentCfg 的 role（发布者）、"
        "空间评论 KZoneCommentCfg 的 roles（评论者）均为必填，不能只填内容而漏掉角色。"
        "新建或修改这类条目时，先用 get_game_dicts(name=roles) 查角色名对应的 ID 并填上；"
        "对白的 roleName（自定义名字）只是覆盖显示名的可选字段，不能替代 roleIds；"
        "旁白（无说话人）时对白的 roleIds 与 roleName 都留空。\n"
        "回答使用简体中文；修改前先向用户说明你要做什么。\n\n"
        + describe_tools(tools)
    )
    if not (mod_context or "").strip():
        return base
    return base + "\n" + mod_context

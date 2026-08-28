# -*- coding: utf-8 -*-
"""三端共享配置存储（GUI / CLI / TUI）。

两个 JSON 文件都位于 editor 根目录（与 editor_env.json 同级）：
  - ``editor_env.json``  : 环境共享标记（OOBE、workspace_root 等），GUI/CLI/TUI 三端共用
  - ``.editor_ai.json``  : AI 助手（Agent）模型服务配置 —— **唯一数据源**

读写路径约定：
  - GUI（Flutter）：不直接访问文件，经后端 HTTP 端点 ``/api/ai/settings`` GET/PUT；
    请求失败时回退到本地 SharedPreferences 缓存（settings_page.dart）
  - CLI / TUI：直接 import 本模块读写

`.editor_ai.json` 的字段名与 Flutter ``AiSettings.toJson()`` 完全一致
（provider/baseUrl/apiKey/model/temperature/imageModel/imageApiKey/imageBaseUrl），
任一端的修改对其它端立即可见。含 apiKey，属于敏感文件，勿入库。
"""

import json
import os
import sys
import tempfile
from pathlib import Path

# 合法的 Agent 服务协议（与 Flutter 设置页下拉一致）
AI_PROVIDERS = ("openai_compatible", "openai_responses", "anthropic")

DEFAULT_AI_SETTINGS = {
    "provider": "openai_compatible",
    "baseUrl": "",
    "apiKey": "",
    "model": "",
    "temperature": 0.7,
    "imageModel": "",
    "imageApiKey": "",
    "imageBaseUrl": "",
}

# 频控宽松上限；便于校验 GUI/CLI 写入的取值范围
_TEMPERATURE_MIN, _TEMPERATURE_MAX = 0.0, 2.0


def _editor_root() -> Path:
    """应用数据根目录（跨平台，含可写性回退，见 core/paths.py）。

    这里转发 core.paths，与 cli/utils.py 的 editor_root() 保持一致；
    避免 core -> cli 的反向依赖（cli.utils 在函数体内才 import core.game_schema，
    直接引用会造成 core 包在无 cli 场景下的耦合）。
    """
    from editor.core.paths import app_data_dir
    return Path(app_data_dir())


def env_path() -> Path:
    return _editor_root() / "editor_env.json"


def ai_settings_path() -> Path:
    return _editor_root() / ".editor_ai.json"


def read_json(path: Path) -> dict:
    """容错读取 json 文件（utf-8-sig 兼容带 BOM），失败返回 {}。"""
    try:
        text = path.read_text(encoding="utf-8-sig").strip()
        data = json.loads(text) if text else {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def atomic_merge_write(path: Path, extra: dict) -> dict:
    """把 extra 合并进 path 的现有内容后原子替换写回，返回合并结果。

    tmp + os.replace 保证断电/并发下不留半截文件（与 cli/oobe.mark_done、
    cli/utils.save_cfg 同一策略）。"""
    data = read_json(path)
    merged = {**data, **(extra or {})}
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=2)
        os.replace(tmp_name, str(path))
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    return merged


def normalize_ai_settings(data: dict) -> dict:
    """把任意来源（CLI 问询 / HTTP body / 旧版 snake_case）规整为标准字段集。"""
    out = dict(DEFAULT_AI_SETTINGS)
    if not isinstance(data, dict):
        return out
    for key in DEFAULT_AI_SETTINGS:
        val = data.get(key)
        if val is None:
            # 兼容 image_* 与 snake_case 别名（如 base_url -> baseUrl）
            alt = {
                "baseUrl": ("base_url",),
                "apiKey": ("api_key", "apikey"),
                "imageModel": ("image_model",),
                "imageApiKey": ("image_api_key",),
                "imageBaseUrl": ("image_base_url",),
                "temperature": ("temp",),
            }.get(key, ())
            for a in alt:
                if data.get(a) is not None:
                    val = data[a]
                    break
        if isinstance(val, str):
            out[key] = val.strip()
        elif isinstance(val, bool):
            continue  # 无布尔字段，防御性忽略
        else:
            out[key] = val
    if out["provider"] not in AI_PROVIDERS:
        out["provider"] = DEFAULT_AI_SETTINGS["provider"]
    try:
        temp = float(out.get("temperature") or 0.7)
    except (TypeError, ValueError):
        temp = 0.7
    out["temperature"] = round(min(max(temp, _TEMPERATURE_MIN), _TEMPERATURE_MAX), 2)
    # image 字段允许留空（空值语义：复用对话配置），但显式类型归一
    for k in ("imageModel", "imageApiKey", "imageBaseUrl"):
        if not isinstance(out[k], str):
            out[k] = ""
    return out


def is_ai_settings_meaningful(settings: dict) -> bool:
    """配置是否可用于发起对话（有 key 且有 baseUrl/model 至少其一）。"""
    return bool((settings or {}).get("apiKey"))


def read_ai_settings() -> dict:
    """读取并规整 .editor_ai.json；不存在时返回默认模板（ismeaningful=False）。"""
    return normalize_ai_settings(read_json(ai_settings_path()))


def write_ai_settings(patch: dict) -> dict:
    """合并写入 AI 配置（只覆盖给出的字段），返回写盘后的完整规整结果。"""
    current = read_ai_settings()
    merged_raw = {**current, **{k: v for k, v in (patch or {}).items() if v is not None}}
    normalized = normalize_ai_settings(merged_raw)
    atomic_merge_write(ai_settings_path(), normalized)
    return normalized


def merge_editor_env(extra: dict) -> dict:
    """向 editor_env.json 合并写入字段（供需要写环境级键的场景使用）。"""
    return atomic_merge_write(env_path(), extra)


def read_workshop_override() -> str:
    """读取 editor_env.json 中安装包/用户配置的 workshop_root 覆盖值。

    Windows 安装包的「mod 文件夹」页面会写入该键；为空（未配置）时，
    后端与 CLI 回退到注册表 / libraryfolders.vdf 自动发现创意工坊 mods 根。
    """
    val = read_json(env_path()).get("workshop_root")
    return val.strip() if isinstance(val, str) else ""


if __name__ == "__main__":  # 手工调试: python -m editor.core.env_store [json-patch]
    import pprint

    argv = sys.argv[1:]
    if argv:
        patch = json.loads(" ".join(argv))
        pprint.pprint(write_ai_settings(patch))
    else:
        pprint.pprint(read_ai_settings())

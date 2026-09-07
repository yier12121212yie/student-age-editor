# -*- coding: utf-8 -*-
"""波次0 数据资产化：GAME_SCHEMA 与 /api/dicts 导出为 JSON 静态资产。

用法（仓库根目录，任意 cwd，仅标准库 + backend/editor 自身）：
    python tools/export_assets.py

产物（幂等：重复运行输出逐字节一致）：
    native/assets/schema.json  —— editor.core.game_schema.GAME_SCHEMA 原样导出
    native/assets/dicts.json   —— GET /api/dicts 响应体原样导出（CSV 字典等
                                  动态读取结果已烘进 JSON，自包含，C++ 侧
                                  不再需要 csv_dicts/ 目录）

导出 dicts 时在 tools/golden_env.py 的隔离环境里进程内启动后端、真实请求
/api/dicts 取响应，保证与端点返回严格同构（audios/evt_types 依赖
STATE.base 装载状态：干净进程未加载本体 → audios={}，与首启契约一致，
与 golden 录制同一固定方式）。
"""

import json
import os
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOLS_DIR)
BACKEND_DIR = os.path.join(REPO_ROOT, "backend")
ASSETS_DIR = os.path.join(REPO_ROOT, "native", "assets")


def _dump_json(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def export_schema():
    sys.path.insert(0, BACKEND_DIR)
    from editor.core.game_schema import GAME_SCHEMA

    out = os.path.join(ASSETS_DIR, "schema.json")
    _dump_json(out, GAME_SCHEMA)

    total = len(GAME_SCHEMA)
    nonempty = sum(1 for v in GAME_SCHEMA.values() if v)
    cfg_tables = sum(1 for k, v in GAME_SCHEMA.items()
                     if k.endswith("Cfg") and v)
    field_entries = sum(len(v) for v in GAME_SCHEMA.values())

    with open(out, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    assert loaded == json.loads(json.dumps(GAME_SCHEMA)), \
        "schema.json 与 GAME_SCHEMA 不一致"
    assert len(loaded) == total

    print("schema.json: %d 个表名（GAME_SCHEMA 全量原样，含 %d 个空壳 *Define 占位）"
          % (total, total - nonempty))
    print("  - 非空 *Cfg 表: %d 个；全部非空表: %d 个；字段条目合计: %d"
          % (cfg_tables, nonempty, field_entries))
    assert cfg_tables == 303, \
        "期望 303 个非空 *Cfg 表，实际 %d —— schema 漂移，需更新资产与文档" % cfg_tables
    return total, cfg_tables


def export_dicts():
    sys.path.insert(0, TOOLS_DIR)
    from golden_env import start_isolated_server, get_json

    cm, base_url, _info = start_isolated_server()
    try:
        status, body = get_json(base_url, "/api/dicts")
    finally:
        cm.__exit__(None, None, None)

    assert status == 200, "/api/dicts 返回 %s" % status
    out = os.path.join(ASSETS_DIR, "dicts.json")
    _dump_json(out, body)

    # 同构校验：从文件读回 == 端点响应（json 往返无损）
    with open(out, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    assert loaded == json.loads(json.dumps(body)), "dicts.json 与端点响应不一致"

    keys = sorted(body)
    assert keys == ["game_dicts", "key_maps", "story_dicts"], \
        "dicts.json 顶层 key 漂移: %s" % keys
    n_items = len(body["game_dicts"])
    n_keymaps = len(body["key_maps"])
    print("dicts.json: 顶层 key 与 /api/dicts 端点一致: %s"
          % " / ".join("%s(%d)" % (k, len(body[k])) for k in keys))
    print("  - game_dicts 子字典 %d 个；key_maps 表映射 %d 个" % (n_items, n_keymaps))
    for name in ("items", "roles", "attrs", "maps", "bgs", "turns",
                 "evt_types", "audios"):
        print("    %-11s %5d 条" % (name + ":", len(body["game_dicts"][name])))
    return keys


def main():
    os.makedirs(ASSETS_DIR, exist_ok=True)
    export_schema()
    export_dicts()
    print("OK: assets 导出完成 -> %s" % ASSETS_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())

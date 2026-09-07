# -*- coding: utf-8 -*-
"""契约录制/导出的隔离环境（record_golden.py 与 export_assets.py 共用）。

固定方式（侵入最小、不改 backend 一行代码）：
  1. tempfile 建独立目录：<tmp>/data（EDITOR_DATA_ROOT / EDITOR_PLUGINS_ROOT /
     EDITOR_PACKS_ROOT 三个环境变量指向其子目录）与 <tmp>/workspace（Mod 工作区）。
  2. 在 <tmp>/data/editor_env.json 预写 workspace_root=<tmp>/workspace、
     oobe_completed=true —— 后端 _init_state() 会读它决定 STATE.workspace_root，
     因此 STATE 只看见空工作区，绝不触碰真实游戏 Mods（LocalLow）与用户配置。
  3. 预置 editor.core.paths._APP_DATA_DIR_CACHE=<tmp>/data：
     env_store/oobe/realtime 等直接走 app_data_dir() 的模块同样被引到 temp 目录
     （EDITOR_DATA_ROOT 只覆盖 api._editor_root，不覆盖 paths.app_data_dir，
     这是唯一需要内存内补丁的原因；补丁只影响本录制进程）。
  4. 把 editor.core.steam_paths.steam_library_paths 打桩为返回 []，
     user_mods_dir 打桩为固定哨兵路径：创意工坊扫描/游戏安装目录探测按机器不同
     会把本机 Mod 列表与绝对路径泄进 golden，打桩后录制结果跨机器确定。

以上状态全部随进程消失；temp 目录由调用方负责清理（contextmanager 语义见
make_env()，返回 (info, cleanup)）。
"""

import contextlib
import json
import os
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND_DIR = os.path.join(REPO_ROOT, "backend")
CONTRACT_DIR = os.path.join(REPO_ROOT, "native", "tests", "contract")


@contextlib.contextmanager
def make_env():
    """建立隔离环境；yield info dict，退出时删除 temp 目录。

    必须在 import editor.server 之前进入本上下文（模块导入期不读这些路径，
    但 start_server()/build_router() 会，所以调用方先 with 再 import 最稳）。
    """
    sys.path.insert(0, BACKEND_DIR)
    if CONTRACT_DIR not in sys.path:
        sys.path.insert(0, CONTRACT_DIR)

    tmp = tempfile.mkdtemp(prefix="studentage_contract_env_")
    data_root = os.path.join(tmp, "data")
    workspace = os.path.join(tmp, "workspace")
    os.makedirs(data_root)
    os.makedirs(workspace)

    saved_env = {}
    for key, value in (
        ("EDITOR_DATA_ROOT", data_root),
        ("EDITOR_PLUGINS_ROOT", os.path.join(data_root, "plugins")),
        ("EDITOR_PACKS_ROOT", os.path.join(data_root, "resource_packs")),
    ):
        saved_env[key] = os.environ.get(key)
        os.environ[key] = value
    # OOBE 快照（/api/oobe/status 的 forced/disabled 字段）受这两个环境变量影响，
    # 录制进程强制清除，避免宿主 shell 环境污染 golden。
    for key in ("EDITOR_OOBE", "EDITOR_NO_OOBE"):
        saved_env[key] = os.environ.pop(key, None)

    # 录制态视为「已完成 OOBE」的干净用户：工作区指向 temp workspace
    with open(os.path.join(data_root, "editor_env.json"), "w", encoding="utf-8") as f:
        json.dump({"workspace_root": os.path.abspath(workspace),
                   "oobe_completed": True}, f, ensure_ascii=False, indent=2)

    # —— 进程内补丁（仅影响本录制/检查进程） ——
    import editor.core.paths as _paths
    _paths._APP_DATA_DIR_CACHE = data_root

    import editor.core.steam_paths as _steam
    _orig_steam_libs = _steam.steam_library_paths
    _orig_user_mods = _steam.user_mods_dir
    _steam.steam_library_paths = lambda: []
    _steam.user_mods_dir = lambda: os.path.join(tmp, "user_mods")

    try:
        yield {
            "tmp": tmp,
            "data_root": data_root,
            "workspace": workspace,
        }
    finally:
        _steam.steam_library_paths = _orig_steam_libs
        _steam.user_mods_dir = _orig_user_mods
        _paths._APP_DATA_DIR_CACHE = None
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


def start_isolated_server():
    """在隔离环境内起进程内后端，返回 (env_cm, base_url)。

    调用方负责 with env_cm 包住生命周期（退出上下文即关 temp 目录；
    HTTP 线程为 daemon，进程退出自动回收）。
    """
    cm = make_env()
    info = cm.__enter__()
    from editor.server import start_server
    _thread, port = start_server(port=0)
    return cm, "http://127.0.0.1:%d" % port, info


def get_json(base_url, path, timeout=30):
    """GET 一个端点，返回 (status, parsed_body_or_text)。只读，不写盘。"""
    import json as _json
    import urllib.error
    import urllib.request
    req = urllib.request.Request(base_url + path, method="GET",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            try:
                return resp.status, _json.loads(raw)
            except ValueError:
                return resp.status, {"_raw": raw}
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, _json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw}

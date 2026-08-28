# -*- coding: utf-8 -*-
"""跨平台 Steam 库 / 游戏目录 / mods 目录探测（GUI、CLI、TUI 共用）。

原有三份实现（server/api.py、services/unityfs_res.py、cli/utils.py）均只
认 Windows，这里合并为唯一实现：

- Windows: 注册表 SteamPath + Program Files 回退（历史行为不变）
- Linux:   ~/.steam/steam、~/.steam/root、~/.local/share/Steam、
           Flatpak Steam（~/.var/app/com.valvesoftware.Steam/...）
- macOS:   ~/Library/Application Support/Steam

各平台统一解析 libraryfolders.vdf 发现全部 Steam 库；去重用
os.path.normcase（Windows 路径不区分大小写，POSIX 精确去重）。

游戏本体只有 Windows 版：Linux/mac 上经 Steam 安装的同样是 Windows 版
数据文件，因此 Addressables 目录优先 StandaloneWindows64；其余 Unity
平台目录仅作未来游戏出原生版时的兼容。
"""
import os
import sys

from editor.core import paths

GAME_APPID = "1991040"
GAME_DIR_NAME = "StudentAge"
GAME_PUBLISHER = "PakyiGame"

# 游戏 Addressables 平台子目录优先级（取首个存在的）
AA_PLATFORM_DIRS = ("StandaloneWindows64", "StandaloneLinux64", "StandaloneOSX")

_workshop_override_warned = False


def _steam_root_candidates():
    """Steam 安装根目录候选（可能不存在，调用方自行过滤）。"""
    out = []
    if sys.platform == "win32":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                out.append(winreg.QueryValueEx(key, "SteamPath")[0])
        except Exception:
            pass
        for env_name in ("ProgramFiles(x86)", "ProgramFiles"):
            base = os.environ.get(env_name, "")
            if base:
                p = os.path.join(base, "Steam")
                if os.path.isdir(p):
                    out.append(p)
        return out
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        out.append(os.path.join(home, "Library", "Application Support", "Steam"))
        return out
    # Linux（.steam/steam 与 .steam/root 通常是指向真实库的符号链接）
    out.append(os.path.join(home, ".steam", "steam"))
    out.append(os.path.join(home, ".steam", "root"))
    out.append(os.path.join(home, ".local", "share", "Steam"))
    out.append(os.path.join(home, ".var", "app", "com.valvesoftware.Steam",
                            ".local", "share", "Steam"))
    return out


def steam_library_paths():
    """发现本机全部 Steam 库根目录（安装根 + libraryfolders.vdf），去重。"""
    roots = [r for r in _steam_root_candidates() if r and os.path.isdir(r)]
    libs = []
    for sp in roots:
        vdf = os.path.join(sp, "steamapps", "libraryfolders.vdf")
        if not os.path.isfile(vdf):
            vdf = os.path.join(sp, "config", "libraryfolders.vdf")
        if not os.path.isfile(vdf):
            continue
        try:
            with open(vdf, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('"path"'):
                        val = line.split('"')[-2] if line.count('"') >= 4 else ""
                        val = val.replace("\\\\", "\\")
                        if val and os.path.isdir(val):
                            libs.append(val)
        except Exception:
            pass
    out, seen = [], set()
    for lib in libs + roots:
        if not lib or not os.path.isdir(lib):
            continue
        key = os.path.normcase(os.path.normpath(lib))
        if key in seen:
            continue
        seen.add(key)
        out.append(lib)
    return out


def game_install_dirs():
    """全部候选的游戏安装目录 <库>/steamapps/common/StudentAge。"""
    return [os.path.join(lib, "steamapps", "common", GAME_DIR_NAME)
            for lib in steam_library_paths()]


def detect_game_aa_dir():
    """在 Steam 库中查找游戏的 Addressables 根目录，找不到返回空串。"""
    for game_dir in game_install_dirs():
        aa_base = os.path.join(game_dir, GAME_DIR_NAME + "_Data",
                               "StreamingAssets", "aa")
        for plat in AA_PLATFORM_DIRS:
            p = os.path.join(aa_base, plat)
            if os.path.isdir(p):
                return p
    return ""


def proton_mods_dirs():
    """Linux 上游戏经 Proton/Wine 运行时实际可读的 Mods 目录（存在性过滤）。"""
    if sys.platform in ("win32", "darwin"):
        return []
    out = []
    for lib in steam_library_paths():
        p = os.path.join(lib, "steamapps", "compatdata", GAME_APPID, "pfx",
                         "drive_c", "users", "steamuser", "AppData", "LocalLow",
                         GAME_PUBLISHER, GAME_DIR_NAME, "Mods")
        if os.path.isdir(p):
            out.append(p)
    return out


def user_mods_dir():
    """默认本地 Mods 工作区（安装器 / GUI / CLI 共用的初始值）。

    - Windows: 游戏标准存档目录 %USERPROFILE%\\AppData\\LocalLow\\...（历史
      行为；USERPROFILE 缺失时回退 ~，避免得到相对路径）
    - Linux:   Proton 前缀内的游戏 Mods 目录（游戏实际可读）；无 Proton
      数据时回退编辑器 XDG 数据目录下的 Mods
    - macOS:   游戏无原生版，默认给 Application Support 下的等价目录；
      CrossOver/Wine 用户需在界面中手动指向 bottle 内路径
    """
    if sys.platform == "win32":
        base = os.environ.get("USERPROFILE") or os.path.expanduser("~")
        return os.path.abspath(os.path.join(
            base, "AppData", "LocalLow", GAME_PUBLISHER, GAME_DIR_NAME, "Mods"))
    if sys.platform == "darwin":
        return os.path.join(os.path.expanduser("~"), "Library",
                            "Application Support", GAME_PUBLISHER,
                            GAME_DIR_NAME, "Mods")
    proton = proton_mods_dirs()
    if proton:
        return proton[0]
    return os.path.join(paths.platform_data_dir(), "Mods")


def workshop_mods_roots():
    """创意工坊 mods 根目录列表。

    editor_env.json 的 workshop_root（安装包「mod 文件夹」页面写入、用户
    可改）存在且为目录时排在最前；无效配置仅提示一次后忽略，其余仍依赖
    libraryfolders.vdf 自动发现。
    """
    global _workshop_override_warned
    roots = []
    custom = ""
    try:
        from editor.core.env_store import read_workshop_override
        custom = read_workshop_override()
    except Exception:
        pass
    if custom:
        if os.path.isdir(custom):
            roots.append(custom)
        elif not _workshop_override_warned:
            _workshop_override_warned = True
            print("[editor] workshop_root 配置无效（目录不存在），已忽略：%r" % custom,
                  file=sys.stderr)
    for lib in steam_library_paths():
        p = os.path.join(lib, "steamapps", "workshop", "content", GAME_APPID)
        if os.path.isdir(p) and p not in roots:
            roots.append(p)
    out, seen = [], set()
    for r in roots:
        key = os.path.normcase(os.path.normpath(str(r)))
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out

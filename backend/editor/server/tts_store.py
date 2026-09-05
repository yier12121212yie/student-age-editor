# -*- coding: utf-8 -*-
"""配音素材存取（mod 内 audio/tts/）：保存 / 登记 AudioCfg / 列表 / 读取 / 删除。

HTTP 路由（/api/tts/*）、CLI、TUI 三端共用；只依赖 fs_tools 与标准库，
不感知 api.STATE / 配置缓存——调用方传入 mod_root 与 cfg_dir。
"""
import json
import os
import re
import threading
import time

from editor.server import fs_tools
from editor.server import cfg_store
from editor.core import atomic_io
from editor.server.fs_tools import SandboxError

AUDIO_DIR = "audio/tts"
ALLOWED_EXTS = ("wav", "ogg", "mp3", "m4a")

# 并发登记 AudioCfg 的互斥锁：读文件 → 扫 max_id → 写入 必须整体串行，
# 否则多个请求同时保存会扫到同一个 max_id，产生重复 id。
_CFG_LOCK = threading.Lock()


def _check_abs_in_audio_dir(mod_root, abs_path, verb):
    """校验 abs_path 严格落在 <mod>/audio/tts/ 内，防止 .. 折叠后越出子目录。

    fs_tools.resolve 只防逃出 mod 根；audio/tts/../Cfgs/... 这类路径能通过
    沙箱检查，因此这里在拿到绝对路径后再按子目录边界校验一次。
    词法校验拦不住符号链接解析，读/删路径还需配合
    _check_realpath_in_audio_dir 做 realpath 层面的二次校验。
    """
    base = os.path.abspath(os.path.join(str(mod_root), AUDIO_DIR))
    if abs_path != base and not abs_path.startswith(base + os.sep):
        raise TtsStoreError("仅允许%s audio/tts/ 内的素材" % verb)


def _check_realpath_in_audio_dir(mod_root, abs_path, verb):
    """realpath 解析后再校验一次包含关系，防止 mod 内的符号链接把读/删
    指到 audio/tts/ 之外的目录（词法校验对链接解析无能为力）。"""
    base = os.path.realpath(os.path.join(str(mod_root), AUDIO_DIR))
    real = os.path.realpath(abs_path)
    if real != base and not real.startswith(base + os.sep):
        raise TtsStoreError("仅允许%s audio/tts/ 内的素材" % verb)


class TtsStoreError(Exception):
    """素材存取失败。message 面向用户（中文）。"""


def _check_mod_root(mod_root):
    if not mod_root or not os.path.isdir(str(mod_root)):
        raise TtsStoreError("未选择模组或模组目录不存在")


def _safe_key(key):
    """净化素材键名：仅字母数字下划线连字符；缺省按毫秒时间戳生成。

    用毫秒而非秒：同秒内连续两次合成若都缺省键名会得到同一个 key，
    第二次保存会把第一次的音频文件静默覆盖（CLI/TUI 都走此路径）。
    """
    key = (key or "").strip()
    if not key or not re.match(r"^[A-Za-z0-9_\-]+$", key):
        key = "tts_%d" % int(time.time() * 1000)
    return key


def save_audio(mod_root, audio, ext, key=None, ogg=False):
    """把音频字节写入 <mod>/audio/tts/<key>.<ext>，返回保存信息 dict。

    ogg=True 且源为 wav 时，若本机装有 ffmpeg/oggenc 则自动转码为
    Ogg/Vorbis（游戏原生格式，见 AA 包 audios_assets_ogg_*）；无编码器时
    保持 wav 落盘（convertedOgg=False，编辑器内试听不受影响）。
    """
    _check_mod_root(mod_root)
    ext = (ext or "wav").lstrip(".").lower()
    if ext not in ALLOWED_EXTS:
        raise TtsStoreError("不支持的音频格式: %s" % ext)
    if not audio:
        raise TtsStoreError("音频内容为空")
    converted = False
    if ext == "wav" and ogg:
        from editor.server import tts_service
        ogg_bytes = tts_service.encode_ogg(audio)
        if ogg_bytes:
            audio, ext, converted = ogg_bytes, "ogg", True
    key = _safe_key(key)
    rel = "/".join([AUDIO_DIR, "%s.%s" % (key, ext)])
    try:
        abs_path = fs_tools.resolve(str(mod_root), rel)
    except SandboxError as e:
        raise TtsStoreError(str(e))
    try:
        atomic_io.write_bytes_atomic(abs_path, audio)
    except OSError as e:
        raise TtsStoreError("保存音频失败: %s" % e)
    return {"key": key, "path": rel, "ext": ext,
            "convertedOgg": converted, "bytes": len(audio)}


def register_audio_cfg(cfg_dir, key, title=""):
    """在 cfg_dir/AudioCfg.json 登记一行配音（id 取当前最大+1），返回新 id。

    只登记 AudioCfg（url 为 audio/tts/<key>，与落盘路径一致、不带扩展名）；
    素材接入对白用 bind_talk_audio（写 TalkCfg.audio）。
    """
    if not cfg_dir:
        raise TtsStoreError("未选择模组，无法登记 AudioCfg")
    with _CFG_LOCK:
        key = _safe_key(key)
        path = os.path.join(str(cfg_dir), "AudioCfg.json")
        data = {}
        if os.path.isfile(path):
            try:
                with open(path, "r", encoding="utf-8-sig") as f:
                    content = f.read().strip()
                loaded = json.loads(content) if content else {}
                if isinstance(loaded, dict):
                    data = loaded
            except (OSError, ValueError):
                data = {}
        max_id = 0
        for k, rec in data.items():
            if isinstance(rec, dict):
                try:
                    max_id = max(max_id, int(rec.get("id", k)))
                except (TypeError, ValueError):
                    continue
        new_id = max_id + 1
        summary = (title or "").strip() or ("配音 " + key)
        if len(summary) > 24:
            summary = summary[:24]
        # url 与落盘路径 <mod>/audio/tts/<key> 一致、不带扩展名（原版 AudioCfg
        # 的 url 一律不带扩展名；游戏侧对 mod 外置音频的解析待实机验证）。
        data[str(new_id)] = {
            "id": new_id,
            "name": summary,
            "url": AUDIO_DIR + "/" + key,
            "type": 0,
            "volumn": 0,
            "group": [],
            "cond": [],
            "disable": 0,
            "uiType": 0,
        }
        try:
            # 统一写入口：原子写 + 覆盖前留 .editor_history 历史快照
            result = cfg_store.write_cfg(path, data, snapshot=True)
        except OSError as e:
            raise TtsStoreError("登记 AudioCfg 失败: %s" % e)
        if not result.get("ok"):
            raise TtsStoreError("登记 AudioCfg 失败: %s" % (result.get("error") or "未知错误"))
        return new_id


def bind_talk_audio(mod_root, talk_id, audio_cfg_id):
    """把对白的逐句配音通道 TalkCfg.audio 指向已登记的 AudioCfg id。

    引擎语义依据：基表 TalkCfg 的 talk.audio 取值 58/58 均落在 AudioCfg id 上，
    而 TalkCfg.vocals 在引擎二进制中无任何消费点（遗留字段，反序列化被忽略），
    故"配音打通"写 audio 而非 vocals。走 cfg_store 统一写入口，
    覆盖前自动留 .editor_history 历史快照。
    """
    talk_id = str(talk_id)
    candidates = [
        os.path.join(str(mod_root), "Cfgs", "zh-cn", "TalkCfg.json"),
        os.path.join(str(mod_root), "Cfgs", "TalkCfg.json"),
    ]
    path = next((p for p in candidates if os.path.isfile(p)), None)
    if path is None:
        raise TtsStoreError("TalkCfg.json 不存在，无法绑定对白")
    # 表级乐观锁：期望 mtime 必须在读取前取得——若读完再 stat，读取→stat
    # 之间落盘的外部修改会被当成期望值，冲突检测出现漏检窗口
    try:
        expect_mtime_ns = os.stat(path).st_mtime_ns
    except OSError:
        expect_mtime_ns = None
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise TtsStoreError("读取 TalkCfg 失败: %s" % e)
    if not isinstance(data, dict):
        raise TtsStoreError("TalkCfg 结构异常，无法绑定")
    rec = data.get(talk_id)
    if not isinstance(rec, dict):
        raise TtsStoreError("对白 %s 不存在于 TalkCfg" % talk_id)
    rec["audio"] = int(audio_cfg_id)
    result = cfg_store.write_cfg(path, data, snapshot=True,
                                 expect_mtime_ns=expect_mtime_ns)
    if result.get("conflict"):
        raise TtsStoreError("写回 TalkCfg 冲突：文件在读取后已被其他窗口修改（%s），请重试绑定"
                            % (result.get("reason") or "未知原因"))
    if not result.get("ok"):
        raise TtsStoreError("写回 TalkCfg 失败: %s" % (result.get("error") or "未知错误"))
    return {"talkId": talk_id, "audioCfgId": int(audio_cfg_id)}


def list_materials(mod_root):
    """列出 <mod>/audio/tts/ 下的配音素材：[{path, size, ext}]；目录不存在返回 []。"""
    _check_mod_root(mod_root)
    try:
        entries = fs_tools.list_dir(str(mod_root), AUDIO_DIR)
    except SandboxError:
        return []
    items = []
    for e in entries:
        if e.get("type") != "file":
            continue
        name = e.get("name") or ""
        ext = os.path.splitext(name)[1].lstrip(".").lower()
        if ext not in ALLOWED_EXTS:
            continue
        items.append({"path": AUDIO_DIR + "/" + name,
                      "size": e.get("size", 0), "ext": ext})
    return items


def read_audio(mod_root, rel):
    """读回素材字节；越界/非 audio/tts/ 文件抛 TtsStoreError。"""
    _check_mod_root(mod_root)
    rel = (rel or "").replace("\\", "/").strip()
    if not rel.startswith(AUDIO_DIR + "/"):
        raise TtsStoreError("仅允许读取 audio/tts/ 内的素材")
    try:
        abs_path = fs_tools.resolve(str(mod_root), rel)
    except SandboxError as e:
        raise TtsStoreError(str(e))
    _check_abs_in_audio_dir(mod_root, abs_path, "读取")
    if os.path.islink(abs_path):
        raise TtsStoreError("不允许读取符号链接指向的素材")
    _check_realpath_in_audio_dir(mod_root, abs_path, "读取")
    if not os.path.isfile(abs_path):
        raise TtsStoreError("文件不存在: %s" % rel)
    try:
        with open(abs_path, "rb") as f:
            return f.read()
    except OSError as e:
        raise TtsStoreError("读取音频失败: %s" % e)


def delete_material(mod_root, rel):
    """删除素材（仅限 audio/tts/ 目录内），返回被删路径。"""
    _check_mod_root(mod_root)
    rel = (rel or "").replace("\\", "/").strip()
    if not rel.startswith(AUDIO_DIR + "/"):
        raise TtsStoreError("仅允许删除 audio/tts/ 内的素材")
    try:
        abs_path = fs_tools.resolve(str(mod_root), rel)
    except SandboxError as e:
        raise TtsStoreError(str(e))
    _check_abs_in_audio_dir(mod_root, abs_path, "删除")
    if os.path.islink(abs_path):
        raise TtsStoreError("不允许删除符号链接")
    _check_realpath_in_audio_dir(mod_root, abs_path, "删除")
    if not os.path.isfile(abs_path):
        raise TtsStoreError("文件不存在: %s" % rel)
    try:
        os.unlink(abs_path)
    except OSError as e:
        raise TtsStoreError("删除失败: %s" % e)
    return rel
# -*- coding: utf-8 -*-
"""配音（TTS）合成服务：阿里云 DashScope（百炼）、MiniMax T2A V2。

按两家官方 HTTP API 实现，供配音面板 /api/tts/* 调用：
    - MiniMax：POST {base}/v1/t2a_v2?GroupId={groupId}  （Authorization: Bearer）
               音色列表 GET {base}/v1/t2a_v2/voice_list?GroupId=…，失败回退内置常用音色
    - 阿里云：POST https://dashscope.aliyuncs.com/api/v1/services/aigc/
                   multimodal-generation/generation    （Authorization: Bearer sk-*）
              model=qwen-tts / cosyvoice-v1/v2，SSE 流式聚合 output.audio（base64）

统一对外接口（均为纯函数，可被 HTTP 路由 / selftest 直接调用）：
    list_voices(provider, settings) -> (voices, source)
    synthesize(provider, text, voice, settings, params) -> (audio_bytes, ext)
    test_connection(provider, settings, params) -> dict
    encode_ogg(wav_bytes) -> ogg_bytes | None   （依赖系统 ffmpeg/oggenc，缺省返回 None）

本模块不保存音频文件——落盘与登记 AudioCfg 由上层（/api/tts/save）完成，职责单一。
module 不依赖第三方 HTTP 库（标准库 urllib）。
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

PROVIDERS = ("minimax", "aliyun")

DEFAULT_MINIMAX_BASE = "https://api.minimax.chat"
DEFAULT_ALIYUN_URL = ("https://dashscope.aliyuncs.com/api/v1/services/aigc/"
                      "multimodal-generation/generation")
DEFAULT_MODELS = {"minimax": "speech-02-hd", "aliyun": "qwen-tts"}

TIMEOUT_SYNTH = 300    # 合成本身耗时可能较长
TIMEOUT_VOICES = 30
_TIMEOUT_ENCODE = 120


class TtsError(Exception):
    """参数校验或上游调用失败。message 面向用户（中文）。"""


# ---------------------------------------------------------------------------
# 音色内置表（实时拉取失败 / 配置缺失时的兜底）
# ---------------------------------------------------------------------------

_MINIMAX_FALLBACK_VOICES = [
    {"id": "female-shaonv", "name": "清甜少女", "gender": "女"},
    {"id": "female-yujie", "name": "知性御姐", "gender": "女"},
    {"id": "female-chengshu", "name": "温柔成熟女声", "gender": "女"},
    {"id": "male-qn-qingse", "name": "青年男声", "gender": "男"},
    {"id": "male-jingpin", "name": "精品男声", "gender": "男"},
    {"id": "presenter_female", "name": "女播音主持", "gender": "女"},
    {"id": "presenter_male", "name": "男播音主持", "gender": "男"},
    {"id": "audiobook_female_1", "name": "女声图书", "gender": "女"},
    {"id": "audiobook_male_1", "name": "男声图书", "gender": "男"},
]

# qwen-tts 音色（DashScope 百炼，docs 校准的音色表；支持自定义 voice id 手填）
_ALIYUN_QWEN_VOICES = [
    {"id": "Cherry", "name": "Cherry（清新女声）", "gender": "女"},
    {"id": "Serena", "name": "Serena（温柔女声）", "gender": "女"},
    {"id": "Ethan", "name": "Ethan（沉稳男声）", "gender": "男"},
    {"id": "June", "name": "June（活泼女声）", "gender": "女"},
    {"id": "Belle", "name": "Belle（甜美女声）", "gender": "女"},
    {"id": "Hannah", "name": "Hannah（飒爽女声）", "gender": "女"},
    {"id": "Olivia", "name": "Olivia（英文女声）", "gender": "女"},
    {"id": "Peyton", "name": "Peyton（英文男声）", "gender": "男"},
    {"id": "Quinn", "name": "Quinn（英文男声）", "gender": "男"},
    {"id": "Kaitlin", "name": "Kaitlin（英文女声）", "gender": "女"},
    {"id": "Theo", "name": "Theo（英文男声）", "gender": "男"},
    {"id": "Dennis", "name": "Dennis（英文男声）", "gender": "男"},
    {"id": "XiaoYun", "name": "小云（标准女声）", "gender": "女"},
    {"id": "XiaoXia", "name": "小夏（亲切女声）", "gender": "女"},
    {"id": "XiaoGang", "name": "小刚（阳刚男声）", "gender": "男"},
]

# cosyvoice 部分音色（模型为 cosyvoice-v1/v2 时可用；同样支持手填 voice id）
_ALIYUN_COSY_VOICES = [
    {"id": "longxiaochun", "name": "龙小淳（高分女声）", "gender": "女"},
    {"id": "longxiaoxia", "name": "龙小夏（青春女声）", "gender": "女"},
    {"id": "longxiaoyan", "name": "龙小炎（阳光男声）", "gender": "男"},
    {"id": "longjielao", "name": "龙哥（低沉男声）", "gender": "男"},
    {"id": "longshushu", "name": "龙叔叔（中年男声）", "gender": "男"},
    {"id": "longbobo", "name": "龙伯伯（浑厚男声）", "gender": "男"},
]


# ---------------------------------------------------------------------------
# HTTP 工具
# ---------------------------------------------------------------------------

def _extract_error(raw):
    """从上游响应体提取可读错误信息；解析失败返回原文截断。"""
    text = (raw or "").decode("utf-8", "replace").strip()
    if not text:
        return "empty response from upstream"
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            resp = obj.get("base_resp")
            if isinstance(resp, dict):
                msg = resp.get("status_msg") or resp.get("status_message")
                if msg:
                    return "[%s] %s" % (resp.get("status_code", ""), msg)
            err = obj.get("error")
            if isinstance(err, dict):
                msg = err.get("message")
                if msg:
                    return "[" + str(err.get("code", "")) + "] " + msg
            if isinstance(err, str) and err:
                return err
            msg = obj.get("message") or obj.get("resp_message")
            if msg:
                return str(msg)
            if obj.get("code"):
                return "[%s] %s" % (obj.get("code"), msg or obj.get("message") or "")
    except ValueError:
        pass
    return text[:400]


def _post_json(url, data, headers):
    """POST JSON，2xx 返回 (json_obj, None)，否则 (None, 中文错误)。"""
    req = urllib.request.Request(url, data=json.dumps(data).encode("utf-8"),
                                 method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SYNTH) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        return None, "HTTP %s: %s" % (e.code, _extract_error(e.read()))
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", None)
        if isinstance(reason, socket.timeout):
            return None, "请求配音服务超时（%s 秒）" % TIMEOUT_SYNTH
        return None, "无法连接配音服务：%s" % reason
    except socket.timeout:
        return None, "请求配音服务超时（%s 秒）" % TIMEOUT_SYNTH
    except Exception as e:  # noqa: BLE001
        return None, "请求配音服务失败：%s" % e
    try:
        return json.loads(raw.decode("utf-8")), None
    except ValueError:
        return None, "配音服务返回了非 JSON 内容：%s" % raw[:200]


def _get_json(url, headers, timeout):
    """GET JSON（用于音色列表等轻量请求）。"""
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        return None, "HTTP %s: %s" % (e.code, _extract_error(e.read()))
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", None)
        if isinstance(reason, socket.timeout):
            return None, "请求配音服务超时（%s 秒）" % timeout
        return None, "无法连接配音服务：%s" % reason
    except socket.timeout:
        return None, "请求配音服务超时（%s 秒）" % timeout
    except Exception as e:  # noqa: BLE001
        return None, "请求配音服务失败：%s" % e
    try:
        return json.loads(raw.decode("utf-8")), None
    except ValueError:
        return None, "配音服务返回了非 JSON 内容：%s" % raw[:200]


# ---------------------------------------------------------------------------
# 音色列表
# ---------------------------------------------------------------------------

def _minimax_base(settings=None):
    """MiniMax Base URL 归一：去掉尾部 /v1，避免再拼出 /v1/v1。

    用户按文档常把 Base URL 填成 https://api.minimax.chat/v1，而接口
    路径本身带 /v1（/v1/t2a_v2），直接拼接会得到 /v1/v1/... 上游 404。
    """
    base = ((settings or {}).get("ttsBaseUrl") or DEFAULT_MINIMAX_BASE).strip()
    base = base.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]
    return base


def list_voices(provider, settings=None):
    """返回 (voices, source)。source 为 live（实时拉取）/ preset（内置兜底）。"""
    provider = (provider or "").strip().lower()
    settings = settings if isinstance(settings, dict) else {}
    if provider == "minimax":
        voices, err = _minimax_voice_list(settings)
        if voices is not None:
            return voices, "live"
        return list(_MINIMAX_FALLBACK_VOICES), "preset"
    if provider == "aliyun":
        model = (settings.get("ttsModel") or DEFAULT_MODELS["aliyun"]).strip().lower()
        table = (_ALIYUN_COSY_VOICES if model.startswith("cosyvoice")
                 else _ALIYUN_QWEN_VOICES)
        return list(table), "preset"
    raise TtsError("不支持的配音服务商: %r" % (provider,))


def _minimax_voice_list(settings=None):
    """实时拉取 MiniMax 音色列表；网络/配置失败返回 (None, 中文错误)。"""
    settings = settings if isinstance(settings, dict) else {}
    key = (settings.get("ttsApiKey") or "").strip()
    group = (settings.get("ttsGroupId") or "").strip()
    if not key or not group:
        return None, "缺少 MiniMax API Key 或 GroupId"
    base = _minimax_base(settings)
    url = "%s/v1/t2a_v2/voice_list?GroupId=%s" % (base, urllib.parse.quote(group))
    headers = {"Authorization": "Bearer " + key}
    obj, err = _get_json(url, headers, TIMEOUT_VOICES)
    if err:
        return None, err
    data = (obj or {}).get("data") or {}
    voices = []
    for v in data.get("voice_list") or []:
        item = _minimax_voice_item(v)
        if item:
            voices.append(item)
    for v in data.get("custom_voice_list") or []:
        item = _minimax_voice_item(v)
        if item:
            item["desc"] = "自定义音色：" + (item.get("desc") or "")
            voices.append(item)
    if not voices:
        return None, "语音列表为空（上游返回 %s）" % json.dumps(obj, ensure_ascii=False)[:200]
    return voices, None


def _minimax_voice_item(v):
    if not isinstance(v, dict):
        return None
    vid = v.get("voice_id")
    if not vid:
        return None
    gender = v.get("gender")
    if isinstance(gender, bool):
        gender = ""
    elif isinstance(gender, (int, float)):
        # 部分接口用 0/1 表示性别；只透传字符串可读值
        gender = {0: "女", 1: "男"}.get(int(gender), "")
    else:
        gender = gender or ""
    return {
        "id": str(vid),
        "name": v.get("name") or str(vid),
        "gender": gender or "",
        "desc": v.get("desc") or "",
    }


# ---------------------------------------------------------------------------
# 合成
# ---------------------------------------------------------------------------

def synthesize(provider, text, voice=None, settings=None, params=None):
    """合成语音。返回 (audio_bytes, ext)；参数/上游错误抛 TtsError。"""
    text = (text or "").strip()
    if not text:
        raise TtsError("配音文本不能为空")
    provider = (provider or "").strip().lower()
    # 入参防御：非 dict（如字符串/列表）的 settings/params 直接当空处理，
    # 避免 .get() 抛 AttributeError 泄漏为 500
    settings = settings if isinstance(settings, dict) else {}
    params = params if isinstance(params, dict) else {}
    if provider not in PROVIDERS:
        raise TtsError("不支持的配音服务商: %r" % (provider,))
    key = (settings.get("ttsApiKey") or "").strip()
    if not key:
        raise TtsError("未配置 %s 的 API Key（设置页 → 配音）"
                       % ("MiniMax" if provider == "minimax" else "阿里云"))
    if provider == "minimax":
        return _synthesize_minimax(text, voice, settings, params)
    return _synthesize_aliyun(text, voice, settings, params)


def _synthesize_minimax(text, voice, settings, params):
    key = (settings.get("ttsApiKey") or "").strip()
    group = (settings.get("ttsGroupId") or "").strip()
    if not group:
        raise TtsError("未配置 MiniMax GroupId（设置页 → 配音）")
    base = _minimax_base(settings)
    url = "%s/v1/t2a_v2?GroupId=%s" % (base, urllib.parse.quote(group))
    headers = {"Authorization": "Bearer " + key, "Content-Type": "application/json"}
    voice = (voice or "").strip() or (settings.get("ttsVoice") or "").strip()
    model = (params.get("model") or settings.get("ttsModel") or "").strip() \
        or DEFAULT_MODELS["minimax"]
    speed = _float_param(params.get("speed"), settings.get("ttsSpeed"), 1.0, 0.5, 2.0)
    vol = _float_param(params.get("vol"), settings.get("ttsVolume"), 1.0, 0.5, 2.0)
    pitch = _int_param(params.get("pitch"), settings.get("ttsPitch"), 0, -12, 12)
    body = {
        "model": model,
        "text": text,
        "stream": False,
        "voice_setting": {
            "voice_id": voice or "female-shaonv",
            "speed": speed,
            "vol": vol,
            "pitch": pitch,
        },
        "audio_setting": {
            "sample_rate": 32000,
            "format": "wav",
            "channel": 1,
        },
    }
    obj, err = _post_json(url, body, headers)
    if err:
        raise TtsError("MiniMax 合成失败：%s" % err)
    resp = (obj or {}).get("base_resp") or {}
    code = resp.get("status_code")
    if code not in (0, None):
        raise TtsError("MiniMax 合成失败：%s" %
                       (resp.get("status_msg") or json.dumps(resp, ensure_ascii=False)[:200]))
    audio = ((obj or {}).get("data") or {}).get("audio")
    if not audio:
        raise TtsError("MiniMax 返回为空：%s" % json.dumps(obj, ensure_ascii=False)[:300])
    return base64.b64decode(audio), "wav"


def _synthesize_aliyun(text, voice, settings, params):
    key = (settings.get("ttsApiKey") or "").strip()
    url = (settings.get("ttsBaseUrl") or DEFAULT_ALIYUN_URL).strip()
    model = (params.get("model") or settings.get("ttsModel") or "").strip() \
        or DEFAULT_MODELS["aliyun"]
    voice = (voice or "").strip() or (settings.get("ttsVoice") or "").strip() \
        or "Cherry"
    body = {
        "model": model,
        "input": {"text": text, "voice": voice},
    }
    headers = {"Authorization": "Bearer " + key, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                 method="POST", headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=TIMEOUT_SYNTH)
    except urllib.error.HTTPError as e:
        raise TtsError("阿里云 TTS 请求失败：HTTP %s %s" % (e.code, _extract_error(e.read())))
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", None)
        if isinstance(reason, socket.timeout):
            raise TtsError("请求阿里云 TTS 超时（%s 秒）" % TIMEOUT_SYNTH)
        raise TtsError("无法连接阿里云 TTS：%s" % reason)
    except socket.timeout:
        raise TtsError("请求阿里云 TTS 超时（%s 秒）" % TIMEOUT_SYNTH)
    except Exception as e:  # noqa: BLE001
        raise TtsError("请求阿里云 TTS 失败：%s" % e)
    try:
        chunks = []
        try:
            for raw_line in resp:
                line = raw_line.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[len("data:"):].strip()
                if not payload or payload == "[DONE]":
                    continue
                try:
                    ev = json.loads(payload)
                except ValueError:
                    continue
                if not isinstance(ev, dict):
                    continue
                if ev.get("result") == "failed" or ev.get("error"):
                    raise TtsError("阿里云 TTS 合成失败：%s"
                                   % json.dumps(ev, ensure_ascii=False)[:200])
                out = ev.get("output")
                if isinstance(out, dict):
                    audio = out.get("audio") or out.get("audio_frame")
                    if audio:
                        chunks.append(audio)
        finally:
            resp.close()
        if not chunks:
            raise TtsError("阿里云 TTS 未返回音频数据（请检查 model/voice 是否有效）")
        # 每个分块自带 base64 填充符，直接拼接会让解码在首个 '=' 处截断，
        # 因此逐块独立解码后拼接字节。
        try:
            audio = b"".join(base64.b64decode(c) for c in chunks)
        except Exception as e:  # noqa: BLE001
            raise TtsError("阿里云 TTS 音频解码失败：%s" % e)
        return audio, "wav"
    except TtsError:
        raise
    except Exception as e:  # noqa: BLE001
        raise TtsError("解析阿里云 TTS 响应失败：%s" % e)


# ---------------------------------------------------------------------------
# 连接测试
# ---------------------------------------------------------------------------

def test_connection(provider, settings=None, params=None):
    """连通性测试：MiniMax 拉一次音色列表；阿里云合成一句短文本后丢弃。"""
    provider = (provider or "").strip().lower()
    settings = settings if isinstance(settings, dict) else {}
    params = params if isinstance(params, dict) else {}
    try:
        if provider == "minimax":
            voices, err = _minimax_voice_list(settings)
            if err:
                return {"ok": False, "error": err}
            return {"ok": True, "detail": "连接成功，共 %d 个音色" % len(voices)}
        if provider == "aliyun":
            _bytes, ext = synthesize("aliyun", "你好，我是测试语音。", None, settings, params)
            return {"ok": True, "detail": "连接成功，合成 %dB %s" % (len(_bytes), ext)}
        return {"ok": False, "error": "不支持的配音服务商: %r" % (provider,)}
    except TtsError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}


# ---------------------------------------------------------------------------
# 参数归一工具
# ---------------------------------------------------------------------------

def _float_param(val, fallback, default, lo, hi):
    """取值：params 优先，其次 settings，再默认值；非法时用默认值并夹取。"""
    if val is None:
        val = fallback
    try:
        f = float(val)
    except (TypeError, ValueError):
        f = default
    return round(min(max(f, lo), hi), 2)


def _int_param(val, fallback, default, lo, hi):
    if val is None:
        val = fallback
    try:
        f = int(val)
    except (TypeError, ValueError):
        f = default
    return min(max(f, lo), hi)


# ---------------------------------------------------------------------------
# Ogg Vorbis 编码器探测（游戏原生音频为 ogg，见 AA 包 audios_assets_ogg_*）
# ---------------------------------------------------------------------------

_encoder_cache = None


def detect_encoder():
    """探测可用的 wav→ogg 编码器：ffmpeg > oggenc；均无返回空串。

    只缓存「找到编码器」的结果：探测未命中很廉价（shutil.which），
    缓存空结果会让运行中才装上编码器、或被 mock 的调用永久失效。"""
    global _encoder_cache
    if _encoder_cache:
        return _encoder_cache
    found = ""
    if shutil.which("ffmpeg"):
        found = "ffmpeg"
    elif shutil.which("oggenc"):
        found = "oggenc"
    if found:
        _encoder_cache = found
    return found


def encode_ogg(wav_bytes):
    """把 WAV 字节转码为 Ogg Vorbis；无可用编码器或转码失败返回 None。"""
    if not wav_bytes:
        return None
    enc = detect_encoder()
    if enc == "ffmpeg":
        cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
               "-i", "-", "-c:a", "libvorbis", "-q:a", "5", "-f", "ogg", "-"]
        try:
            proc = subprocess.run(cmd, input=wav_bytes, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=_TIMEOUT_ENCODE)
        except Exception:
            return None
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout
        return None
    if enc == "oggenc":
        fd, tmp = tempfile.mkstemp(suffix=".wav")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(wav_bytes)
            try:
                proc = subprocess.run(["oggenc", "-Q", "-o", "-", tmp],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      timeout=_TIMEOUT_ENCODE)
            except Exception:
                return None
            if proc.returncode == 0 and proc.stdout:
                return proc.stdout
            return None
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return None
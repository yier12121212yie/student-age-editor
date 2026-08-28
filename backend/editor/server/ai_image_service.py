# -*- coding: utf-8 -*-
"""OpenAI Images API（openai-image-api 标准）生图 / 改图服务。

按 OpenAI 官方 Images API 规范实现，供 AI 侧栏工具（generate_image / edit_image）调用：
    - 生图：POST {base}/images/generations
      body: model, prompt, n, size, quality, style, background, response_format=b64_json
    - 改图：POST {base}/images/edits（multipart/form-data）
      fields: model, prompt, n, size;  files: image, mask（可选）
    - response_format 优先 b64_json；网关只返回 url 时自动下载转 base64。

模块不依赖第三方 HTTP 库（标准库 urllib），可被 HTTP 路由 / selftest 直接调用。
本模块不负责保存图片——保存到模组由上层（/api/tools/write）完成，职责单一。
"""
import base64
import json
import re
import socket
import uuid
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE_URL = "https://api.openai.com/v1"
DEFAULT_MODEL = "gpt-image-2"
TIMEOUT_SECONDS = 300  # 生图可能较慢，给足超时

# dall-e 系列尺寸枚举（严格校验）；gpt-image 系列（gpt-image-1/2/…）为
# 任意「宽x高」且宽高为 64 的整数倍（1–8192），并额外支持 auto。
_DALLE_SIZES = {"256x256", "512x512", "1024x1024", "1024x1792", "1792x1024"}
_SUPPORTED_QUALITY = {"low", "medium", "high", "auto"}
_SUPPORTED_STYLE = {"vivid", "natural"}
_SUPPORTED_BACKGROUND = {"transparent", "opaque", "auto"}


def _is_valid_size(model, size):
    """尺寸合法性：gpt-image 系列放宽（NxM、64 的倍数、≤8192），其余按 dall-e 枚举。"""
    if not size or size == "auto":
        return True
    m = re.match(r"^(\d{2,5})x(\d{2,5})$", size.strip())
    if not m:
        return False
    w, h = int(m.group(1)), int(m.group(2))
    if (model or "").startswith("gpt-image"):
        return 1 <= w <= 8192 and 1 <= h <= 8192 and w % 64 == 0 and h % 64 == 0
    return size in _DALLE_SIZES


class ImageGenError(Exception):
    """参数校验或上游调用失败。message 面向用户（中文）。"""


def _normalize_base_url(base_url):
    base = (base_url or "").strip().rstrip("/")
    if not base:
        base = DEFAULT_BASE_URL
    # 兼容用户只填域名（https://api.openai.com）或已带 /v1 的情况
    if not base.startswith("http://") and not base.startswith("https://"):
        base = "https://" + base
    return base


def _extract_error(raw):
    """从上游响应体提取可读错误信息；解析失败返回原文截断。"""
    text = (raw or "").decode("utf-8", "replace").strip()
    if not text:
        return "empty response from upstream"
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            err = obj.get("error")
            if isinstance(err, dict):
                msg = err.get("message")
                if msg:
                    return str(msg)
            if isinstance(err, str) and err:
                return err
            code = obj.get("code")
            if code:
                return "[%s] %s" % (code, obj.get("message", ""))
            msg = obj.get("message")
            if msg:
                return str(msg)
    except ValueError:
        pass
    return text[:400]


def _request(url, data, headers, method="POST"):
    """发送请求；2xx 返回 (json_obj, None)，否则 (None, 中文错误)。"""
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        detail = _extract_error(e.read())
        return None, "HTTP %s: %s" % (e.code, detail)
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", None)
        if isinstance(reason, socket.timeout):
            return None, "请求图片服务超时（%s 秒）" % TIMEOUT_SECONDS
        return None, "无法连接图片服务：%s" % reason
    except socket.timeout:
        return None, "请求图片服务超时（%s 秒）" % TIMEOUT_SECONDS
    except Exception as e:  # noqa: BLE001
        return None, "请求图片服务失败：%s" % e
    try:
        return json.loads(raw.decode("utf-8")), None
    except ValueError:
        return None, "图片服务返回了非 JSON 内容：%s" % raw[:200]


def _validate_common(model, prompt, n, size, quality, style, background):
    if not (prompt or "").strip():
        raise ImageGenError("prompt（图片描述/修改指令）不能为空")
    try:
        n = int(n) if n is not None else 1
    except (TypeError, ValueError):
        raise ImageGenError("n（生成数量）必须是整数")
    n = max(1, min(n, 10))
    model = (model or "").strip() or DEFAULT_MODEL
    if not _is_valid_size(model, size):
        if model.startswith("gpt-image"):
            raise ImageGenError(
                "不支持的 size：%s（gpt-image 系列支持「宽x高」且宽高为 64 的整数倍、不超过 8192，或 auto）" % size)
        raise ImageGenError("不支持的 size：%s（可选：%s）" % (
            size, " / ".join(sorted(_DALLE_SIZES))))
    if quality and quality not in _SUPPORTED_QUALITY:
        raise ImageGenError("不支持的 quality：%s（可选：%s）" % (
            quality, " / ".join(sorted(_SUPPORTED_QUALITY))))
    if style and style not in _SUPPORTED_STYLE:
        raise ImageGenError("不支持的 style：%s（可选：%s）" % (
            style, " / ".join(sorted(_SUPPORTED_STYLE))))
    if background and background not in _SUPPORTED_BACKGROUND:
        raise ImageGenError("不支持的 background：%s（可选：%s）" % (
            background, " / ".join(sorted(_SUPPORTED_BACKGROUND))))
    return {
        "model": model,
        "prompt": prompt.strip(),
        "n": n,
        "size": size,
        "quality": quality,
        "style": style,
        "background": background,
    }


def _resolve_images(data, api_key):
    """把上游返回的 data[] 统一为 [{b64, mime}]：b64_json 直取，url 下载转 base64。"""
    items = data if isinstance(data, list) else []
    out = []
    for it in items:
        if not isinstance(it, dict):
            continue
        b64 = it.get("b64_json")
        if isinstance(b64, str) and b64:
            out.append({"b64": b64, "mime": "image/png"})
            continue
        url = it.get("url")
        if isinstance(url, str) and url:
            b64, mime = _download_to_b64(url, api_key)
            out.append({"b64": b64, "mime": mime})
    return out


def _download_to_b64(url, api_key):
    """下载 url 图片转 base64（带 Authorization，兼容需鉴权的网关）。"""
    headers = {"Authorization": "Bearer %s" % api_key} if api_key else {}
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
    except Exception as e:  # noqa: BLE001
        raise ImageGenError("下载生成图片失败：%s" % e)
    ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip().lower()
    mime = ctype if ctype.startswith("image/") else "image/png"
    return base64.b64encode(raw).decode("ascii"), mime


# ---------------------------------------------------------------------------
# 对外接口
# ---------------------------------------------------------------------------

def generate_images(api_key="", base_url="", model=None, prompt="", n=1,
                    size=None, quality=None, style=None, background=None):
    """标准生图：POST {base}/images/generations。

    返回 {"images": [{b64, mime}], "model": ..., "created": ...}
    """
    if not (api_key or "").strip():
        raise ImageGenError("未配置图片生成 API Key，请先在「设置」中配置")
    p = _validate_common(model, prompt, n, size, quality, style, background)
    base = _normalize_base_url(base_url)
    body = {
        "model": p["model"],
        "prompt": p["prompt"],
        "n": p["n"],
        "response_format": "b64_json",
    }
    for k in ("size", "quality", "style", "background"):
        if p[k]:
            body[k] = p[k]
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer %s" % api_key.strip(),
    }
    data = json.dumps(body).encode("utf-8")
    resp, err = _request("%s/images/generations" % base, data, headers)
    if err:
        raise ImageGenError(err)
    images = _resolve_images(resp.get("data") if isinstance(resp, dict) else None,
                             api_key)
    if not images:
        raise ImageGenError("图片服务未返回任何图片：%s" % json.dumps(resp, ensure_ascii=False)[:300])
    return {
        "images": images,
        "model": (resp.get("model") or p["model"]) if isinstance(resp, dict) else p["model"],
        "created": resp.get("created") if isinstance(resp, dict) else None,
    }


def edit_image(api_key="", base_url="", model=None, prompt="",
               image_b64=None, image_mime="image/png",
               mask_b64=None, n=1, size=None):
    """标准改图：POST {base}/images/edits（multipart）。

    参数 image_b64 / mask_b64 为图片原始字节的 base64（PNG 最佳）。
    返回 {"images": [{b64, mime}], "model": ..., "created": ...}
    """
    if not (api_key or "").strip():
        raise ImageGenError("未配置图片生成 API Key，请先在「设置」中配置")
    p = _validate_common(model, prompt, n, size, None, None, None)
    if not image_b64:
        raise ImageGenError("image（要修改的图片）不能为空")
    try:
        image_bytes = base64.b64decode(image_b64)
    except Exception:
        raise ImageGenError("image 不是合法的 base64 图片数据")
    if not image_bytes:
        raise ImageGenError("image 内容为空")
    mime = (image_mime or "image/png").strip().lower()
    if not mime.startswith("image/"):
        mime = "image/png"

    mask_bytes = None
    if mask_b64:
        try:
            mask_bytes = base64.b64decode(mask_b64)
        except Exception:
            raise ImageGenError("mask 不是合法的 base64 图片数据")

    base = _normalize_base_url(base_url)
    fields = [
        ("model", p["model"]),
        ("prompt", p["prompt"]),
        ("n", str(p["n"])),
    ]
    if p["size"]:
        fields.append(("size", p["size"]))
    files = [("image", "image.png", mime, image_bytes)]
    if mask_bytes:
        files.append(("mask", "mask.png", "image/png", mask_bytes))

    boundary = "----studentage_aiedit_%s" % uuid.uuid4().hex
    body, content_type = _build_multipart(boundary, fields, files)
    headers = {
        "Content-Type": content_type,
        "Authorization": "Bearer %s" % api_key.strip(),
    }
    resp, err = _request("%s/images/edits" % base, body, headers)
    if err:
        raise ImageGenError(err)
    images = _resolve_images(resp.get("data") if isinstance(resp, dict) else None,
                             api_key)
    if not images:
        raise ImageGenError("图片服务未返回任何图片：%s" % json.dumps(resp, ensure_ascii=False)[:300])
    return {
        "images": images,
        "model": (resp.get("model") or p["model"]) if isinstance(resp, dict) else p["model"],
        "created": resp.get("created") if isinstance(resp, dict) else None,
    }


def _build_multipart(boundary, fields, files):
    """构造 multipart/form-data 请求体。fields=[(name, value)]，files=[(name, filename, mime, bytes)]。"""
    chunks = []
    for name, value in fields:
        chunks.append(b"--" + boundary.encode("utf-8") + b"\r\n")
        chunks.append(('Content-Disposition: form-data; name="%s"\r\n\r\n'
                       % name).encode("utf-8"))
        chunks.append(str(value).encode("utf-8") + b"\r\n")
    for name, filename, mime, raw in files:
        chunks.append(b"--" + boundary.encode("utf-8") + b"\r\n")
        chunks.append(('Content-Disposition: form-data; name="%s"; filename="%s"\r\n'
                       % (name, filename)).encode("utf-8"))
        chunks.append(("Content-Type: %s\r\n\r\n" % mime).encode("utf-8"))
        chunks.append(raw + b"\r\n")
    chunks.append(b"--" + boundary.encode("utf-8") + b"--\r\n")
    return b"".join(chunks), "multipart/form-data; boundary=%s" % boundary

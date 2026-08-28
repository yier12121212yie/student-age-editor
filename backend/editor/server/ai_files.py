# -*- coding: utf-8 -*-
"""AI 侧栏附件解析：docx/txt/md/xlsx → 提取文本；png/jpg → 魔数校验 + base64。

零第三方依赖：zipfile + xml.etree.ElementTree（标准库）。
供 api.py 的 POST /api/ai/upload 调用。
"""
import base64
import io
import re
import zipfile
import xml.etree.ElementTree as ET

MAX_FILE_BYTES = 10 * 1024 * 1024   # 单文件上限 10MB
MAX_TEXT_CHARS = 200000             # 提取文本上限（字符）
MAX_XML_BYTES = 50 * 1024 * 1024    # zip 内单个 XML 解压上限

W_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
S_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
R_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
P_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"

TEXT_EXTS = ("txt", "md", "docx", "xlsx")
IMAGE_EXTS = ("png", "jpg", "jpeg")

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPG_MAGIC = b"\xff\xd8\xff"


class UploadError(Exception):
    """上传/解析失败（message 直接展示给用户）。"""


def _ext(name):
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def _check_magic(raw, ext):
    if ext == "png" and not raw.startswith(PNG_MAGIC):
        raise UploadError("文件不是有效的 PNG 图片")
    if ext in ("jpg", "jpeg") and not raw.startswith(JPG_MAGIC):
        raise UploadError("文件不是有效的 JPG 图片")


def parse_file(name, raw):
    """解析上传文件，返回统一结果 dict。

    text 类：{"kind": "text", "name", "size", "text", "truncated"}
    image 类：{"kind": "image", "name", "size", "mime", "data"}（data 为 base64）
    """
    ext = _ext(name)
    if ext in TEXT_EXTS:
        text, truncated = _text_of(ext, raw)
        return {"kind": "text", "name": name, "size": len(raw),
                "text": text, "truncated": truncated}
    if ext in IMAGE_EXTS:
        _check_magic(raw, ext)
        mime = "image/png" if ext == "png" else "image/jpeg"
        return {"kind": "image", "name": name, "size": len(raw),
                "mime": mime, "data": base64.b64encode(raw).decode("ascii")}
    raise UploadError("不支持的文件类型：%s（支持 docx / txt / md / xlsx / png / jpg）"
                      % (ext or "无扩展名"))


def _text_of(ext, raw):
    if ext in ("txt", "md"):
        text = raw.decode("utf-8", errors="replace")
        if text.startswith("\ufeff"):
            text = text[1:]
    elif ext == "docx":
        text = _docx_text(raw)
    elif ext == "xlsx":
        text = _xlsx_text(raw)
    else:
        text = ""
    truncated = len(text) > MAX_TEXT_CHARS
    return text[:MAX_TEXT_CHARS], truncated


def _read_limited(zf, name):
    """读取 zip 内条目，限制解压大小防 zip 炸弹。"""
    try:
        info = zf.getinfo(name)
    except KeyError:
        raise UploadError("压缩包内缺少文件：%s" % name)
    if info.file_size > MAX_XML_BYTES:
        raise UploadError("压缩包内文件过大（%.1fMB）" % (info.file_size / 1048576.0))
    return zf.read(name)


# ---------------- docx ----------------

def _docx_text(raw):
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile:
        raise UploadError("docx 文件损坏：无法解压")
    names = set(zf.namelist())
    if "word/document.xml" not in names:
        raise UploadError("docx 文件缺少 word/document.xml")
    buf = _read_limited(zf, "word/document.xml")
    paragraphs = []
    try:
        for _evt, el in ET.iterparse(io.BytesIO(buf), events=("end",)):
            if el.tag == W_NS + "p":
                paragraphs.append(_docx_para_text(el))
                el.clear()
    except ET.ParseError:
        raise UploadError("docx 文档 XML 解析失败")
    text = "\n".join(p for p in paragraphs if p)
    return text or "（docx 未提取到文本内容）"


def _docx_para_text(p):
    parts = []
    for node in p.iter():
        if node.tag == W_NS + "t":
            parts.append(node.text or "")
        elif node.tag == W_NS + "tab":
            parts.append("\t")
        elif node.tag == W_NS + "br":
            parts.append("\n")
    return "".join(parts).strip()


# ---------------- xlsx ----------------

def _xlsx_text(raw):
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile:
        raise UploadError("xlsx 文件损坏：无法解压")
    names = set(zf.namelist())
    if "xl/workbook.xml" not in names:
        raise UploadError("xlsx 文件缺少 xl/workbook.xml")

    # 工作表名 → sheet 路径（经 workbook.xml.rels 解析 rId）
    sheet_paths = {}
    try:
        wb = ET.fromstring(_read_limited(zf, "xl/workbook.xml"))
    except ET.ParseError:
        raise UploadError("xlsx workbook.xml 解析失败")
    rels = {}
    if "xl/_rels/workbook.xml.rels" in names:
        try:
            rel_root = ET.fromstring(_read_limited(zf, "xl/_rels/workbook.xml.rels"))
        except ET.ParseError:
            rel_root = None
        if rel_root is not None:
            for rel in rel_root.iter(P_NS + "Relationship"):
                rid = rel.get("Id")
                tgt = (rel.get("Target") or "").lstrip("/")
                if rid and tgt:
                    rels[rid] = tgt if tgt.startswith("xl/") else "xl/" + tgt
    for sheet in wb.iter(S_NS + "sheet"):
        name = sheet.get("name") or "Sheet"
        rid = sheet.get(R_NS + "id")
        if rid and rid in rels:
            sheet_paths[name] = rels[rid]

    # 共享字符串表（t="s" 的单元格取值索引）
    shared = []
    if "xl/sharedStrings.xml" in names:
        try:
            s_root = ET.fromstring(_read_limited(zf, "xl/sharedStrings.xml"))
            for si in s_root.iter(S_NS + "si"):
                shared.append("".join(t.text or "" for t in si.iter(S_NS + "t")))
        except ET.ParseError:
            shared = []

    blocks = []
    for sheet_name, path in sheet_paths.items():
        if path not in names:
            continue
        lines = _sheet_lines(zf, path, shared)
        if lines is None:
            continue
        blocks.append("【工作表：%s】" % sheet_name)
        blocks.extend(lines)
    text = "\n".join(blocks)
    return text or "（xlsx 未提取到文本内容）"


def _sheet_lines(zf, path, shared):
    try:
        root = ET.fromstring(_read_limited(zf, path))
    except ET.ParseError:
        return None
    rows = []
    for row in root.iter(S_NS + "row"):
        cells = {}
        max_col = 0
        for c in row.iter(S_NS + "c"):
            col = _col_index(c.get("r") or "")
            if col is None:
                continue
            val = _cell_value(c, shared)
            if val != "":
                cells[col] = val
                max_col = max(max_col, col)
        if cells:
            rows.append("\t".join(cells.get(i, "") for i in range(1, max_col + 1)))
    return rows


def _cell_value(c, shared):
    t = c.get("t")
    if t == "inlineStr":
        is_el = c.find(S_NS + "is")
        if is_el is not None:
            return "".join(x.text or "" for x in is_el.iter(S_NS + "t"))
        return ""
    v = c.find(S_NS + "v")
    if v is None or v.text is None:
        return ""
    val = v.text
    if t == "s":
        try:
            return shared[int(val)]
        except (ValueError, IndexError):
            return ""
    return val


def _col_index(ref):
    """"AB12" → 列号 28（A=1）。解析失败返回 None。"""
    m = re.match(r"([A-Za-z]+)\d+", ref)
    if not m:
        return None
    n = 0
    for ch in m.group(1).upper():
        n = n * 26 + (ord(ch) - ord("A") + 1)
    return n

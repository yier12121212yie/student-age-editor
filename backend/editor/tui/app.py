# -*- coding: utf-8 -*-

"""Textual TUI for StudentAge editor — 优化版



三栏布局：

  左: Mods / Cfgs 树

  中: 记录列表 (DataTable，支持动态列 + 实时过滤)

  右: 详情 / JSON 编辑器



快捷键：

  q 退出  r 刷新  n 新建  d 删除  s 保存  e 聚焦编辑

  f 格式化  y 复制记录  / 过滤  Ctrl+/ 全局搜索  ? 帮助

  Tab / Shift+Tab 切换焦点面板  方向键导航  Enter 确认

"""



import json

import os

import queue

from pathlib import Path



from textual.app import App, ComposeResult

from textual.binding import Binding

from textual.containers import Center, Horizontal, Vertical, VerticalScroll

from textual.screen import ModalScreen

from textual.widgets import (

    Button,

    DataTable,

    Footer,

    Header,

    Input,

    Label,

    Static,

    TextArea,

    Tree,

    OptionList,

    Checkbox,

    ProgressBar,

    RadioSet,

    RadioButton,

    RichLog,

    Select,

)

from textual.widgets.option_list import Option

from textual import events, on

from rich.markup import escape



from editor.cli.utils import (

    CfgParseError,

    cfg_name_normalize,

    cfg_path,

    find_mod,

    list_mods,

    load_cfg,

    load_schema,

    resolve_workspace,

    save_cfg,

    search_in_mod,

    suggest_next_id,

    validate_cfg,

)

# ── GUI-like form helpers ──

TALK_LABELS = {

    "roleIds": "说话人群组",

    "roleName": "自定义名字",

    "highlights": "高亮人物",

    "bg": "切换背景",

    "audio": "背景音乐",

    "roles": "人物控制指令",

    "screenEffect": "屏幕画面特效",

    "content": "台词内容",

    "check": "前置判断",

    "nextTalk": "下一对话ID",

    "nextTalk2": "失败跳转ID",

    "option": "已选选项",

    "id": "ID",

    "time": "时间",

    "effect": "效果",

    "effect2": "效果2",

    "showTxt": "显示文本",

    "vocals": "语音",

    "replace": "替换",

    "maxoptions": "最大选项",

    "miniGame": "小游戏",

}

TALK_SECTIONS = [

    ("角色与台词", ["roleIds", "roleName", "highlights"]),

    ("场景与表现", ["bg", "audio", "roles", "screenEffect"]),

    ("台词内容", ["content"]),

    ("逻辑与分支", ["check", "nextTalk", "nextTalk2"]),

    ("已选选项", ["option"]),

]

FIELD_HINTS = {

    "roleIds": "输入角色 ID，逗号隔开",

    "roleName": "旁白（默认）",

    "highlights": "逗号隔开",

    "bg": "0=继承上文 -1=清空人物 -2=仅转场",

    "audio": "AudioCfg ID",

    "roles": "行: 动作,角色; 列: 动作ID,角色ID...",

    "screenEffect": "特效 ID，逗号隔开",

    "content": "输入对白内容，支持 <color=..> <size=..> 标签",

    "check": "行: 条件类型,判断ID,值; 分号分割多行",

    "nextTalk": "= 对话结束",

    "nextTalk2": "check 判断失败时跳转",

    "option": "逗号隔开",

}



def _field_label(key: str, cfg: str) -> str:

    if cfg == "TalkCfg" and key in TALK_LABELS:

        return TALK_LABELS[key]

    return FIELD_CN.get(key, key)



# 补充映射：仅填补 DEFAULT_*_KEY_MAP 未覆盖的字段（setdefault 不覆盖已有译名）

FIELD_LABELS_EXTRA = {

    # PersonCfg
    "bubbleParm": "气泡参数(小学)",

    "bubbleParm2": "气泡参数(中学)",

    "clickAudio": "点击音效",

    "kzoneHeadId": "空间头像ID",

    "telephone": "电话号码",

    "nicknames": "昵称",

    "l2d": "L2D立绘(小学)",

    "l2d2": "L2D立绘(中学)",

    "l2dParm": "L2D参数(小学)",

    "l2dParm2": "L2D参数(中学)",

    "urlParm": "立绘参数(小学)",

    "urlParm2": "立绘参数(中学)",

    # 通用
    "title": "标题",

    "value": "数值",

    "target": "目标值",

    "group": "分组",

    "lv": "等级",

    "last": "前置",

    "rate": "概率",

    "priority": "优先级",

    "order": "顺序",

    "next": "下一项",

    "nextTalk": "下一对话ID",

    "img": "图片",

    "imgs": "图片列表",

    "sound": "音效",

    "camera": "镜头参数",

    "unlock": "解锁条件",

    "level": "等级",

    "exp": "经验",

}



def _build_field_cn() -> dict:

    cn: dict = {}

    try:

        from editor.core import data_dicts as _dd

        for m in (

            _dd.DEFAULT_PERSON_KEY_MAP,

            _dd.DEFAULT_GROW_KEY_MAP,

            _dd.DEFAULT_EVT_KEY_MAP,

            _dd.DEFAULT_TALK_KEY_MAP,

            _dd.DEFAULT_OPT_KEY_MAP,

            _dd.DEFAULT_KZONE_KEY_MAP,

            _dd.DEFAULT_PHONE_KEY_MAP,

            _dd.DEFAULT_GIFT_KEY_MAP,

            _dd.DEFAULT_INTERACT_KEY_MAP,

        ):

            for k, v in m.items():

                cn.setdefault(k, v)

    except Exception:

        pass

    for k, v in FIELD_LABELS_EXTRA.items():

        cn.setdefault(k, v)

    return cn



FIELD_CN = _build_field_cn()



def _field_hint(key: str) -> str:

    return FIELD_HINTS.get(key, "")



class SuggestDropdown(OptionList):

    """表单字段输入的自动补全候选下拉（内联展开，不遮挡表单）。"""

    DEFAULT_CSS = """

    SuggestDropdown {

        height: auto;

        max-height: 8;

        margin: 0 0 1 0;

        padding: 0;

        background: #232329;

        border: solid #3a3a42;

        scrollbar-size-horizontal: 0;

        display: none;

    }

    SuggestDropdown:focus {

        border: solid #6c5ce7;

    }

    """

    def __init__(self, owner: "FldInput", **kwargs):

        super().__init__(**kwargs)

        self.owner = owner

        self._vals: list = []

    def show(self, items: list) -> None:

        """items: [(显示文本, 补全值), ...]"""

        self.clear_options()

        self._vals = [v for _, v in items]

        if items:

            self.add_options([Option(t) for t, _ in items])

            self.highlighted = 0

            self.display = True

        else:

            self.display = False

    def hide(self) -> None:

        self.display = False

        self.clear_options()

        self._vals = []

    def current_value(self):

        h = self.highlighted

        if h is not None and 0 <= h < len(self._vals):

            return self._vals[h]

        return None

    async def _on_key(self, event: events.Key) -> None:

        if event.key == "escape":

            self.hide()

            if self.owner is not None:

                self.owner.focus()

            event.stop()

            event.prevent_default()

            return

        if event.key == "up" and self.highlighted == 0:

            # 回到输入框（下拉保持展开，可再按 ↓ 进入）

            if self.owner is not None:

                self.owner.focus()

            event.stop()

            event.prevent_default()

            return

        await super()._on_key(event)





class FldInput(Input):

    """表单字段输入框：按 ↓ 展开候选、输入过滤、Enter/点击补全。

    候选来自 数据字典（如角色/背景/地点 ID）与同 Cfg 其它记录的取值。

    """

    def __init__(self, pool=None, **kwargs):

        super().__init__(**kwargs)

        self._pool: list = pool or []          # [(显示文本, 补全值), ...]

        self.dropdown: "SuggestDropdown | None" = None

        self._suppress_suggest = False

    @staticmethod

    def _split_last_segment(text: str):

        """按逗号/分号定位最后一段，返回 (前缀, 末段)。支持 1D/2D 数组逐段补全。"""

        import re as _re

        m = _re.search(r"([,;，；]\s*)([^,;，；]*)$", text)

        if m:

            return text[: m.start(2)], m.group(2)

        return "", text

    def refresh_suggestions(self, force: bool = False) -> None:

        dd = self.dropdown

        if dd is None:

            return

        if self._suppress_suggest and not force:

            self._suppress_suggest = False

            return

        _prefix, seg = self._split_last_segment(self.value)

        q = seg.strip().lower()

        items = []

        seen = set()

        for label, val in self._pool:

            if val in seen:

                continue

            if q and q not in (label + " " + val).lower():

                continue

            seen.add(val)

            items.append((label, val))

            if len(items) >= 60:

                break

        if items and (force or self.has_focus):

            dd.show(items)

        else:

            dd.hide()

    def apply_completion(self, raw: str) -> None:

        prefix, _seg = self._split_last_segment(self.value)

        newv = prefix + raw

        self._suppress_suggest = True

        self.value = newv

        self.cursor_position = len(newv)

        if self.dropdown is not None:

            self.dropdown.hide()

        self.focus()

    async def _on_key(self, event: events.Key) -> None:

        dd = self.dropdown

        if dd is not None and dd.display:

            if event.key == "down":

                dd.focus()

                if dd.highlighted is None:

                    dd.highlighted = 0

                event.stop()

                event.prevent_default()

                return

            if event.key == "escape":

                dd.hide()

                event.stop()

                event.prevent_default()

                return

            if event.key == "enter":

                val = dd.current_value()

                if val is not None:

                    self.apply_completion(val)

                    event.stop()

                    event.prevent_default()

                    return

        elif event.key == "down" and dd is not None:

            # 未展开时按 ↓ 直接展开候选

            self.refresh_suggestions(force=True)

            if dd.display:

                dd.focus()

                dd.highlighted = 0

            event.stop()

            event.prevent_default()

            return

        await super()._on_key(event)



def _encode(val, ftype: str) -> str:

    if val is None:

        return ""

    if ftype == "String":

        return str(val)

    if ftype == "Number":

        return str(val)

    if ftype == "1D Array":

        if isinstance(val, list):

            return ", ".join(str(x) for x in val)

        return str(val)

    if ftype == "2D Array":

        if isinstance(val, list):

            rows = []

            for r in val:

                if isinstance(r, list):

                    rows.append(", ".join(str(x) for x in r))

                else:

                    rows.append(str(r))

            return "; ".join(rows)

        return str(val)

    return str(val) if not isinstance(val, (dict, list)) else __import__("json").dumps(val, ensure_ascii=False)



def _decode(text: str, ftype: str):

    import re as _re

    t = text.strip()

    if not t:

        if ftype == "String":

            return ""

        if ftype == "Number":

            return 0

        return []

    if ftype == "Number":

        try:

            return int(t) if t.lstrip("-").isdigit() else float(t) if _re.match(r"^-?\d+\.\d+$", t) else 0

        except:

            return 0

    if ftype == "String":

        return t

    if ftype == "1D Array":

        parts = _re.split(r"[;，,，\n]+", t)

        out = []

        for p in parts:

            p = p.strip()

            if not p:

                continue

            if p.lstrip("-").isdigit():

                try: out.append(int(p))

                except: out.append(p)

            elif _re.match(r"^-?\d+\.\d+$", p):

                try: out.append(float(p))

                except: out.append(p)

            else:

                out.append(p)

        return out

    if ftype == "2D Array":

        rows = _re.split(r"[;\n]+", t)

        out = []

        for r in rows:

            r = r.strip()

            if not r:

                continue

            cols = _re.split(r"[,，]+", r)

            row = []

            for c in cols:

                c = c.strip()

                if not c:

                    continue

                if c.lstrip("-").isdigit():

                    try: row.append(int(c))

                    except: row.append(c)

                elif _re.match(r"^-?\d+\.\d+$", c):

                    try: row.append(float(c))

                    except: row.append(c)

                else:

                    row.append(c)

            out.append(row)

        return out

    return t





def _code_sample(code: str) -> str:

    """把指南模板 code（如 "[4001, X]" / "[N, 3000, E]"）转成可补全的文本。

    去掉外层括号，占位符替换为示例值（N=人物ID、X=数值参数等），

    使补全结果与 _split_last_segment 的逐段补全语义及 _decode 的解析格式一致。

    """

    t = (code or "").strip()

    if t.startswith("[") and t.endswith("]"):

        t = t[1:-1].strip()

    if not t:

        return ""

    parts = [p.strip() for p in t.split(",")]

    # 占位符 → 示例值（用户补全后再按需修改）

    named = {"N": "0", "S": "2", "E": "1", "C": "1", "Emoji": "1",

             "I": "1", "Bg": "1", "Npc": "1", "CG": "1"}

    # X 的示例值随指令含义不同（4001 秒 / 3002 秒 / 3001 次 / 3004·3008 像素 …）

    x_by_code = {"4001": "0.5", "4011": "0.5", "4012": "1", "3001": "1",

                 "3002": "0.4", "3004": "100", "3008": "100"}

    out = []

    for p in parts:

        if p in named:

            out.append(named[p])

        elif p == "X":

            out.append(x_by_code.get(parts[0] if parts else "", "1"))

        else:

            out.append(p)

    return ", ".join(out)







# ──────────────────────────────────────────────────────────────────────

# Modal Screens

# ──────────────────────────────────────────────────────────────────────



class HelpScreen(ModalScreen):

    """帮助弹窗 — 快捷键总览"""



    DEFAULT_CSS = """

    HelpScreen { align: center middle; }

    #help-dialog {

        width: 78; height: auto; max-height: 88%;

        background: $surface; border: thick $primary;

        padding: 1 2;

    }

    #help-title { text-align: center; text-style: bold; color: $primary; margin-bottom: 1; }

    #help-grid { height: auto; max-height: 22; overflow-y: auto; }

    #help-footer { text-align: center; color: $text-muted; margin-top: 1; }

    """



    def compose(self) -> ComposeResult:

        with Vertical(id="help-dialog"):

            yield Static("⌨️  快捷键帮助  —  Editor TUI", id="help-title")

            yield Static(

                "[b]导航[/]\n"

                "  [cyan]Tab[/] / [cyan]Shift+Tab[/]  循环切换 左 → 中 → 右 面板\n"

                "  [cyan]↑ ↓[/] / [cyan]j k[/]        上下移动  [cyan]Enter[/] 确认选择\n"

                "  [cyan]← →[/] / [cyan]h l[/]        折叠/展开 Mod  ·  面板间跳转\n"

                "  [cyan]Esc[/]              关闭弹窗 / 退出搜索\n"

                "\n[b]记录操作[/]\n"

                "  [green]n[/] 新建记录       自动生成 ID=最大值+1，可在弹窗中改写\n"

                "  [green]y[/] 复制记录       复制当前记录为新 ID\n"

                "  [yellow]d[/] 删除记录       弹出确认框（防误触）\n"

                "  [cyan]e[/] 聚焦编辑       聚焦右侧 JSON 编辑区\n"

                "  [cyan]f[/] 格式化         自动格式化 JSON（2 空格缩进）\n"

                "\n[b]保存与校验[/]\n"

                "  [magenta]s[/] / [magenta]Ctrl+S[/]  保存到文件（先校验，error 阻断）\n"

                "  [magenta]v[/] 校验         仅校验不落盘，结果显示在编辑区\n"

                "\n[b]搜索与全局[/]\n"

                "  [cyan]/[/]  过滤当前列表   实时过滤中栏记录（ID/预览）\n"

                "  [cyan]Ctrl+K[/] 全局搜索   跨 cfg 搜索（/ 也会进入全局若未选中 cfg）\n"

                "  [cyan]r[/]  刷新           重载 workspace + 当前 cfg\n"
                "  [green]N[/]  新建 Mod        在 workspace 下生成 manifest.json + Cfgs/zh-cn 骨架（n 未选 cfg 时也会转入）\n"
                "  [green]c[/]  云同步         网盘 provider 列表 / 测试 / 上传下载同步\n"
                "  [green]a[/]  AI 助手        对话式修改模组（写操作需确认）\n"
                "  [green]t[/]  配音 (TTS)     语音合成 / 测试连接 / 素材管理\n"
                "  [green]p[/]  插件           第三方插件列表 / 启停 / 详情 / 卸载 / 重载（启用需高危确认）\n"

                "  [cyan]?[/]  帮助           打开本窗口\n"

                "  [cyan]q[/]  退出           有未保存时二次确认\n",

                id="help-grid",

            )

            yield Static("[dim]按 Esc / q / Enter 关闭[/]", id="help-footer")

            with Center():

                yield Button("关闭 (Esc)", id="help-close", variant="primary")



    def on_mount(self):

        self.query_one("#help-close", Button).focus()



    @on(Button.Pressed, "#help-close")

    def close(self, _=None):

        self.app.pop_screen()



    def on_key(self, event):

        if event.key in ("escape", "q", "enter"):

            event.stop()

            self.app.pop_screen()





class ConfirmScreen(ModalScreen[bool]):

    """通用确认弹窗"""



    DEFAULT_CSS = """

    ConfirmScreen { align: center middle; }

    #confirm-dialog {

        width: 60; height: auto;

        background: $surface; border: thick $warning;

        padding: 1 2;

    }

    #confirm-title { text-style: bold; color: $warning; }

    #confirm-msg { margin: 1 0; }

    #confirm-dialog Horizontal { height: auto; }

    """



    def __init__(self, title: str, message: str, ok_label="确定", ok_variant="error", cancel_label="取消"):

        super().__init__()

        self._title = title

        self._msg = message

        self._ok_label = ok_label

        self._ok_variant = ok_variant

        self._cancel_label = cancel_label



    def compose(self) -> ComposeResult:

        with Vertical(id="confirm-dialog"):

            yield Static(self._title, id="confirm-title")

            yield Static(self._msg, id="confirm-msg")

            with Horizontal():

                yield Button(self._cancel_label, id="c-cancel", variant="default")

                yield Button(self._ok_label, id="c-ok", variant=self._ok_variant)



    def on_mount(self):

        self.query_one("#c-cancel", Button).focus()



    @on(Button.Pressed, "#c-cancel")

    def cancel(self, _=None):

        self.dismiss(False)



    @on(Button.Pressed, "#c-ok")

    def ok(self, _=None):

        self.dismiss(True)



    def on_key(self, event):

        if event.key == "escape":

            event.stop()

            self.dismiss(False)





class PromptScreen(ModalScreen[str | None]):

    """单行输入弹窗（新建 ID 等）"""



    DEFAULT_CSS = """

    PromptScreen { align: center middle; }

    #prompt-dialog {

        width: 60; height: auto;

        background: $surface; border: thick $primary;

        padding: 1 2;

    }

    #prompt-title { text-style: bold; color: $primary; }

    #prompt-msg { margin: 1 0 1 0; color: $text-muted; }

    #prompt-input { margin-bottom: 1; }

    #prompt-dialog Horizontal { height: auto; }

    """



    def __init__(self, title: str, message: str, default: str = "", placeholder: str = ""):

        super().__init__()

        self._title = title

        self._msg = message

        self._default = default

        self._placeholder = placeholder



    def compose(self) -> ComposeResult:

        with Vertical(id="prompt-dialog"):

            yield Static(self._title, id="prompt-title")

            yield Static(self._msg, id="prompt-msg")

            yield Input(value=self._default, placeholder=self._placeholder, id="prompt-input")

            with Horizontal():

                yield Button("取消", id="p-cancel")

                yield Button("确定", id="p-ok", variant="primary")



    def on_mount(self):

        inp = self.query_one("#prompt-input", Input)

        inp.focus()

        # select all

        inp.action_select_all()



    @on(Button.Pressed, "#p-cancel")

    def cancel(self, _=None):

        self.dismiss(None)



    @on(Button.Pressed, "#p-ok")

    def ok(self, _=None):

        v = self.query_one("#prompt-input", Input).value.strip()

        self.dismiss(v)



    @on(Input.Submitted, "#prompt-input")

    def on_submit(self, event: Input.Submitted):

        self.dismiss(event.value.strip())



    def on_key(self, event):

        if event.key == "escape":

            event.stop()

            self.dismiss(None)





class ValidationScreen(ModalScreen):

    """校验结果弹窗"""



    DEFAULT_CSS = """

    ValidationScreen { align: center middle; }

    #val-dialog {

        width: 78; height: 70%;

        background: $surface; border: thick $primary;

        padding: 1 1;

    }

    #val-title { text-align: center; text-style: bold; margin-bottom: 1; }

    #val-list { height: 1fr; overflow-y: auto; border: solid $primary 40%; padding: 0 1; }

    """



    def __init__(self, cfg_name: str, issues: list, total: int):

        super().__init__()

        self._cfg = cfg_name

        self._issues = issues

        self._total = total



    def compose(self) -> ComposeResult:

        with Vertical(id="val-dialog"):

            if not self._issues:

                yield Static(f"[green]✓ {self._cfg} 校验通过 · {self._total} 条记录[/]", id="val-title")

                yield Static("[dim]无警告与错误，可放心保存。[/]", id="val-list")

            else:

                errs = sum(1 for lv, _ in self._issues if lv == "error")

                warns = len(self._issues) - errs

                color = "red" if errs else "yellow"

                yield Static(

                    f"[{color}]● {self._cfg} 校验结果 · {len(self._issues)} 条提示  "

                    f"([red]{errs} error[/] / [yellow]{warns} warn[/])[/]",

                    id="val-title",

                )

                lines = []

                for lv, msg in self._issues[:80]:

                    if lv == "error":

                        lines.append(f"[red][ERR][/] {msg}")

                    else:

                        lines.append(f"[yellow][WARN][/] {msg}")

                if len(self._issues) > 80:

                    lines.append(f"[dim]… 还有 {len(self._issues)-80} 条未显示[/]")

                yield Static("\n".join(lines), id="val-list")

            with Center():

                yield Button("关闭 (Esc)", id="val-close", variant="primary")



    def on_mount(self):

        self.query_one("#val-close", Button).focus()



    @on(Button.Pressed, "#val-close")

    def close(self, _=None):

        self.app.pop_screen()



    def on_key(self, event):

        if event.key in ("escape", "enter", "q"):

            event.stop()

            self.app.pop_screen()





class GlobalSearchScreen(ModalScreen):

    """全局搜索弹窗：输入关键词后在 workspace 内搜索"""



    DEFAULT_CSS = """

    GlobalSearchScreen { align: center middle; }

    #gs-dialog {

        width: 78; height: 72%;

        background: $surface; border: thick $primary;

        padding: 1 1;

    }

    #gs-title { text-style: bold; color: $primary; }

    #gs-input { margin: 1 0; }

    #gs-hint { color: $text-muted; margin-bottom: 1; }

    #gs-table { height: 1fr; }

    """



    def __init__(self, workspace: Path, current_mod_root: Path | None):

        super().__init__()

        self.workspace = workspace

        self.current_mod_root = current_mod_root

        self._hits: list[dict] = []



    def compose(self) -> ComposeResult:

        with Vertical(id="gs-dialog"):

            yield Static("🔍  全局搜索", id="gs-title")

            yield Input(placeholder="输入关键词后回车搜索 · 支持 ID / 文本模糊匹配 · Esc 关闭", id="gs-input")

            yield Static("[dim]回车搜索 · 上下选择 · 回车定位到记录 · Esc 关闭[/]", id="gs-hint")

            yield DataTable(id="gs-table", cursor_type="row")



    def on_mount(self):

        self.query_one("#gs-input", Input).focus()

        t: DataTable = self.query_one("#gs-table", DataTable)

        t.add_columns("Mod", "Cfg", "ID", "片段")

        t.zebra_stripes = True



    @on(Input.Submitted, "#gs-input")

    def do_search(self, event: Input.Submitted):

        kw = event.value.strip()

        if not kw:

            return

        t: DataTable = self.query_one("#gs-table", DataTable)

        t.clear()

        self._hits.clear()



        # 若当前有选中 mod，优先搜当前 mod；否则搜整个 workspace

        if self.current_mod_root and self.current_mod_root.is_dir():

            hits = search_in_mod(self.current_mod_root, kw, None)

            for h in hits:

                h["mod"] = self.current_mod_root.name

            # 标记来源

            mod_label = self.current_mod_root.name

        else:

            hits = []

            mods = list_mods(self.workspace)

            for m in mods[:20]:  # 限制避免卡死

                sub = search_in_mod(m["root"], kw, None)

                for h in sub:

                    h["mod"] = m["name"]

                    hits.append(h)

            mod_label = "workspace"



        self._hits = hits

        if not hits:

            self.app.notify(f"未找到 {kw!r}", severity="warning", timeout=2.5)

            return

        for h in hits[:200]:

            # 转义防止 markup 注入

            snippet = h["snippet"][:72].replace("[", "\\[")

            t.add_row(h.get("mod", mod_label), h["cfg"], h["id"], snippet, key=f"{h['cfg']}:{h['id']}")

        self.app.notify(f"找到 {len(hits)} 条 · {kw!r}", timeout=2.5)

        t.focus()



    @on(DataTable.RowSelected, "#gs-table")

    def on_row_selected(self, event: DataTable.RowSelected):

        key = str(event.row_key.value) if event.row_key and event.row_key.value else ""

        if ":" not in key:

            return

        cfg, rid = key.split(":", 1)

        # 回调给主 App 定位

        # 通过 dismiss 传递结果

        self.dismiss({"cfg": cfg, "id": rid})




    def on_key(self, event):

        if event.key == "escape":

            event.stop()

            self.dismiss(None)




class OobeScreen(ModalScreen[bool]):

    """首次运行引导（OOBE）：欢迎 → 工作区 → 首个 Mod（可选）→ 完成。

    dismiss(True)=完成/跳过（已写入标记），dismiss(False)=中止（下次再提示）。
    """



    DEFAULT_CSS = """

    OobeScreen { align: center middle; }

    #oobe-dialog {

        width: 84; max-width: 92%; height: auto; max-height: 90%;

        background: $surface; border: thick $primary;

        padding: 1 2;

    }

    #oobe-title { text-style: bold; color: $primary; margin-bottom: 1; }

    #oobe-body { height: auto; max-height: 20; overflow-y: auto; }

    .oobe-step { display: none; height: auto; padding: 0 1; }

    .oobe-step.visible { display: block; }

    .oobe-feature { color: $text; margin-bottom: 1; }

    .oobe-hint { color: $text-muted; margin-top: 1; }

    .oobe-row { height: auto; align-horizontal: left; }

    .oobe-row Button { min-width: 10; margin-right: 1; }

    #oobe-inputs Input { margin-bottom: 1; }

    #oobe-nav { height: 3; margin-top: 1; align-horizontal: center; }

    #oobe-nav Button { min-width: 14; margin: 0 1; text-style: bold; }

    #oobe-summary { color: $text; }

    """



    STEPS = ["欢迎", "工作区", "首个 Mod（可选）", "AI 助手（可选）", "配音 TTS（可选）", "云存储（可选）", "完成"]


    def __init__(self, workspace: Path | None = None, forced: bool = False, **kwargs):

        super().__init__(**kwargs)

        self._forced = forced

        try:

            self._ws_default = str(resolve_workspace(None))

        except Exception:

            from editor.cli.oobe import suggested_workspace as _sw

            self._ws_default = str(_sw())

        self._initial_ws = workspace

        self._mod_title = ""

        self._mod_desc = ""

        self._step = 0


    # ── UI 构造 ──


    def compose(self) -> ComposeResult:

        from editor.cli.oobe import suggested_workspace

        with Vertical(id="oobe-dialog"):

            yield Static(f"🚀  欢迎使用 学生时代 · 模组编辑器 — OOBE 向导", id="oobe-title")

            with VerticalScroll(id="oobe-body"):

                with Vertical(id="oobe-step-0", classes="oobe-step visible"):

                    yield Static(

                        "这是一份离线文件模式的《学生时代》模组编辑器，"

                        "三分钟完成初始配置：\n\n"

                        "[b]·[/] 直接读写 [cyan]Cfgs/zh-cn/*.json[/]，406 张 schema 表校验\n"

                        "[b]·[/] CLI 单命令 / REPL / 本 TUI / Flutter GUI 共用同一份数据\n"

                        "[b]·[/] 完成后此向导不会再自动弹出，可用 [cyan]--oobe[/] 随时重开",

                        classes="oobe-feature",

                    )

                    yield Static(f"[dim]检测到的建议工作区: {suggested_workspace()}[/]", classes="oobe-hint")

                with Vertical(id="oobe-step-1", classes="oobe-step"):

                    yield Static("[b]① 选择工作区[/] — 存放你的模组目录（不存在会自动创建）")

                    yield Input(value=self._ws_default, placeholder="工作区绝对路径", id="o-ws-input")

                    with Horizontal(classes="oobe-row"):

                        yield Button("默认", id="o-ws-default", variant="default")

                        yield Static("[dim]回车确认 · 「默认」恢复建议位置[/]", classes="oobe-hint")


                with Vertical(id="oobe-step-2", classes="oobe-step"):

                    yield Static("[b]② 创建第一个 Mod[/] [dim](可跳过)[/]")

                    yield Input(placeholder="Mod 名称（即目录名，如 MyFirstMod）", id="oobe-mod-title")

                    yield Input(placeholder="描述（可选，直接回车跳过）", id="oobe-mod-desc")

                    yield Static("[dim]会生成 manifest.json + Cfgs/zh-cn/ 空骨架[/]", classes="oobe-hint")

                with Vertical(id="oobe-step-3", classes="oobe-step"):

                    yield Static("[b]③ AI 助手[/] [dim](可选，全部留空跳过)[/]")

                    yield Input(placeholder="协议 openai_compatible / openai_responses / anthropic", value="openai_compatible", id="oobe-ai-provider")

                    yield Input(placeholder="Base URL（回车=官方默认）", id="oobe-ai-baseurl")

                    yield Input(placeholder="API Key（留空则跳过本步）", id="oobe-ai-key", password=True)

                    yield Input(placeholder="模型（回车=默认）", id="oobe-ai-model")

                with Vertical(id="oobe-step-4", classes="oobe-step"):

                    yield Static("[b]④ 配音 TTS[/] [dim](可选，全部留空跳过)[/]")

                    yield Input(placeholder="服务商 aliyun / minimax（留空跳过）", id="oobe-tts-provider")

                    yield Input(placeholder="API Key", id="oobe-tts-key", password=True)

                    yield Input(placeholder="Group ID（仅 MiniMax，可空）", id="oobe-tts-groupid")

                    yield Input(placeholder="模型（回车=默认）", id="oobe-tts-model")

                    yield Input(placeholder="默认音色（回车=默认）", id="oobe-tts-voice")

                with Vertical(id="oobe-step-5", classes="oobe-step"):

                    yield Static("[b]⑤ 云存储[/] [dim](可选，留空跳过；保存后可到云同步面板测试)[/]")

                    yield Input(placeholder="类型 local / webdav / openlist（留空跳过）", id="oobe-cloud-type")

                    yield Input(placeholder="名称（回车=类型名）", id="oobe-cloud-name")

                    yield Input(placeholder="地址（WebDAV/OpenList）或本地根目录（local）", id="oobe-cloud-url")

                    yield Input(placeholder="用户名（webdav 可空）", id="oobe-cloud-user")

                    yield Input(placeholder="密码 / Token（可空）", id="oobe-cloud-secret", password=True)

                    yield Input(placeholder="远端根目录（回车=mods）", value="mods", id="oobe-cloud-remote")

                with Vertical(id="oobe-step-6", classes="oobe-step"):

                    yield Static("", id="oobe-summary")

            with Horizontal(id="oobe-nav"):

                yield Button("跳过全部", id="o-skip", variant="default")

                yield Button("上一步", id="o-prev", variant="default")

                yield Button("下一步", id="o-next", variant="primary")


    def on_mount(self):

        self._prefill_settings()

        self._show_step(0)

        self.query_one("#o-next", Button).focus()


    # ── 步骤切换 ──


    def _show_step(self, idx: int):

        self._step = idx

        for i in range(len(self.STEPS)):

            try:

                w = self.query_one(f"#oobe-step-{i}")

                w.set_class(i == idx, "visible")

            except Exception:

                pass

        title = "🚀  欢迎使用 学生时代 · 模组编辑器 — OOBE 向导"

        if idx > 0:

            title = f"🚀  OOBE 向导 — 第 {idx}/{len(self.STEPS) - 1} 步：{self.STEPS[idx]}"

        self.query_one("#oobe-title", Static).update(title)

        nxt = self.query_one("#o-next", Button)

        if idx == 1:

            nxt.label = "下一步"

            self.query_one("#o-ws-input", Input).focus()

        elif idx == 2:

            nxt.label = "下一步"

            self.query_one("#oobe-mod-title", Input).focus()

        elif idx == len(self.STEPS) - 2:

            nxt.label = "创建并完成"

            self.query_one("#oobe-cloud-type", Input).focus()

        else:

            nxt.label = "开始使用" if idx == len(self.STEPS) - 1 else "下一步"


    @on(Button.Pressed, "#o-ws-default")

    def _reset_default(self):

        self.query_one("#o-ws-input", Input).value = self._ws_default


    @on(Button.Pressed, "#o-prev")

    def _prev(self):

        if self._step > 0:

            self._show_step(self._step - 1)


    @on(Button.Pressed, "#o-next")

    def _next(self):

        if self._step == 1 and not self._collect_workspace():

            return

        if self._step == len(self.STEPS) - 1:

            self.dismiss(True)

        elif self._step == len(self.STEPS) - 2:

            self._finish()

        else:

            self._show_step(self._step + 1)


    @on(Input.Submitted, "#o-ws-input")

    def _ws_submitted(self, event):

        if self._collect_workspace():

            self._show_step(2)


    @on(Input.Submitted, "#oobe-mod-title")

    def _mod_submitted(self, event):

        self._next()


    def _collect_workspace(self) -> bool:

        from editor.cli.oobe import set_workspace

        raw = self.query_one("#o-ws-input", Input).value.strip()

        if not raw:

            self.app.notify("请输入工作区路径", severity="warning", timeout=3)

            return False

        try:

            p = set_workspace(raw)

        except ValueError as e:

            self.app.notify(str(e), severity="error", timeout=4)

            return False

        self.app.notify(f"工作区已保存: {p}", timeout=3)

        return True


    def _prefill_settings(self):

        from editor.core.env_store import read_ai_settings

        try:

            s = read_ai_settings()

        except Exception:

            s = {}

        try:

            self.query_one("#oobe-ai-provider", Input).value = s.get("provider") or "openai_compatible"

            self.query_one("#oobe-ai-baseurl", Input).value = s.get("baseUrl") or ""

            self.query_one("#oobe-ai-key", Input).value = s.get("apiKey") or ""

            self.query_one("#oobe-ai-model", Input).value = s.get("model") or ""

            self.query_one("#oobe-tts-provider", Input).value = s.get("ttsProvider") or ""

            self.query_one("#oobe-tts-key", Input).value = s.get("ttsApiKey") or ""

            self.query_one("#oobe-tts-groupid", Input).value = s.get("ttsGroupId") or ""

            self.query_one("#oobe-tts-model", Input).value = s.get("ttsModel") or ""

            self.query_one("#oobe-tts-voice", Input).value = s.get("ttsVoice") or ""

        except Exception:

            pass


    def _collect_ai_settings(self) -> dict:

        ai: dict = {}

        try:

            ai["provider"] = self.query_one("#oobe-ai-provider", Input).value.strip() or "openai_compatible"

        except Exception:

            ai["provider"] = "openai_compatible"

        for key, iid in (("baseUrl", "#oobe-ai-baseurl"),

                         ("apiKey", "#oobe-ai-key"),

                         ("model", "#oobe-ai-model")):

            try:

                v = self.query_one(iid, Input).value.strip()

                if v:

                    ai[key] = v

            except Exception:

                pass

        if not (ai.get("apiKey") or ai.get("model") or ai.get("baseUrl")):

            return {}

        return ai


    def _collect_tts_settings(self) -> dict:

        tts: dict = {}

        try:

            p = self.query_one("#oobe-tts-provider", Input).value.strip().lower()

        except Exception:

            return tts

        if p not in ("aliyun", "minimax"):

            return tts

        for key, iid in (("ttsApiKey", "#oobe-tts-key"),

                         ("ttsGroupId", "#oobe-tts-groupid"),

                         ("ttsModel", "#oobe-tts-model"),

                         ("ttsVoice", "#oobe-tts-voice")):

            try:

                v = self.query_one(iid, Input).value.strip()

                if v:

                    tts[key] = v

            except Exception:

                pass

        if not tts.get("ttsApiKey"):

            return {}

        tts["ttsProvider"] = p

        return tts


    def _collect_cloud(self) -> dict | None:

        try:

            t = self.query_one("#oobe-cloud-type", Input).value.strip().lower()

        except Exception:

            return None

        if t not in ("local", "webdav", "openlist"):

            return None

        def _val(iid: str) -> str:

            try:

                return self.query_one(iid, Input).value.strip()

            except Exception:

                return ""

        cfg: dict = {}

        if t == "local":

            root = _val("#oobe-cloud-url")

            if not root:

                return None

            cfg["root"] = root

        elif t == "webdav":

            url = _val("#oobe-cloud-url")

            if not url:

                return None

            cfg["url"] = url

            user = _val("#oobe-cloud-user")

            if user:

                cfg["username"] = user

            pwd = _val("#oobe-cloud-secret")

            if pwd:

                cfg["password"] = pwd

        else:  # openlist

            url = _val("#oobe-cloud-url")

            if not url:

                return None

            cfg["url"] = url

            token = _val("#oobe-cloud-secret")

            if token:

                cfg["token"] = token

        return {

            "name": _val("#oobe-cloud-name") or t,

            "type": t,

            "config": cfg,

            "remote_root": _val("#oobe-cloud-remote") or "mods",

        }


    def _finish(self):

        from editor.cli.oobe import apply_setup

        title = self.query_one("#oobe-mod-title", Input).value.strip()

        desc = self.query_one("#oobe-mod-desc", Input).value.strip()

        ws_raw = ""

        try:

            ws_raw = self.query_one("#o-ws-input", Input).value.strip()

        except Exception:

            pass

        ai_only = self._collect_ai_settings()

        tts = self._collect_tts_settings()

        ai_settings = dict(ai_only)

        ai_settings.update(tts)

        cloud_provider = self._collect_cloud()

        try:

            result = apply_setup(workspace=ws_raw or None,

                                 mod_title=title or None, mod_desc=desc,

                                 ai_settings=ai_settings or None,

                                 cloud_provider=cloud_provider)

        except Exception as e:

            # 工作区步骤可能已经保存过；建 Mod 失败不阻塞完成标记以外的流程

            self.app.notify(f"{e} — 已跳过建 Mod", severity="warning", timeout=4)

            try:

                apply_setup(workspace=None, mod_title=None, mod_desc="")

                result = {}

            except Exception:

                result = {}

        s = self.query_one("#oobe-summary", Static)

        lines = ["[green]✓ 初始配置已完成[/]\n"]

        if result.get("workspace"):

            lines.append(f"[b]工作区[/] {result['workspace']}")

        if result.get("mod"):

            lines.append(f"[b]首个 Mod[/] {result['mod']}")

        if ai_only:

            lines.append(f"[b]AI 助手[/] 已配置（{ai_only.get('provider') or 'openai_compatible'}）")

        if tts.get("ttsProvider"):

            lines.append(f"[b]配音 TTS[/] 已配置（{tts.get('ttsProvider')}）")

        if result.get("cloud_provider"):

            cname = (cloud_provider or {}).get("name") or ""

            ctype = (cloud_provider or {}).get("type") or ""

            lines.append(f"[b]云存储[/] {cname}（{ctype}）")

        lines.append("\n[dim]提示：左侧选择 Mod → 展开 Cfgs → 回车打开记录表[/]")

        lines.append("[dim]快捷键：n 新建 · e 编辑 · s 保存 · ? 帮助[/]")

        s.update("\n".join(lines))

        self._show_step(len(self.STEPS) - 1)


    @on(Button.Pressed, "#o-skip")

    def skip(self):

        from editor.cli.oobe import mark_done

        mark_done()

        self.dismiss(True)


    def on_key(self, event):

        if event.key == "escape":

            event.stop()

            self.dismiss(False)



# ──────────────────────────────────────────────────────────────────────


class PluginInfoScreen(ModalScreen):
    """插件详情弹窗：manifest 全字段 + contributions。"""

    BINDINGS = [Binding("escape", "close", "关闭", priority=True)]

    DEFAULT_CSS = """
    PluginInfoScreen { align: center middle; }
    #pi-dialog { width: 80; height: 72%; background: $surface; border: thick $primary; padding: 1 2; }
    #pi-title { text-style: bold; color: $primary; margin-bottom: 1; }
    #pi-body { height: 1fr; overflow-y: auto; }
    """

    def __init__(self, info):
        super().__init__()
        self._info = info

    def _render_body(self):
        info = self._info
        lines = []
        for k in ("id", "name", "version", "author", "description", "entry"):
            lines.append(f"[cyan]{k}[/]  {escape(str(info.get(k) or ''))}")
        status = "启用" if info.get("enabled") else "停用"
        if info.get("enabled"):
            status += " · " + ("已加载" if info.get("loaded") else "加载失败")
        lines.append(f"[cyan]status[/]  {status}")
        lines.append(f"[cyan]risk_ack_at[/]  {escape(str(info.get('risk_ack_at') or ''))}")
        if info.get("error"):
            lines.append(f"[red]error[/]  {escape(str(info['error']))}")
        contrib = info.get("contributions") or {}
        lines.append("\n[bold]contributions[/]")
        for kind in ("routes", "tools", "commands", "panels"):
            items = contrib.get(kind) or []
            if items:
                lines.append(f"[green][{kind}][/]")
                for it in items:
                    lines.append("    " + escape(str(it)))
            else:
                lines.append(f"[dim][{kind}][/] (none)")
        return "\n".join(lines)

    def compose(self):
        with Vertical(id="pi-dialog"):
            yield Static(f"🧩 插件详情 — {escape(self._info['id'])}", id="pi-title")
            yield Static(self._render_body(), id="pi-body")
            with Center():
                yield Button("关闭 (Esc)", id="pi-close", variant="primary")

    def on_mount(self):
        self.query_one("#pi-close", Button).focus()

    @on(Button.Pressed, "#pi-close")
    def close(self, _=None):
        self.app.pop_screen()

    def on_key(self, event):
        if event.key in ("escape", "q", "enter"):
            event.stop()
            self.app.pop_screen()


class PluginsScreen(ModalScreen):
    """插件管理弹窗：空格 启用/停用 · i 详情 · d 卸载 · r 重载。

    启用第三方插件 = 运行其 Python 代码，必须先弹 ConfirmScreen 高危确认，
    确认后才 set_enabled(pid, True, risk_ack=True)；未确认保持停用。
    """

    BINDINGS = [
        Binding("escape", "close", "关闭", priority=True),
        Binding("space", "toggle", "启用/停用"),
        Binding("i", "info", "详情"),
        Binding("d", "delete", "卸载"),
        Binding("r", "reload", "重载"),
        Binding("q", "close", "关闭", show=False),
    ]

    DEFAULT_CSS = """
    PluginsScreen { align: center middle; }
    #pl-dialog { width: 90; height: 80%; background: $surface; border: thick $primary; padding: 1 2; }
    #pl-title { text-style: bold; color: $primary; margin-bottom: 1; }
    #pl-table { height: 1fr; }
    #pl-hint { color: $text-muted; margin-top: 1; }
    """

    def __init__(self):
        super().__init__()
        self._plugins = []
        self._selected_id = None

    @staticmethod
    def _system():
        from editor.core import plugin_system
        return plugin_system

    def compose(self):
        with Vertical(id="pl-dialog"):
            yield Static("🧩 插件管理（第三方 Python 插件）", id="pl-title")
            yield DataTable(id="pl-table", cursor_type="row")
            yield Static(
                "空格=启用/停用 · i=详情 · d=卸载 · r=重载 · Esc/q=关闭  "
                "[dim]（启用需高危确认：插件将与编辑器同权限运行）[/]",
                id="pl-hint")

    def on_mount(self):
        t: DataTable = self.query_one("#pl-table", DataTable)
        t.cursor_type = "row"
        t.zebra_stripes = True
        t.add_columns("id", "名称", "版本", "状态", "error")
        t.focus()
        self._reload()

    def _reload(self):
        ps = self._system()
        try:
            ps.load_all(None)
            self._plugins = ps.list_plugins()
        except Exception as e:
            self._plugins = []
            self.app.notify(f"插件列表加载失败: {e}", severity="error", timeout=3)
        t: DataTable = self.query_one("#pl-table", DataTable)
        t.clear()
        for e in self._plugins:
            status = "启用" if e["enabled"] else "停用"
            if e["enabled"]:
                status += " ·" + ("已加载" if e["loaded"] else "加载失败")
            t.add_row(e["id"], e["name"] or "-", e["version"] or "-", status,
                      (e["error"] or "")[:40], key=e["id"])
        if self._selected_id is None and self._plugins:
            self._selected_id = self._plugins[0]["id"]

    def _selected_plugin(self):
        if self._selected_id:
            for e in self._plugins:
                if e["id"] == self._selected_id:
                    return e
        return None

    @on(DataTable.RowHighlighted, "#pl-table")
    def _on_highlight(self, event):
        if event.row_key and event.row_key.value:
            self._selected_id = str(event.row_key.value)

    def action_toggle(self):
        entry = self._selected_plugin()
        if entry is None:
            self.app.notify("先在列表中选择一个插件", severity="warning", timeout=2)
            return
        ps = self._system()
        if entry["enabled"]:
            # 停用直接切换（无需确认）
            try:
                ps.set_enabled(entry["id"], False)
            except Exception as e:
                self.app.notify(f"停用失败: {e}", severity="error", timeout=3)
            else:
                self.app.notify(f"已停用 {entry['id']}", timeout=2)
            self._reload()
            return
        # 启用：先弹高危确认（复用 ConfirmScreen[bool] 模式），确认才启用
        def _after(ok):
            if not ok:
                self.app.notify(f"{entry['id']} 未启用（放弃高危确认）", timeout=2)
                self._reload()
                return
            try:
                ps.set_enabled(entry["id"], True, risk_ack=True)
            except Exception as e:
                self.app.notify(f"启用失败: {e}", severity="error", timeout=3)
            else:
                self.app.notify(f"已启用 {entry['id']}", timeout=2)
            self._reload()
        self.app.push_screen(ConfirmScreen(
            f"启用插件 {entry['id']}？",
            f"[b]{escape(entry['name'])}[/]  [{escape(entry['id'])}] "
            f"{escape(entry['version'] or '')} · {escape(entry['author'] or '')}\n"
            f"{escape(entry['description'] or '')}\n\n"
            "[bold red]高危警示[/]\n"
            "该插件为第三方 Python 代码，启用后将以与编辑器相同的用户权限在本机运行，"
            "可读写文件、访问网络。请仅启用来自可信来源的插件。",
            ok_label="启用", ok_variant="warning"), _after)

    def action_info(self):
        entry = self._selected_plugin()
        if entry is None:
            self.app.notify("先在列表中选择一个插件", severity="warning", timeout=2)
            return
        self.app.push_screen(PluginInfoScreen(entry))

    def action_delete(self):
        entry = self._selected_plugin()
        if entry is None:
            self.app.notify("先在列表中选择一个插件", severity="warning", timeout=2)
            return
        ps = self._system()
        if entry["enabled"]:
            self.app.notify(f"{entry['id']} 已启用，请先停用再卸载（空格停用）",
                            severity="warning", timeout=3)
            return
        def _after(ok):
            if not ok:
                return
            try:
                ps.uninstall_plugin(entry["id"])
            except Exception as e:
                self.app.notify(f"卸载失败: {e}", severity="error", timeout=3)
            else:
                self.app.notify(f"已卸载 {entry['id']}", timeout=2)
            self._reload()
        self.app.push_screen(ConfirmScreen(
            f"卸载插件 {entry['id']}？",
            f"将删除插件目录与数据，不可恢复。\n{escape(entry['name'])} {escape(entry['version'] or '')}",
            ok_label="卸载", ok_variant="error"), _after)

    def action_reload(self):
        ps = self._system()
        try:
            ps.reload_plugins(None)
        except Exception as e:
            self.app.notify(f"重载失败: {e}", severity="error", timeout=3)
        else:
            self.app.notify("插件已重载", timeout=2)
        self._reload()

    def action_close(self):
        self.app.pop_screen()

    def on_key(self, event):
        if event.key == "escape":
            event.stop()
            self.app.pop_screen()


# Main App

# ──────────────────────────────────────────────────────────────────────




# ---------------------------------------------------------------------------
# 云同步面板 / AI 助手聊天面板（三端共享 .editor_cloud.json / .editor_ai.json）
# ---------------------------------------------------------------------------

_SYNC_ACTION_CN = {
    "upload_new": "上传(新增)", "upload_update": "上传(更新)",
    "download_new": "下载(新增)", "download_update": "下载(更新)",
    "sync_upload": "双向→上传", "sync_download": "双向→下载",
    "sync_upload_update": "双向→上传(新)", "sync_download_update": "双向→下载(新)",
    "delete_remote": "删除远端多余", "delete_local": "删除本地多余",
    "skip": "跳过(一致)", "skip_unchanged": "跳过(一致)",
    "skip_extra_remote": "跳过(远端多余)", "skip_local_extra": "跳过(本地多余)",
}


import re as _re

_SENSITIVE_KEY_RE = _re.compile(r"password|token|secret|cookie|key", _re.I)


class CloudProviderEditScreen(ModalScreen):
    """云 provider 配置弹窗：新增 / 编辑（按驱动 config_schema 动态出表单）。"""

    BINDINGS = [Binding("escape", "close", "取消", priority=True)]

    DEFAULT_CSS = """
    CloudProviderEditScreen { align: center middle; }
    #cpe-dialog { width: 64; height: auto; max-height: 88%; background: $surface; border: thick $primary; padding: 1 2; }
    #cpe-title { text-style: bold; color: $primary; margin-bottom: 1; }
    #cpe-form { height: auto; }
    #cpe-fields { height: auto; }
    #cpe-error { color: $error; margin-top: 1; }
    #cpe-buttons { height: 3; margin-top: 1; }
    CloudProviderEditScreen Input, CloudProviderEditScreen Select { margin-bottom: 1; }
    """

    def __init__(self, entry=None, workspace=None, on_saved=None):
        super().__init__()
        self._entry = entry or {}          # None/{} = 新增
        self._workspace = workspace
        self._on_saved = on_saved
        self._secret_fields = set()

    def compose(self) -> ComposeResult:
        editing = bool(self._entry.get("id"))
        with Vertical(id="cpe-dialog"):
            yield Static(("✏ 编辑网盘配置" if editing else "➕ 新增网盘配置") + "（.editor_cloud.json 三端共享）",
                         id="cpe-title")
            with Vertical(id="cpe-form"):
                yield Select(
                    [(f"{t}  {n}", t) for t, n in _CLOUD_DRIVER_TYPES],
                    prompt="选择驱动类型",
                    id="cpe-type",
                    allow_blank=False,
                )
                yield Vertical(id="cpe-fields")
                yield Input(placeholder="显示名称（回车=默认）", id="cpe-name")
                yield Input(placeholder="远端根目录（mods / cfgs / save）", value="mods", id="cpe-root")
                yield Static("", id="cpe-error")
                with Horizontal(id="cpe-buttons"):
                    yield Button("保存", id="cpe-save", variant="success")
                    yield Button("取消", id="cpe-cancel", variant="default")

    async def on_mount(self):
        sel = self.query_one("#cpe-type", Select)
        if self._entry.get("type"):
            want = _cloud_type_canonical(self._entry["type"])
            if want in {t for _, t in _CLOUD_DRIVER_TYPES}:
                if want != sel.value:
                    self._suppress_change = True  # 程序化赋值会入队一次 Changed，避免二次重建
                    sel.value = want
            else:
                # 已下线驱动（阿里云盘/夸克/天翼）：不预选类型，给出替代指引
                from editor.server import cloud_sync as _cs
                label = getattr(_cs, "REMOVED_DRIVERS", {}).get(want, want)
                self.query_one("#cpe-error", Static).update(
                    "%s已停止支持：请改用 OpenList 代理云存储（下方选择 openlist 新建）。" % label)
        await self._rebuild_fields()
        if self._entry.get("name"):
            self.query_one("#cpe-name", Input).value = self._entry["name"]
        if self._entry.get("remote_root"):
            self.query_one("#cpe-root", Input).value = self._entry["remote_root"]

    def _cloud_mod(self):
        try:
            from editor.server.api import STATE
            if not STATE.workspace_root:
                STATE.workspace_root = str(self._workspace or resolve_workspace(None))
        except Exception:
            pass
        from editor.server import cloud_sync
        return cloud_sync

    async def _rebuild_fields(self):
        """按当前驱动 config_schema 重建输入行（先等旧组件注销完，避免 id 冲突）。"""
        fields = self.query_one("#cpe-fields", Vertical)
        await fields.remove_children()
        self._secret_fields = set()
        itype = self._selected_type()
        if not itype:
            return
        try:
            schema = self._cloud_mod().get_driver(itype, {}).config_schema()
        except Exception as e:
            self.query_one("#cpe-error", Static).update(f"读取驱动 schema 失败: {e}")
            return
        orig_cfg = self._entry.get("config") or {}
        for field, desc in (schema or {}).items():
            secret = bool(_SENSITIVE_KEY_RE.search(field))
            if secret:
                self._secret_fields.add(field)
            cur = orig_cfg.get(field, "")
            shown = "***" if (secret and cur) else cur
            inp = Input(value=shown, placeholder=f"{field} — {desc}",
                        id=f"cpe-f-{field}", password=secret)
            fields.mount(inp)

    def _selected_type(self):
        try:
            return self.query_one("#cpe-type", Select).value
        except Exception:
            return None

    @on(Select.Changed, "#cpe-type")
    async def type_changed(self, _event):
        if getattr(self, "_suppress_change", False):
            self._suppress_change = False
            return
        # 换类型 = 换配置字段；已输入的非敏感值尽量保留
        await self._rebuild_fields()

    @on(Button.Pressed, "#cpe-cancel")
    def action_close(self):
        self.dismiss(False)

    @on(Input.Submitted, "#cpe-name")
    @on(Input.Submitted, "#cpe-root")
    def _submit_save(self, _event):
        self._save()

    @on(Button.Pressed, "#cpe-save")
    def save_pressed(self):
        self._save()

    def _save(self):
        cs = self._cloud_mod()
        itype = self._selected_type()
        if not itype:
            self.query_one("#cpe-error", Static).update("请选择驱动类型")
            return
        cfg = {}
        orig_cfg = self._entry.get("config") or {}
        missing = []
        try:
            schema = cs.get_driver(itype, {}).config_schema()
        except Exception as e:
            self.query_one("#cpe-error", Static).update(f"读取驱动 schema 失败: {e}")
            return
        for field in (schema or {}):
            try:
                raw = self.query_one(f"#cpe-f-{field}", Input).value.strip()
            except Exception:
                raw = ""
            if raw == "***" and field in orig_cfg:
                continue  # 掩码回显 = 保留原值
            if raw:
                cfg[field] = raw
            elif field not in orig_cfg:
                missing.append(field)
        if missing:
            self.query_one("#cpe-error", Static).update(f"缺少配置字段: {', '.join(missing)}")
            return
        name = self.query_one("#cpe-name", Input).value.strip() or itype
        remote_root = self.query_one("#cpe-root", Input).value.strip() or "mods"
        info = {"type": itype, "config": cfg, "name": name, "remote_root": remote_root}
        try:
            if self._entry.get("id"):
                entry = cs.update_provider(self._entry["id"], info)
                action = "已更新"
            else:
                entry = cs.add_provider(info)
                action = "已保存"
        except Exception as e:
            self.query_one("#cpe-error", Static).update(f"保存失败: {type(e).__name__}: {e}")
            return
        if callable(self._on_saved):
            try:
                self._on_saved(entry)
            except Exception:
                pass
        self.dismiss(entry)


_CLOUD_DRIVER_TYPES = [
    ("local", "本地目录"), ("webdav", "WebDAV"), ("openlist", "OpenList/Alist"),
    ("baidu", "百度网盘"), ("123", "123 云盘"),
    ("google_drive", "Google Drive"), ("onedrive", "OneDrive"),
]
# server.cloud_sync.DRIVERS 里的别名 → 上表规范名（Select 只列规范名）
_CLOUD_TYPE_ALIASES = {
    "alist": "openlist", "baidu_netdisk": "baidu",
    "123pan": "123", "gdrive": "google_drive",
}


def _cloud_type_canonical(t):
    t = (t or "").lower()
    return _CLOUD_TYPE_ALIASES.get(t, t)


class AgentConfigScreen(ModalScreen):
    """AI 助手配置弹窗：协议/baseUrl/apiKey/model/temperature + 保存 + 测试连通。"""

    BINDINGS = [Binding("escape", "close", "取消", priority=True)]

    DEFAULT_CSS = """
    AgentConfigScreen { align: center middle; }
    #ac-dialog { width: 68; height: auto; background: $surface; border: thick $primary; padding: 1 2; }
    #ac-title { text-style: bold; color: $primary; margin-bottom: 1; }
    AgentConfigScreen Input, AgentConfigScreen RadioSet { margin-bottom: 1; }
    #ac-perm-label { color: $text-muted; margin-top: 1; }
    #ac-buttons { height: 3; margin-top: 1; }
    #ac-result { color: $text-muted; margin-top: 1; }
    """

    def __init__(self, on_saved=None):
        super().__init__()
        self._on_saved = on_saved

    def compose(self) -> ComposeResult:
        with Vertical(id="ac-dialog"):
            yield Static("🤖 AI 助手配置（.editor_ai.json 三端共享）", id="ac-title")
            yield RadioSet(
                "OpenAI Compatible（/chat/completions）",
                "OpenAI Responses（/responses）",
                "Anthropic Compatible（/messages）",
                id="ac-provider",
            )
            yield Input(placeholder="baseUrl — 如 https://api.example.com/v1", id="ac-baseurl")
            yield Input(placeholder="apiKey — 密钥", id="ac-key", password=True)
            yield Input(placeholder="model — 模型名", id="ac-model")
            yield Input(placeholder="temperature — 0.0 ~ 2.0", id="ac-temp")
            yield Static("AI 权限（写操作是否逐项确认）", id="ac-perm-label")
            yield RadioSet(
                "变更前确认 — 每次修改弹出审批框（默认）",
                "完全访问 — AI 直接修改，不再弹出确认框",
                id="ac-perm",
            )
            with Horizontal(id="ac-buttons"):
                yield Button("保存", id="ac-save", variant="success")
                yield Button("测试连接", id="ac-test", variant="default")
                yield Button("取消", id="ac-cancel", variant="default")
            yield Static("", id="ac-result")

    def on_mount(self):
        from editor.core.env_store import read_ai_settings, AI_PROVIDERS
        s = read_ai_settings()
        want = s.get("provider") if s.get("provider") in AI_PROVIDERS else AI_PROVIDERS[0]
        for i, rb in enumerate(self.query_one("#ac-provider", RadioSet).query(RadioButton)):
            rb.value = (AI_PROVIDERS[i] == want)
        self.query_one("#ac-baseurl", Input).value = s.get("baseUrl") or ""
        self.query_one("#ac-key", Input).value = s.get("apiKey") or ""
        self.query_one("#ac-model", Input).value = s.get("model") or ""
        self.query_one("#ac-temp", Input).value = str(s.get("temperature", 0.7))
        perm = s.get("permissionMode") or "confirm"
        for i, rb in enumerate(self.query_one("#ac-perm", RadioSet).query(RadioButton)):
            rb.value = (i == (1 if perm == "full" else 0))

    def _collect_patch(self):
        from editor.core.env_store import AI_PROVIDERS
        rs = self.query_one("#ac-provider", RadioSet)
        patch = {"provider": AI_PROVIDERS[rs.pressed_index] if rs.pressed_index >= 0 else AI_PROVIDERS[0]}
        patch["baseUrl"] = self.query_one("#ac-baseurl", Input).value.strip()
        patch["apiKey"] = self.query_one("#ac-key", Input).value.strip()
        patch["model"] = self.query_one("#ac-model", Input).value.strip()
        raw = self.query_one("#ac-temp", Input).value.strip()
        if raw:
            patch["temperature"] = float(raw)  # ValueError 由 _save 捕获
        patch["permissionMode"] = (
            "full" if self.query_one("#ac-perm", RadioSet).pressed_index == 1 else "confirm")
        return patch

    @on(Button.Pressed, "#ac-cancel")
    def action_close(self):
        self.dismiss(False)

    @on(Button.Pressed, "#ac-save")
    def save_pressed(self):
        from editor.core.env_store import write_ai_settings
        res = self.query_one("#ac-result", Static)
        try:
            merged = write_ai_settings(self._collect_patch())
        except ValueError:
            res.update("[temperature] 需为数字 (0.0-2.0)")
            return
        except Exception as e:
            res.update(f"保存失败: {type(e).__name__}: {e}")
            return
        res.update(f"✓ 已保存 → .editor_ai.json（provider={merged['provider']} "
                   f"model={merged['model'] or '空'} 权限={merged.get('permissionMode') or 'confirm'}）")
        if callable(self._on_saved):
            try:
                self._on_saved(merged)
            except Exception:
                pass
        self.dismiss(merged)

    @on(Button.Pressed, "#ac-test")
    def test_pressed(self):
        from editor.core.env_store import normalize_ai_settings
        from editor.agent import LlmClient
        res = self.query_one("#ac-result", Static)
        btn = self.query_one("#ac-test", Button)
        try:
            settings = normalize_ai_settings(self._collect_patch())
        except ValueError:
            res.update("[temperature] 需为数字 (0.0-2.0)")
            return
        if not settings.get("apiKey"):
            res.update("⚠ 请先填写 apiKey")
            return
        btn.disabled = True
        res.update("… 连接中")

        def job():
            ok, msg = False, ""
            try:
                client = LlmClient(settings)
                chunks, text = [], ""
                _calls, text = client.round(
                    [{"role": "user", "content": "连通性测试，请只回复：OK"}],
                    [], "你是连通性测试探针，只回复 OK。", on_text=chunks.append)
                ok, msg = True, (text or "".join(chunks)).strip()[:80]
            except BaseException as e:
                msg = f"{type(e).__name__}: {e}"

            def done():
                try:
                    btn.disabled = False
                    res.update(f"✓ 连接成功，模型回复：{msg}" if ok else f"✗ 连接失败：{msg}")
                except Exception:
                    pass
            self.app.call_from_thread(done)

        self.run_worker(job, thread=True, group="agent-config-test", exclusive=True)


def _fmt_size(n):
    n = int(n or 0)
    if n < 1024:
        return "%dB" % n
    if n < 1024 * 1024:
        return "%.1fKB" % (n / 1024)
    return "%.1fMB" % (n / 1024 / 1024)


class TtsScreen(ModalScreen):
    """配音 (TTS) 面板：配置 / 测试连接 / 文本合成 / 素材管理。

    配置读写 .editor_ai.json 的 tts* 字段（三端共享）；素材落在
    <mod>/audio/tts/，可选登记 AudioCfg（url="audio/tts/<key>"，与落盘路径
    一致、不带扩展名，不写 TalkCfg.vocals）。
    """

    BINDINGS = [Binding("escape", "close", "关闭", priority=True)]

    _TTS_PROVIDERS = ("aliyun", "minimax")

    DEFAULT_CSS = """
    TtsScreen { align: center middle; }
    #tts-dialog { width: 84; height: 90%; background: $surface; border: thick $primary; padding: 1 2; }
    #tts-title { text-style: bold; color: $primary; margin-bottom: 1; }
    #tts-section, .tts-section { text-style: bold; margin-top: 1; }
    TtsScreen Input, TtsScreen RadioSet, TtsScreen Checkbox { margin-bottom: 1; }
    #tts-cfg-buttons, #tts-mat-buttons { height: 3; }
    #tts-synth-row { height: auto; }
    #tts-keyname { width: 32; }
    #tts-mats { height: 8; border: round $panel; margin-bottom: 1; }
    #tts-result { height: 7; margin-top: 1; border: round $panel; }
    #tts-hint { color: $text-muted; margin-top: 1; }
    """

    def __init__(self, mod_root=None, mod_name=None, workspace=None):
        super().__init__()
        self._mod_root = mod_root
        self._mod_name = mod_name
        self._workspace = workspace

    def compose(self) -> ComposeResult:
        with VerticalScroll(id="tts-dialog"):
            yield Static(
                "🔊 配音 (TTS)（.editor_ai.json 三端共享） · 模组："
                + (self._mod_name or "（未选定）"),
                id="tts-title")
            yield RadioSet(
                "阿里云 DashScope（CosyVoice / Qwen-TTS）",
                "MiniMax（speech-02 系列）",
                id="tts-provider",
            )
            yield Input(placeholder="apiKey — 密钥（已保存时显示 ***，回车保存保留原值）",
                        id="tts-key", password=True)
            yield Input(placeholder="groupId — 仅 MiniMax 需要", id="tts-group")
            yield Input(placeholder="baseUrl — 留空用官方默认", id="tts-baseurl")
            yield Input(placeholder="model — 如 cosyvoice-v2 / qwen-tts-latest", id="tts-model")
            yield Input(placeholder="voice — 音色 ID（留空用服务商默认）", id="tts-voice")
            yield Input(placeholder="speed — 语速 0.5 ~ 2.0", id="tts-speed")
            with Horizontal(id="tts-cfg-buttons"):
                yield Button("保存配置", id="tts-save", variant="success")
                yield Button("测试连接", id="tts-test", variant="default")
                yield Button("音色列表", id="tts-voices", variant="default")
            yield Static("合成并保存", classes="tts-section")
            yield Input(placeholder="合成文本 — 要转成语音的台词", id="tts-text")
            with Horizontal(id="tts-synth-row"):
                yield Input(placeholder="文件名 key（可选，缺省按时间戳）", id="tts-keyname")
                yield Checkbox("登记 AudioCfg", id="tts-regcfg", value=True)
                yield Button("合成并保存", id="tts-synth", variant="primary")
            yield Static("素材（mod/audio/tts/）", classes="tts-section")
            yield OptionList(id="tts-mats")
            with Horizontal(id="tts-mat-buttons"):
                yield Button("刷新素材", id="tts-reload", variant="default")
                yield Button("删除选中", id="tts-del", variant="error")
            yield RichLog(id="tts-result", markup=False, wrap=True)
            yield Static("Esc 关闭 · 测试/合成/音色列表在后台线程执行 · 合成前请先在左侧树选择模组",
                         id="tts-hint")

    def on_mount(self):
        from editor.core.env_store import read_ai_settings
        s = read_ai_settings()
        want = s.get("ttsProvider") if s.get("ttsProvider") in self._TTS_PROVIDERS \
            else self._TTS_PROVIDERS[0]
        for i, rb in enumerate(self.query_one("#tts-provider", RadioSet).query(RadioButton)):
            rb.value = (self._TTS_PROVIDERS[i] == want)
        self.query_one("#tts-key", Input).value = "***" if s.get("ttsApiKey") else ""
        self.query_one("#tts-group", Input).value = s.get("ttsGroupId") or ""
        self.query_one("#tts-baseurl", Input).value = s.get("ttsBaseUrl") or ""
        self.query_one("#tts-model", Input).value = s.get("ttsModel") or ""
        self.query_one("#tts-voice", Input).value = s.get("ttsVoice") or ""
        speed = s.get("ttsSpeed")
        self.query_one("#tts-speed", Input).value = "" if speed in (None, 1.0) else str(speed)
        self._reload_materials()

    # ---- 配置 ----
    def _collect_patch(self):
        """只收集 tts* 字段的 patch；apiKey 为 *** 掩码时保留原值（不写入 patch）。"""
        rs = self.query_one("#tts-provider", RadioSet)
        patch = {"ttsProvider": self._TTS_PROVIDERS[rs.pressed_index]
                 if rs.pressed_index >= 0 else self._TTS_PROVIDERS[0]}
        key = self.query_one("#tts-key", Input).value.strip()
        if key != "***":
            patch["ttsApiKey"] = key
        patch["ttsGroupId"] = self.query_one("#tts-group", Input).value.strip()
        patch["ttsBaseUrl"] = self.query_one("#tts-baseurl", Input).value.strip()
        patch["ttsModel"] = self.query_one("#tts-model", Input).value.strip()
        patch["ttsVoice"] = self.query_one("#tts-voice", Input).value.strip()
        raw = self.query_one("#tts-speed", Input).value.strip()
        if raw:
            patch["ttsSpeed"] = float(raw)  # ValueError 由调用方捕获
        return patch

    def _merged_settings(self):
        from editor.core.env_store import read_ai_settings
        merged = dict(read_ai_settings())
        merged.update(self._collect_patch())
        return merged

    @on(Button.Pressed, "#tts-save")
    def save_pressed(self):
        from editor.core.env_store import write_ai_settings
        res = self.query_one("#tts-result", RichLog)
        try:
            patch = self._collect_patch()
        except ValueError:
            self._log("⚠ 语速需为数字（0.5 ~ 2.0）")
            return
        try:
            merged = write_ai_settings(patch)
        except Exception as e:
            self._log(f"✗ 保存失败: {type(e).__name__}: {e}")
            return
        self.query_one("#tts-key", Input).value = "***" if merged.get("ttsApiKey") else ""
        self._log(f"✓ 已保存 → .editor_ai.json（ttsProvider={merged.get('ttsProvider') or '空'}）")

    @on(Button.Pressed, "#tts-test")
    def test_pressed(self):
        btn = self.query_one("#tts-test", Button)
        try:
            settings = self._merged_settings()
        except ValueError:
            self._log("⚠ 语速需为数字（0.5 ~ 2.0）")
            return
        provider = settings.get("ttsProvider")
        if not provider:
            self._log("⚠ 请先选择服务商（阿里云 / MiniMax）")
            return
        if not (settings.get("ttsApiKey") or "").strip():
            self._log("⚠ 请先填写 apiKey")
            return
        btn.disabled = True
        self._log(f"… 连接中（{provider}）")

        def job():
            out = {"ok": False, "error": ""}
            try:
                from editor.server import tts_service
                out = tts_service.test_connection(provider, settings)
            except Exception as e:  # noqa: BLE001
                out = {"ok": False, "error": f"{type(e).__name__}: {e}"}

            def done():
                try:
                    btn.disabled = False
                    if out.get("ok"):
                        self._log(f"✓ {out.get('detail') or '连接成功'}")
                    else:
                        self._log(f"✗ {out.get('error') or '连接失败'}")
                except Exception:
                    pass
            self.app.call_from_thread(done)

        self.run_worker(job, thread=True, group="tts-test", exclusive=True)

    @on(Button.Pressed, "#tts-voices")
    def voices_pressed(self):
        btn = self.query_one("#tts-voices", Button)
        try:
            settings = self._merged_settings()
        except ValueError:
            self._log("⚠ 语速需为数字（0.5 ~ 2.0）")
            return
        provider = settings.get("ttsProvider")
        if not provider:
            self._log("⚠ 请先选择服务商（阿里云 / MiniMax）")
            return
        btn.disabled = True
        self._log(f"… 拉取音色列表（{provider}）")

        def job():
            msg = ""
            try:
                from editor.server import tts_service
                voices, source = tts_service.list_voices(provider, settings)
                preview = ", ".join(f"{v['id']}({v['name']})" for v in voices[:8])
                msg = (f"✓ 音色 {len(voices)} 个（{source}）：{preview}"
                       + (" …" if len(voices) > 8 else ""))
            except Exception as e:  # noqa: BLE001
                from editor.server.tts_service import TtsError
                msg = "✗ 拉取失败：" + (str(e) if isinstance(e, TtsError)
                                       else f"{type(e).__name__}: {e}")

            def done():
                try:
                    btn.disabled = False
                    self._log(msg)
                except Exception:
                    pass
            self.app.call_from_thread(done)

        self.run_worker(job, thread=True, group="tts-voices", exclusive=True)

    # ---- 合成 ----
    @on(Button.Pressed, "#tts-synth")
    def synth_pressed(self):
        btn = self.query_one("#tts-synth", Button)
        if not self._mod_root:
            self._log("⚠ 未选择模组 — 请先在左侧树打开一个模组")
            return
        text = self.query_one("#tts-text", Input).value.strip()
        if not text:
            self._log("⚠ 请输入要合成的文本")
            return
        try:
            settings = self._merged_settings()
        except ValueError:
            self._log("⚠ 语速需为数字（0.5 ~ 2.0）")
            return
        provider = settings.get("ttsProvider")
        if not provider:
            self._log("⚠ 请先选择服务商（阿里云 / MiniMax）")
            return
        key = self.query_one("#tts-keyname", Input).value.strip()
        register = self.query_one("#tts-regcfg", Checkbox).value
        mod_root = self._mod_root
        voice = settings.get("ttsVoice") or None
        title = text[:24]
        btn.disabled = True
        self._log(f"… 正在合成（{provider}，{len(text)} 字）…")

        def job():
            err, line = "", ""
            try:
                from editor.server import tts_service, tts_store
                audio, ext = tts_service.synthesize(provider, text, voice=voice,
                                                    settings=settings)
                info = tts_store.save_audio(mod_root, audio, ext, key=key or None, ogg=True)
                line = (f"✓ 已保存 {info['path']}（{info['bytes']} 字节，"
                        + ("已转 Ogg" if info["convertedOgg"] else f"格式 {info['ext']}") + "）")
                if register:
                    cfg_dir = cfg_path(mod_root, "AudioCfg").parent
                    new_id = tts_store.register_audio_cfg(cfg_dir, info["key"], title=title)
                    line += f" · 已登记 AudioCfg id={new_id}（url=audio/tts/{info['key']}）"
            except Exception as e:  # noqa: BLE001
                from editor.server.tts_service import TtsError
                from editor.server.tts_store import TtsStoreError
                err = str(e) if isinstance(e, (TtsError, TtsStoreError)) \
                    else f"{type(e).__name__}: {e}"

            def done():
                try:
                    btn.disabled = False
                    if err:
                        self._log(f"✗ 合成失败：{err}")
                    else:
                        self._log(line)
                        self._reload_materials()
                except Exception:
                    pass
            self.app.call_from_thread(done)

        self.run_worker(job, thread=True, group="tts-synth", exclusive=True)

    # ---- 素材 ----
    def _reload_materials(self):
        lst = self.query_one("#tts-mats", OptionList)
        lst.clear_options()
        if not self._mod_root:
            lst.add_option(Option("（未选择模组 — Esc 后在左侧树打开一个模组）", id=None))
            return
        try:
            from editor.server import tts_store
            items = tts_store.list_materials(self._mod_root)
        except Exception as e:  # noqa: BLE001
            from editor.server.tts_store import TtsStoreError
            msg = str(e) if isinstance(e, TtsStoreError) else f"{type(e).__name__}: {e}"
            lst.add_option(Option(f"⚠ 读取失败：{msg}", id=None))
            return
        if not items:
            lst.add_option(Option("（暂无配音素材）", id=None))
            return
        for it in items:
            lst.add_option(Option(f"{it['path']}  {_fmt_size(it['size'])}", id=it["path"]))
        lst.highlighted = 0

    @on(Button.Pressed, "#tts-reload")
    def reload_pressed(self):
        self._reload_materials()

    @on(Button.Pressed, "#tts-del")
    def del_pressed(self):
        lst = self.query_one("#tts-mats", OptionList)
        rel = None
        try:
            opt = lst.get_option_at_index(lst.highlighted or 0)
            rel = opt.id
        except Exception:
            pass
        if not rel:
            self._log("⚠ 先在列表中选择一个素材")
            return
        # 列表返回的 id 已是完整相对路径（audio/tts/...），避免再拼一次前缀
        target = rel if rel.startswith("audio/tts/") else "audio/tts/" + rel

        def _after(ok):
            if not ok:
                return
            try:
                from editor.server import tts_store
                tts_store.delete_material(self._mod_root, target)
                self._log(f"✓ 已删除 {target}")
            except Exception as e:  # noqa: BLE001
                from editor.server.tts_store import TtsStoreError
                msg = str(e) if isinstance(e, TtsStoreError) else f"{type(e).__name__}: {e}"
                self._log(f"✗ 删除失败：{msg}")
            self._reload_materials()

        self.app.push_screen(ConfirmScreen(
            "删除配音素材",
            f"确定删除 {target} 吗？\n仅删除音频文件，不改动 AudioCfg。",
            ok_label="删除", ok_variant="error"), _after)

    def _log(self, text):
        try:
            self.query_one("#tts-result", RichLog).write(text)
        except Exception:
            pass

    def action_close(self):
        self.dismiss(None)


class CloudScreen(ModalScreen):
    """云同步面板：左侧 provider 列表 + 测试连接，右侧方向/选项 + 同步进度。"""

    BINDINGS = [Binding("escape", "close", "关闭", priority=True)]

    DEFAULT_CSS = """
    CloudScreen { align: center middle; }
    #cloud-dialog { width: 92%; height: 82%; background: $surface; border: thick $primary; padding: 0 1; }
    #cloud-title { text-style: bold; color: $primary; padding: 1 1 0 1; }
    #cloud-body { height: 1fr; }
    #cloud-left { width: 42%; padding: 0 1; }
    #cloud-right { width: 1fr; padding: 0 1; }
    #cloud-list { height: 3fr; border: round $panel; }
    #cloud-detail { color: $text-muted; margin-top: 1; }
    #cloud-actions { height: 3; margin-top: 1; }
    #cloud-progress { margin: 1 0; }
    #cloud-result { height: 1fr; border: round $panel; }
    #cloud-hint { color: $text-muted; padding: 0 1 1 1; }
    """

    def __init__(self, mod_name=None, workspace=None):
        super().__init__()
        self._mod_name = mod_name
        self._workspace = workspace
        self._providers = []
        self._selected = None
        self._sync_poll = None

    def compose(self) -> ComposeResult:
        with Vertical(id="cloud-dialog"):
            yield Static("☁️  云同步（.editor_cloud.json 三端共享）", id="cloud-title")
            with Horizontal(id="cloud-body"):
                with Vertical(id="cloud-left"):
                    yield Static("网盘 Providers")
                    yield OptionList(id="cloud-list")
                    yield Static("", id="cloud-detail")
                    with Horizontal(id="cloud-actions"):
                        yield Button("测试", id="cloud-test", variant="default")
                        yield Button("新增", id="cloud-add", variant="primary")
                        yield Button("编辑", id="cloud-edit", variant="default")
                        yield Button("删除", id="cloud-remove", variant="error")
                        yield Button("刷新", id="cloud-reload", variant="default")
                with Vertical(id="cloud-right"):
                    yield Static(f"同步模组：[b]{self._mod_name or '(未选定)'}[/b]")
                    yield RadioSet(
                        "上传 upload（本地→远端）",
                        "下载 download（远端→本地）",
                        "双向 sync（新者为准）",
                        id="cloud-direction",
                    )
                    yield Checkbox("DRY-RUN 预览（不写盘）", id="cloud-dry", value=True)
                    yield Checkbox("删除远端多余文件", id="cloud-del")
                    yield Button("开始同步", id="cloud-sync", variant="success")
                    yield ProgressBar(id="cloud-progress", show_eta=False)
                    yield RichLog(id="cloud-result", markup=False, wrap=True)
            yield Static("Esc 关闭 · 同步在后台线程执行，可 Esc 随时关闭面板", id="cloud-hint")

    def on_mount(self):
        self._reload_providers()

    # ---- providers ----
    def _cloud_mod(self):
        # 注入工作区后再取模块：_cloud_config_path 依赖 STATE.workspace_root
        try:
            from editor.server.api import STATE
            if not STATE.workspace_root:
                STATE.workspace_root = str(self._workspace or resolve_workspace(None))
        except Exception:
            pass
        from editor.server import cloud_sync
        return cloud_sync

    def _reload_providers(self):
        lst = self.query_one("#cloud-list", OptionList)
        lst.clear_options()
        self._providers = []
        try:
            self._providers = self._cloud_mod().list_providers()
        except Exception as e:
            self._log(f"⚠ 读取配置失败：{e}")
        if not self._providers:
            lst.add_option(Option("（尚未配置网盘 — 点下方「新增」添加）", id=None))
            self.query_one("#cloud-detail", Static).update("")
            return
        for p in self._providers:
            lst.add_option(Option(f"{p.get('name') or p.get('id')}  [{p.get('type')}]", id=p.get("id")))
        lst.highlighted = 0
        self._sync_selected_from_list()

    @on(OptionList.OptionSelected)
    def provider_selected(self, _event):
        self._sync_selected_from_list()

    def on_option_list_option_highlighted(self, _event):
        self._sync_selected_from_list()

    def _sync_selected_from_list(self):
        lst = self.query_one("#cloud-list", OptionList)
        oid = None
        try:
            opt = lst.get_option_at_index(lst.highlighted or 0)
            oid = opt.id
        except Exception:
            pass
        self._selected = next((p for p in self._providers if p.get("id") == oid), None)
        if self._selected:
            self.query_one("#cloud-detail", Static).update(
                f"id: {self._selected['id']}\n远端根: {self._selected.get('remote_root')}")
        else:
            self.query_one("#cloud-detail", Static).update("")

    @on(Button.Pressed, "#cloud-reload")
    def reload_pressed(self):
        self._reload_providers()

    # ---- 配置（新增 / 编辑 / 删除）----
    @on(Button.Pressed, "#cloud-add")
    def add_pressed(self):
        self.app.push_screen(CloudProviderEditScreen(
            workspace=self._workspace,
            on_saved=lambda _e: self._reload_providers))

    @on(Button.Pressed, "#cloud-edit")
    def edit_pressed(self):
        if not self._selected:
            self._log("⚠ 先在左侧选择一个网盘")
            return
        self.app.push_screen(CloudProviderEditScreen(
            entry=dict(self._selected), workspace=self._workspace,
            on_saved=lambda _e: self._reload_providers))

    @on(Button.Pressed, "#cloud-remove")
    def remove_pressed(self):
        if not self._selected:
            self._log("⚠ 先在左侧选择一个网盘")
            return
        entry = dict(self._selected)

        def _after(ok):
            if not ok:
                return
            try:
                self._cloud_mod().remove_provider(entry["id"])
                self._log(f"✓ 已删除 {entry['id']}（{entry.get('name')}）— 远端文件不受影响")
            except Exception as e:
                self._log(f"✗ 删除失败：{type(e).__name__}: {e}")
            self._reload_providers()

        self.app.push_screen(ConfirmScreen(
            "删除网盘配置",
            f"确定删除 {entry.get('name')} [{entry.get('id')}] 吗？\n仅移除本机配置，远端文件不受影响。",
            ok_label="删除", ok_variant="error"), _after)

    @on(Button.Pressed, "#cloud-test")
    def test_pressed(self):
        if not self._selected:
            self._log("⚠ 先在左侧选择一个网盘")
            return
        entry = dict(self._selected)
        btn = self.query_one("#cloud-test", Button)
        btn.disabled = True
        self._log(f"… 正在测试 {entry['id']} ({entry.get('type')}) …")

        def job():
            ok, msg = False, ""
            try:
                driver = self._cloud_mod().get_driver(entry.get("type"), entry.get("config") or {})
                driver.test()
                ok = True
            except Exception as e:
                msg = f"{type(e).__name__}: {e}"

            def done():
                try:
                    btn.disabled = False
                    self._log(("✓ 连接成功 " if ok else f"✗ 连接失败 {msg}") + f"  [{entry['id']}]")
                except Exception:
                    pass
            self.app.call_from_thread(done)

        self.run_worker(job, thread=True, group="cloud-test", exclusive=True)

    # ---- 同步 ----
    @on(Button.Pressed, "#cloud-sync")
    def sync_pressed(self):
        if not self._mod_name:
            self._log("⚠ 未选定模组，无法同步")
            return
        if self._sync_poll is not None:
            self._log("… 已有同步在进行")
            return
        if not self._selected:
            self._log("⚠ 先在左侧选择一个网盘")
            return
        direction = ("upload", "download", "sync")[self.query_one("#cloud-direction", RadioSet).pressed_index]
        dry = self.query_one("#cloud-dry", Checkbox).value
        delete_extra = self.query_one("#cloud-del", Checkbox).value
        cs = self._cloud_mod()
        provider_id = self._selected["id"]
        self._log(f"▶ 同步 {self._mod_name} [{('DRY-RUN ' if dry else '') + direction}] → {provider_id}")
        bar = self.query_one("#cloud-progress", ProgressBar)
        bar.update(progress=0, total=None)

        def job():
            error, result = None, None
            try:
                result = cs.sync_mod_folder(
                    provider_id=provider_id, direction=direction, mod_name=self._mod_name,
                    dry_run=dry, delete_extra=delete_extra)
            except BaseException as e:
                error = f"{type(e).__name__}: {e}"
            self.app.call_from_thread(self._sync_done, result, error)

        self.run_worker(job, thread=True, group="cloud-sync", exclusive=True)
        self._sync_poll = self.set_interval(0.4, self._poll_sync)

    def _poll_sync(self):
        try:
            st = self._cloud_mod().sync_status()
        except Exception:
            return
        bar = self.query_one("#cloud-progress", ProgressBar)
        total = st.get("total") or 0
        bar.update(total=total or None, progress=st.get("progress") or 0)

    def _sync_done(self, result, error=None):
        if self._sync_poll is not None:
            self._sync_poll.stop()
            self._sync_poll = None
        if error:
            self._log(f"✗ 同步失败：{error}")
            return
        counts = {}
        errors = []
        for row in result.get("results") or []:
            if row.get("ok"):
                counts[row.get("action", "?")] = counts.get(row.get("action", "?"), 0) + 1
            else:
                errors.append(row)
        head = "DRY-RUN 预览（未写盘）" if result.get("dry_run") else "同步完成"
        self._log(f"■ {head}：{result.get('total', 0)} 个文件")
        for action, n in sorted(counts.items(), key=lambda kv: -kv[1]):
            self._log(f"   {_SYNC_ACTION_CN.get(action, action)}（{action}）× {n}")
        for row in errors[:10]:
            self._log(f"   ✗ {row.get('rel')} — {row.get('error')}")
        if len(errors) > 10:
            self._log(f"   … 其余 {len(errors) - 10} 项失败省略")
        self._log("")

    def _log(self, text):
        try:
            self.query_one("#cloud-result", RichLog).write(text)
        except Exception:
            pass

    def action_close(self):
        if self._sync_poll is not None:
            self._sync_poll.stop()
            self._sync_poll = None
        self.dismiss(None)


class AgentHistoryScreen(ModalScreen):
    """AI 会话历史面板：列出 .editor_ai_history 里的会话，预览 / 恢复 / 删除 / 清空。

    恢复 = 把该会话的 history 归一化后载入 AgentChatScreen 的 engine（可接着
    对话，继续写回同一会话文件）；本面板只做选择与展示，不直接持有 engine。
    """

    BINDINGS = [Binding("escape", "close", "关闭", priority=True)]

    DEFAULT_CSS = """
    AgentHistoryScreen { align: center middle; }
    #ah-dialog { width: 86; height: 88%; background: $surface; border: thick $primary; padding: 1 2; }
    #ah-title { text-style: bold; color: $primary; margin-bottom: 1; }
    #ah-list { height: 12; border: round $panel; margin-bottom: 1; }
    #ah-preview { height: 1fr; border: round $panel; margin-bottom: 1; }
    #ah-buttons { height: 3; }
    #ah-hint { color: $text-muted; padding: 0 0 1 0; }
    """

    def __init__(self, on_resume=None):
        super().__init__()
        self._on_resume = on_resume
        self._sessions = []

    def compose(self) -> ComposeResult:
        with Vertical(id="ah-dialog"):
            yield Static("📜 AI 会话历史（CLI / TUI 共享存储）", id="ah-title")
            yield OptionList(id="ah-list")
            yield RichLog(id="ah-preview", markup=False, wrap=True)
            with Horizontal(id="ah-buttons"):
                yield Button("▶ 继续会话", id="ah-resume", variant="primary")
                yield Button("🗑 删除", id="ah-delete", variant="error")
                yield Button("🧹 清空", id="ah-clear", variant="error")
                yield Button("⟳ 刷新", id="ah-reload", variant="default")
                yield Button("关闭", id="ah-close", variant="default")
            yield Static("↑↓ 选择并预览 · 回车 / 「继续会话」载入聊天面板接着对话", id="ah-hint")

    def on_mount(self):
        self._reload()

    # ---- 列表 ----
    def _reload(self):
        from editor.agent import history_store
        lst = self.query_one("#ah-list", OptionList)
        lst.clear_options()
        self._sessions = history_store.list_sessions()
        if not self._sessions:
            lst.add_option(Option("（暂无会话 — 聊天面板会自动记录历史）", id=None))
            self._preview_selected()
            return
        for s in self._sessions:
            title = escape(s.get("title") or "（无标题）")
            label = (f"{s.get('updated_at') or '-'}  {title}"
                     f"  ({s.get('mod') or '-'} · {s.get('message_count') or 0} 条)")
            lst.add_option(Option(label, id=s.get("id")))
        lst.highlighted = 0
        self._preview_selected()

    def _selected(self):
        lst = self.query_one("#ah-list", OptionList)
        try:
            opt = lst.get_option_at_index(lst.highlighted or 0)
        except Exception:
            return None
        return next((s for s in self._sessions if s.get("id") == opt.id), None)

    # ---- 预览 ----
    @on(OptionList.OptionSelected)
    def option_selected(self, _event):
        self._resume_selected()

    def on_option_list_option_highlighted(self, _event):
        self._preview_selected()

    def _preview_selected(self):
        from editor.agent import history_store
        s = self._selected()
        prev = self.query_one("#ah-preview", RichLog)
        try:
            prev.clear()
        except Exception:
            pass
        if not s:
            prev.write("（未选择会话）")
            return
        full = history_store.load_session(s["id"]) or {}
        lines = history_store.render_transcript(full.get("history") or []).splitlines()
        if len(lines) > 200:
            lines = ["（较早 %d 行已省略）" % (len(lines) - 200)] + lines[-200:]
        prev.write(f"{s.get('title') or '（无标题）'}")
        prev.write(f"{s.get('id')} · {s.get('provider') or '-'} · 模组 {s.get('mod') or '-'} · "
                   f"{s.get('message_count') or 0} 条消息")
        prev.write("─" * 46)
        if lines:
            for ln in lines:
                prev.write(ln)
        else:
            prev.write("（空会话）")

    # ---- 动作 ----
    def _resume_selected(self):
        s = self._selected()
        if not s:
            return
        if callable(self._on_resume):
            self.dismiss(s["id"])
            try:
                self._on_resume(s["id"])
            except Exception:
                pass

    @on(Button.Pressed, "#ah-resume")
    def resume_pressed(self):
        self._resume_selected()

    @on(Button.Pressed, "#ah-delete")
    def delete_pressed(self):
        s = self._selected()
        if not s:
            return

        def _cb(ok):
            if not ok:
                return
            from editor.agent import history_store
            history_store.delete_session(s["id"])
            self._reload()

        self.app.push_screen(ConfirmScreen(
            "删除会话", f"删除会话 {s['id']} ？\n{s.get('title') or '（无标题）'}",
            ok_label="删除"), _cb)

    @on(Button.Pressed, "#ah-clear")
    def clear_pressed(self):
        if not self._sessions:
            return

        def _cb(ok):
            if not ok:
                return
            from editor.agent import history_store
            history_store.clear_sessions()
            self._reload()

        self.app.push_screen(ConfirmScreen(
            "清空历史", f"确认清空全部 {len(self._sessions)} 个 AI 会话历史？",
            ok_label="清空"), _cb)

    @on(Button.Pressed, "#ah-reload")
    def reload_pressed(self):
        self._reload()

    @on(Button.Pressed, "#ah-close")
    def action_close(self):
        self.dismiss(None)


class AskScreen(ModalScreen[str]):
    """ask_user 提问弹窗：AI 主动向用户提问（选项按钮 + 自由输入 + 跳过）。

    dismiss 值为回答文本直接回填给模型；跳过 / 空输入 / Esc 统一
    dismiss("用户未回答")。与写操作审批无关——完全访问模式同样要弹。
    """

    DEFAULT_CSS = """
    AskScreen { align: center middle; }
    #ask-dialog {
        width: 64;
        height: auto;
        max-height: 80%;
        background: $surface;
        border: thick $primary;
        padding: 1 2;
    }
    #ask-title { text-style: bold; color: $primary; }
    #ask-text { margin: 1 0; }
    #ask-options { height: auto; margin-bottom: 1; }
    #ask-options Button { margin-right: 1; }
    #ask-inputbar { height: 3; margin-bottom: 1; }
    #ask-input { width: 1fr; }
    #ask-hint { color: $text-muted; }
    """

    def __init__(self, question: str, options=None):
        super().__init__()
        self._question = question
        self._options = [str(o).strip() for o in (options or []) if str(o).strip()][:6]

    def compose(self) -> ComposeResult:
        with Vertical(id="ask-dialog"):
            yield Static("🤖 AI 向你提问", id="ask-title")
            yield Static(self._question, id="ask-text")
            if self._options:
                with Horizontal(id="ask-options"):
                    for i, opt in enumerate(self._options):
                        yield Button(f"{i + 1}. {opt}", id=f"ask-opt-{i}")
            with Horizontal(id="ask-inputbar"):
                yield Input(placeholder="或输入自定义回答…", id="ask-input")
                yield Button("发送", id="ask-send", variant="primary")
                yield Button("跳过", id="ask-skip")
            yield Static("点选项或输入回答后发送；跳过 / 留空 = 未回答", id="ask-hint")

    def on_mount(self):
        self.query_one("#ask-input", Input).focus()

    @on(Button.Pressed)
    def _button(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid.startswith("ask-opt-"):
            self.dismiss(self._options[int(bid[len("ask-opt-"):])])
        elif bid == "ask-send":
            text = self.query_one("#ask-input", Input).value.strip()
            self.dismiss(text or "用户未回答")
        elif bid == "ask-skip":
            self.dismiss("用户未回答")

    @on(Input.Submitted, "#ask-input")
    def on_submit(self, event: Input.Submitted):
        self.dismiss(event.value.strip() or "用户未回答")

    def on_key(self, event):
        if event.key == "escape":
            event.stop()
            self.dismiss("用户未回答")


class AgentChatScreen(ModalScreen):
    """AI 助手聊天面板：TextArea 流式回复 + 工具记录 + ConfirmScreen 审批桥接。"""

    BINDINGS = [Binding("escape", "close", "关闭", priority=True)]

    DEFAULT_CSS = """
    AgentChatScreen { align: center middle; }
    #agent-dialog { width: 90%; height: 85%; background: $surface; border: thick $primary; padding: 0 1; }
    #agent-title { text-style: bold; color: $primary; padding: 1 1 0 1; }
    #agent-log { height: 1fr; border: round $panel; margin: 1 0; }
    #agent-inputbar { height: 3; }
    #agent-input { width: 1fr; }
    #agent-send { margin-left: 1; }
    #agent-hint { color: $text-muted; padding: 0 1 1 1; }
    """

    def __init__(self, mod_root=None, mod_name=None, workspace=None):
        super().__init__()
        self._mod_root = mod_root
        self._mod_name = mod_name
        self._workspace = workspace
        self._client = None
        self._engine = None
        self._session = None  # AI 会话历史（.editor_ai_history），首次发送时创建
        self._transcript = ""
        self._busy = False
        self._pending = queue.SimpleQueue()  # 流式 delta 缓冲（worker 线程投递，UI 线程攒批刷出）

    def compose(self) -> ComposeResult:
        with Vertical(id="agent-dialog"):
            yield Static("🤖 AI 助手", id="agent-title")
            yield TextArea(id="agent-log", read_only=True, soft_wrap=True,
                           show_line_numbers=False, show_cursor=False)
            with Horizontal(id="agent-inputbar"):
                yield Input(placeholder="输入任务或问题…（exit 关闭面板）", id="agent-input")
                yield Button("📜 历史", id="agent-history", variant="default")
                yield Button("⚙ 配置", id="agent-config", variant="default")
                yield Button("发送", id="agent-send", variant="primary")
            yield Static("Esc 关闭 · 修改会先弹出确认框（选择「允许」或「取消」）", id="agent-hint")

    def on_mount(self):
        self.set_interval(0.1, self._flush_pending)  # 流式攒批刷帧：每 100ms 至多一次增量插入
        self._init_chat()

    def _init_chat(self, note=None):
        from editor.core.env_store import read_ai_settings, is_ai_settings_meaningful
        settings = read_ai_settings()
        self._permission_mode = settings.get("permissionMode") or "confirm"
        full_access = self._permission_mode == "full"
        title = f"🤖 AI 助手  {settings['provider']} · {settings['model'] or '-'}"
        if full_access:
            title += "  · 完全访问"
        if self._mod_name:
            title += f"  · 模组：{self._mod_name}"
        self.query_one("#agent-title", Static).update(title)
        self.query_one("#agent-hint", Static).update(
            "Esc 关闭 · 完全访问模式：AI 修改直接执行，不再弹出确认框"
            if full_access else
            "Esc 关闭 · 修改会先弹出确认框（选择「允许」或「取消」）")
        log = self.query_one("#agent-log", TextArea)
        if note:
            self._append(note + "\n")
        if not is_ai_settings_meaningful(settings):
            log.text = ("[未配置] .editor_ai.json 缺少 apiKey。\n"
                        "点下方「⚙ 配置」直接填写（与 CLI / GUI 三端共享），"
                        "或运行 python run_cli.py agent config。")
            self._transcript = log.text
            self.query_one("#agent-input", Input).disabled = True
            return
        if not settings.get("model"):
            log.text = ("[未配置] model 为空。点下方「⚙ 配置」补全 model 后再使用。")
            self._transcript = log.text
            self.query_one("#agent-input", Input).disabled = True
            return
        from editor.agent import LlmClient, AgentTools, AgentEngine
        tools = AgentTools()
        tools.use_mod(self._mod_root, self._workspace)
        mod_ctx = (f"当前模组：{self._mod_name}。默认只修改这个模组，不要读取或修改其他模组的内容。"
                   if self._mod_name else "")
        self._engine = AgentEngine(
            tools, confirm=self._confirm_bridge, ask=self._ask_bridge,
            on_text=self._on_text,
            on_tool_round_text=self._on_round_text, on_tool_result=self._on_tool_result,
            on_retry=self._on_retry, mod_context=mod_ctx)
        self._client = LlmClient(settings)
        self._session = None  # 引擎重建后旧会话不再续写，避免空 history 覆盖会话文件
        if not note:
            log.text = "已就绪。描述你想对模组做的修改，例如：\n  把开局事件的标题改成「新的开始」\n  给某角色加一段对白\n"
        self._transcript = log.text
        self.query_one("#agent-input", Input).disabled = False
        self.query_one("#agent-input", Input).focus()

    @on(Button.Pressed, "#agent-config")
    def config_pressed(self):
        self.app.push_screen(AgentConfigScreen(
            on_saved=lambda _s: self._init_chat(note="✓ 配置已保存，会话已按新配置重新加载。")))

    @on(Button.Pressed, "#agent-history")
    def history_pressed(self):
        self.app.push_screen(AgentHistoryScreen(on_resume=self._load_history_session))

    # ---- 会话历史（.editor_ai_history，与 CLI 共享）----
    def _persist_session(self):
        """每轮对话结束后落盘（worker 线程调用；失败静默，不影响聊天）。"""
        if self._engine is None:
            return
        try:
            from editor.agent import history_store
            if self._session is None:
                from editor.core.env_store import read_ai_settings
                s = read_ai_settings()
                self._session = history_store.new_session(
                    provider=s.get("provider") or "", model=s.get("model") or "",
                    mod=self._mod_name or "", source="tui")
            self._session["history"] = list(self._engine.history)
            history_store.save_session(self._session)
        except Exception:
            pass

    def _load_history_session(self, session_id):
        """历史面板「继续会话」回调：载入历史并回显文稿（UI 线程）。"""
        from editor.agent import history_store
        if self._busy:
            self._append("\n⚠ 当前有请求进行中，待回复完成后再恢复会话。\n")
            return
        if self._engine is None:
            self._append("\n⚠ AI 未配置或未就绪，无法恢复会话。\n")
            return
        session = history_store.load_session(session_id)
        if not session:
            self._append("\n⚠ 会话不存在或已被删除。\n")
            return
        self._engine.history = history_store.to_openai_history(session.get("history") or [])
        session["history"] = self._engine.history
        self._session = session  # 续写同一会话文件
        lines = history_store.render_transcript(self._engine.history).splitlines()
        if len(lines) > 60:
            lines = ["（较早 %d 行已省略）" % (len(lines) - 60)] + lines[-60:]
        self._append(f"\n── 已恢复会话 {session['id']} · {session.get('title') or '（无标题）'}，可继续对话 ──\n")
        if lines:
            self._append("\n".join(lines) + "\n")

    # ---- 流式回调（worker 线程只入队，UI 侧 set_interval 攒批刷出）----
    def _append(self, text):
        """UI 线程即时写入（本地回显）；流式 delta 不走这里。"""
        self._pending.put(text)
        self._flush_pending()

    def _flush_pending(self):
        """把缓冲的 delta 合并为一次增量插入。

        逐 delta 全量重建 TextArea（log.text = …）会导致整篇重折行、滚动条跳动、
        光标归零 —— 表现为流式输出时画面抽搐；攒批 + insert 只重排受影响行。
        """
        if self._pending.empty():
            return
        chunk = []
        try:
            while True:
                chunk.append(self._pending.get_nowait())
        except queue.Empty:
            pass
        text = "".join(chunk)
        self._transcript += text
        try:
            log = self.query_one("#agent-log", TextArea)
            log.insert(text, log.document.end)
            log.scroll_end(animate=False)
            log.history.clear()  # 只读日志无需 undo，防止编辑历史随流式无限增长
        except Exception:
            pass  # 面板已关闭：worker 尾声的刷新直接忽略

    def _on_text(self, delta):
        self._pending.put(delta)

    def _on_round_text(self, _text):
        self._pending.put("\n")

    def _on_tool_result(self, name, result):
        head = (result or "").strip().splitlines()
        head = head[0] if head else ""
        self._pending.put(f"⚙ {name} → {head[:160]}\n")

    def _on_retry(self, attempt, total, reason):
        # 断流前已输出的半截文本会随重连重新生成，提示行与正文分两行
        self._pending.put(f"\n⚠ 连接中断，正在自动重连 ({attempt}/{total})…\n")

    def _finish(self):
        def done():
            self._busy = False
            try:
                self.query_one("#agent-send", Button).disabled = False
                self.query_one("#agent-input", Input).focus()
            except Exception:
                pass
        self.app.call_from_thread(done)

    def _confirm_bridge(self, title, detail):
        """worker 线程审批：push ConfirmScreen + Event 等待用户选择。

        完全访问模式（permissionMode=full）直接放行，不弹确认框。"""
        if getattr(self, "_permission_mode", "confirm") == "full":
            return True
        import threading
        ev = threading.Event()
        box = {"ok": False}

        def ask():
            def _cb(ok):
                box["ok"] = bool(ok)
                ev.set()
            self.app.push_screen(ConfirmScreen(
                title, detail, ok_label="允许", ok_variant="warning"), _cb)

        self.app.call_from_thread(ask)
        ev.wait()
        return box["ok"]

    def _ask_bridge(self, question, options):
        """worker 线程提问桥：push AskScreen + Event 等待用户回答。

        与 _confirm_bridge 同一跨线程模式；区别是**不做**完全访问短路——
        ask_user 是 AI 主动向用户提问，任何权限模式都必须弹给用户。"""
        import threading
        ev = threading.Event()
        box = {"answer": "用户未回答"}

        def ask():
            def _cb(answer):
                text = answer.strip() if isinstance(answer, str) else ""
                box["answer"] = text or "用户未回答"
                ev.set()
            self.app.push_screen(AskScreen(question, options), _cb)

        self.app.call_from_thread(ask)
        ev.wait()
        return box["answer"]

    # ---- 发送 ----
    @on(Input.Submitted, "#agent-input")
    def input_submitted(self, _event):
        self._send()

    @on(Button.Pressed, "#agent-send")
    def send_pressed(self):
        self._send()

    def _send(self):
        if self._engine is None or self._busy:
            return
        inp = self.query_one("#agent-input", Input)
        text = inp.value.strip()
        if not text:
            return
        if text.lower() in ("exit", "quit"):
            self.action_close()
            return
        inp.value = ""
        self._busy = True
        self.query_one("#agent-send", Button).disabled = True
        self._append(f"\n你：{text}\n")

        engine, client = self._engine, self._client

        def job():
            try:
                engine.run(text, client)
                self._persist_session()
                self.app.call_from_thread(self._append, "\n")
            except Exception as e:
                self.app.call_from_thread(self._append, f"⚠ {e}\n")
            finally:
                self._finish()

        self.run_worker(job, thread=True, group="agent-chat", exclusive=True)

    def action_close(self):
        if self._client is not None:
            self._client.cancel()  # 关闭底层连接，令 worker 的阻塞读立即退出
        self.dismiss(None)


class UpdateCheckScreen(ModalScreen):
    """检查更新弹窗：打开即显示「检查中…」，worker 线程查询 GitHub 后就地刷新结果。"""

    BINDINGS = [Binding("escape", "close", "关闭", priority=True)]

    DEFAULT_CSS = """
    UpdateCheckScreen { align: center middle; }
    #upd-dialog { width: 76; height: auto; max-height: 88%; background: $surface; border: thick $primary; padding: 1 2; }
    #upd-title { text-style: bold; color: $primary; margin-bottom: 1; }
    #upd-body { height: auto; max-height: 24; margin-bottom: 1; }
    #upd-hint { color: $text-muted; }
    """

    def compose(self) -> ComposeResult:
        with Vertical(id="upd-dialog"):
            yield Static("🔄 检查更新", id="upd-title")
            with VerticalScroll(id="upd-body"):
                yield Static("正在检查 GitHub 最新发行版…", id="upd-text")
            yield Static("Esc 关闭", id="upd-hint")

    def on_mount(self):
        # 网络请求放 worker 线程跑（参考 agent-chat 的 thread worker 模式），UI 不阻塞
        self.run_worker(self._fetch, thread=True, group="update-check", exclusive=True)

    def _fetch(self):
        result = {}
        try:
            from editor.core.update_check import check_update
            result = check_update(timeout=6) or {}
        except BaseException as e:  # 任何异常都转成结果文本，不允许炸掉 UI
            result = {"ok": False, "error": f"{type(e).__name__}: {e}"}

        def done():
            try:
                self._show(result)
            except Exception:
                pass  # 弹窗已被用户关闭：worker 尾声的刷新直接忽略

        self.app.call_from_thread(done)

    def _show(self, result):
        """把查询结果渲染进弹窗（UI 线程）。用 rich.text.Text 承载内容，
        避免 notes 的 markdown/方括号被 Textual 当成标记语法解析。"""
        from rich.text import Text

        title = self.query_one("#upd-title", Static)
        body = self.query_one("#upd-text", Static)
        if not result.get("ok"):
            title.update(Text("❌ 检查更新失败"))
            body.update(Text(
                f"错误：{result.get('error') or '未知错误'}\n"
                f"当前版本：{result.get('current') or '-'}"))
            return
        current = str(result.get("current") or "-")
        latest = str(result.get("latest_tag") or "")
        update_available = bool(result.get("update_available"))
        lines = [f"当前版本：{current}"]
        if not latest:
            lines.append("最新版本：-（仓库尚无发行版）")
        else:
            latest_name = str(result.get("latest_name") or "")
            lines.append("最新版本：" + latest + (f"  {latest_name}" if latest_name else ""))
            lines.append("需要更新：" + ("是 — 发现新版本，建议更新" if update_available else "否 — 已是最新"))
            if result.get("prerelease"):
                lines.append("类型：预发行版 (prerelease)")
            if result.get("published_at"):
                lines.append(f"发布时间：{result['published_at']}")
            if result.get("html_url"):
                lines.append(f"发行页：{result['html_url']}")
            notes = str(result.get("notes") or "").strip()
            if notes:
                note_lines = notes.splitlines()
                lines.append("")
                lines.append("── 更新说明 ──")
                lines.extend(note_lines[:20])
                if len(note_lines) > 20:
                    lines.append("…（完整说明见发行页）")
            assets = result.get("assets") or []
            lines.append("")
            lines.append(f"── 附件：{len(assets)} 个 ──")
            if assets:
                first = assets[0] or {}
                size = first.get("size") or 0
                lines.append(f"{first.get('name') or '-'} ({size / (1024 * 1024):.1f} MB)")
                lines.append(str(first.get("url") or "-"))
        title.update(Text("✅ 已是最新" if not update_available else "🆕 发现新版本"))
        body.update(Text("\n".join(lines)))

    def action_close(self):
        self.dismiss(None)


class EditorTUI(App):

    TITLE = "学生时代 · 模组编辑器 — TUI"

    SUB_TITLE = "终端版 · 直接读写 Cfgs 文件"



    CSS = """

    Screen { layout: vertical; background: $background; }



    Header {

        dock: top; height: 3;

        background: $primary; color: $text;

    }

    Header.-tall { height: 3; }

    Footer { dock: bottom; background: $panel; }



    #body { height: 1fr; layout: horizontal; }



    /* ── 面板通用 ── */

    .panel {

        background: $surface;

        border: solid $primary 30%;

        margin: 0;

        padding: 0;

    }

    .panel:focus-within { border: solid $primary; }



    #left   { width: 36; min-width: 28; background: #252526; }

    #middle { width: 1fr; min-width: 32; background: #1e1e1e; }

    #right  { width: 52; min-width: 36; background: #1f1f1f; }



    .panel-title {

        height: 1; padding: 0 1;

        background: #007acc;

        color: white; text-style: bold;

        dock: top;

    }

    .panel-hint {

        height: 1; padding: 0 1;

        background: $boost;

        color: $text-muted;

        dock: bottom;

    }



    /* ── 左栏 Tree ── */

    #mod-tree { height: 1fr; padding: 0 1; }

    Tree > .tree--guides { color: $primary 50%; }

    Tree > .tree--cursor { background: $primary 20%; }



    /* ── 中栏 ── */

    #filter-bar { height: 3; padding: 0 1; display: none; background: $boost; }

    #filter-bar.visible { display: block; }

    #record-table { height: 1fr; }

    DataTable > .datatable--header { background: $primary 85%; color: $text; text-style: bold; }

    DataTable > .datatable--cursor { background: $primary 22%; }

    DataTable > .datatable--hover { background: $primary 10%; }



    /* ── 右栏 ── */

    #detail-area {

        height: 1fr;

        border: solid $primary 18%;

        background: #1f1f1f;

        color: #d4d4d4;

    }

    #detail-area:focus { border: solid $primary 70%; }

    TextArea > .text-area--gutter {

        background: #1f1f1f;

        color: #858585;

    }

    TextArea > .text-area--cursor-line {

        background: #2a2d2e;

    }

    TextArea > .text-area--cursor {

        background: #aeafad;

        color: #1f1f1f;

    }

    TextArea > .text-area--selection {

        background: #264f78;

    }

    #right-actions {

        height: 3;

        padding: 0 1;

        align: center middle;

        background: #252526;

        border-top: solid $primary 20%;

    }

    #right-actions Button {

        margin-right: 1;

        min-width: 11;

        text-style: bold;

    }

    #right-actions #btn-save { background: #0e639c; color: white; }

    #right-actions #btn-save:hover { background: #1177bb; }

    #right-actions #btn-validate, #right-actions #btn-format, #right-actions #btn-dup, #right-actions #btn-external {

        background: #3c3c3c; color: #cccccc;

    }

    #right-actions #btn-validate:hover, #right-actions #btn-format:hover, #right-actions #btn-dup:hover, #right-actions #btn-external:hover {

        background: #4a4a4a; color: white;

    }

    #right-title {

        height: 1;

        padding: 0 1;

        background: #007acc 16%;

        color: #cccccc;

        text-style: bold;

    }

    #right-title.dirty { color: #f48771; background: #5a1d1d 30%; }

    #right-title.-synced { color: #89d185; }



    /* ── 状态栏 ── */

    #status {

        height: 3; padding: 0 1;

        background: #007acc;

        border-top: solid white 10%;

        color: #ffffff;

        text-style: bold;

    }

    #status.-success { background: #16825d; color: white; }

    #status.-warning { background: #a66a00; color: white; }

    #status.-error   { background: #be1100; color: white; }



    /* -- Form view GUI-like -- */

    #form-view { height: 1fr; background: #1e1e23; padding: 0 1; overflow: auto; display: none; }

    #form-view.visible { display: block; }

    #form-view:focus-within { border: solid $primary 60%; }

    .form-section { background: #1e1e23; border: solid #2e2e35; padding: 1 1; margin: 1 0; }

    .form-section-title { color: #ff8c00; text-style: bold; background: #2a2418 40%; padding: 0 1; }

    .form-field { margin: 1 0; }

    .form-field-label { color: #d4d4d8; text-style: bold; }

    .form-field-key { color: #5e5e66; }

    .form-field-hint { color: #8b8b93; }

    #form-view Input { background: #2a2a2e; border: solid #3a3a42; color: #d4d4d8; }

    #form-view Input:focus { border: solid #6c5ce7; }

    #form-view TextArea { background: #2a2a2e; border: solid #3a3a42; }

    #form-view TextArea:focus { border: solid #6c5ce7; }

    #form-header { height: 3; background: #252526; border-bottom: solid #2a2a2e; padding: 0 1; }

    #form-header-id { color: #c97018; text-style: bold; }



    /* ── 搜索栏 ── */

    #search-bar { height: 3; padding: 0 1; background: $boost; display: none; }

    #search-bar.visible { display: block; }



    /* ── 空状态 ── */

    .empty { height: 1fr; align: center middle; color: $text-muted; text-align: center; }

    """



    BINDINGS = [

        Binding("q", "quit", "退出"),

        Binding("r", "refresh", "刷新"),

        Binding("n", "new_record", "新建"),

        Binding("N", "new_mod", "新建Mod"),

        Binding("y", "duplicate", "复制"),

        Binding("d", "delete_record", "删除"),

        Binding("e", "edit_record", "编辑"),

        Binding("f", "format", "格式化"),

        Binding("s", "save", "保存"),

        Binding("ctrl+s", "save", "保存", show=False),

        Binding("v", "validate", "校验"),

        Binding("/", "filter", "过滤"),

        Binding("ctrl+k", "global_search", "全局搜索", priority=True),

        Binding("c", "cloud", "云同步"),

        Binding("a", "agent_chat", "AI 助手"),

        Binding("t", "tts", "配音 TTS"),

        Binding("u", "check_update", "检查更新"),

        Binding("p", "plugins", "插件"),

        Binding("question_mark", "help", "帮助", key_display="?"),

        Binding("m", "toggle_form", "表单/JSON"),

        # priority=True：避免被 Screen 内建 tab 焦点导航 / Input 的 ctrl+k(删至行尾) 抢走，
        # 否则焦点落入任一输入框后 Tab 面板切换与全局搜索将永远失效。
        Binding("tab", "next_panel", "下一面板", show=False, priority=True),

        Binding("shift+tab", "prev_panel", "上一面板", show=False, priority=True),

    ]



    def __init__(self, workspace=None, initial_mod=None, force_oobe: bool = False, **kwargs):

        super().__init__(**kwargs)

        self.workspace = resolve_workspace(workspace) if workspace else resolve_workspace(None)

        self.initial_mod = initial_mod

        self.force_oobe = bool(force_oobe)

        self.current_mod_root: Path | None = None

        self.current_mod_name: str | None = None

        self.current_cfg: str | None = None

        self.current_records: dict = {}

        self.current_selected_id: str | None = None

        self._dirty = False

        self._form_mode = True  # GUI-like form default

        self._form_inputs: dict[str, object] = {}

        self._last_form_rid: str | None = None

        self._form_built_for = None

        self._last_form_cfg: str | None = None

        self._filter_kw: str = ""

        self._panel_order = ["mod-tree", "record-table", "detail-area"]

        self._panel_idx = 0
        self._tree_filter_timer = None



    # ── compose ──



    def compose(self) -> ComposeResult:

        yield Header(show_clock=False)

        with Horizontal(id="body"):

            # 左

            with Vertical(id="left", classes="panel"):

                yield Static("📦  Mods / Cfgs", id="left-title", classes="panel-title")

                yield Tree("Workspace", id="mod-tree")

                yield Input(placeholder="过滤 Mod/Cfg…", id="tree-filter", compact=True)

                yield Static("↑↓ 选择  Enter 打开  → 展开  N 新建Mod", id="left-hint", classes="panel-hint")

            # 中

            with Vertical(id="middle", classes="panel"):

                yield Static("📋  Records", id="middle-title", classes="panel-title")

                with Horizontal(id="filter-bar"):

                    yield Label("筛选: ")

                    yield Input(placeholder="输入 ID 或字段关键字实时过滤…  Esc 清空", id="filter-input")

                yield DataTable(id="record-table", cursor_type="row")

                yield Static("n 新建  y 复制  d 删除  / 过滤  Enter 预览", id="middle-hint", classes="panel-hint")

            # 右

            with Vertical(id="right", classes="panel"):

                yield Static("📝  Detail / JSON", id="right-title", classes="panel-title")

                with VerticalScroll(id="form-view"):

                    yield Static("表单加载中...", id="form-placeholder")

                yield TextArea(id="detail-area", language="json", theme="vscode_dark", show_line_numbers=True, soft_wrap=True, tab_behavior="indent")

                with Horizontal(id="right-actions"):

                    yield Button("保存 (s)", id="btn-save", variant="success")

                    yield Button("校验", id="btn-validate", variant="default")

                    yield Button("格式化", id="btn-format", variant="default")

                    yield Button("复制", id="btn-dup", variant="default")

                    yield Button("外部编辑", id="btn-external", variant="default")

                yield Static("", id="status")

        yield Footer()



    # ── lifecycle ──



    def on_mount(self):

        self._setup_table()

        self._register_custom_theme()

        self._load_workspace()

        self.query_one("#mod-tree", Tree).focus()

        self._update_status(f"Workspace: {self.workspace} · {len(list_mods(self.workspace))} mods · 按 ? 查看帮助", "info")

        # 初始化表单视图状态

        try:

            fv = self.query_one("#form-view", VerticalScroll)

            fv.remove_class("visible")

            self.query_one("#detail-area", TextArea).styles.display = "block"

        except:

            pass

        # 空状态占位：引导用户选择 Mod/Cfg

        try:

            area = self.query_one("#detail-area", TextArea)

            area.text = (

                "# 欢迎使用 学生时代 · TUI 编辑器\n"

                "#\n"

                "# ① 在左侧选择 Mod → 展开查看 Cfgs\n"

                "# ② 点击 Cfg 在中栏加载记录\n"

                "# ③ 中栏 ↑↓ 选择记录，右侧实时预览 JSON\n"

                "# ④ 按 e 聚焦编辑，f 格式化，s 保存，v 校验\n"

                "# ⑤ 按 / 过滤当前列表，Ctrl+K 全局搜索\n"

                "# ⑥ 按 ? 查看完整快捷键帮助\n"

                "#\n"

                f"# Workspace: {self.workspace}\n"

                f"# Mods: {len(list_mods(self.workspace))} 个\n"

                "# 按 r 刷新 · q 退出\n"

            )

            area.read_only = True

        except Exception:

            pass

        # OOBE：首次访问自动弹出，--oobe / EDITOR_OOBE=1 强制开启
        try:
            from editor.cli.oobe import should_run as _oobe_should, forced_by_env as _oobe_forced

            if _oobe_should(self.force_oobe or _oobe_forced()):

                self.push_screen(
                    OobeScreen(self.workspace,
                               forced=self.force_oobe or _oobe_forced()),
                    self._after_oobe)

        except Exception:

            pass


    def _after_oobe(self, completed) -> None:
        """OOBE 关闭后刷新工作区（完成/跳过都重载一次）。"""
        try:
            from editor.cli.utils import resolve_workspace as _rw
            self.workspace = _rw(None)
        except Exception:
            pass
        try:
            self._load_workspace()
            n = len(list_mods(self.workspace))
            self._update_status(f"Workspace: {self.workspace} · {n} mods · 按 ? 查看帮助", "info")
        except Exception:
            pass


    def _setup_table(self):

        t: DataTable = self.query_one("#record-table", DataTable)

        t.cursor_type = "row"

        t.zebra_stripes = True

        # 初始两列，后续 _load_cfg 会按 schema 动态重建

        try:

            t.add_columns("ID", "预览")

        except Exception:

            pass



    def _register_custom_theme(self):

        """\u6ce8\u518c\u9ad8\u5bf9\u6bd4\u5ea6\u81ea\u5b9a\u4e49\u4e3b\u9898"""

        try:

            from textual._text_area_theme import TextAreaTheme

            from textual.widgets import TextArea as _TA

            from rich.style import Style

            base = TextAreaTheme.get_builtin_theme("vscode_dark")

            if base is None:

                return

            custom = TextAreaTheme(

                name="readable_dark",

                base_style=base.base_style,

                gutter_style=Style(color="#b3b3b3", bgcolor="#1f1f1f"),

                cursor_style=Style(color="#1f1f1f", bgcolor="#aeafad"),

                cursor_line_style=Style(bgcolor="#2a2d2e"),

                cursor_line_gutter_style=Style(color="#ffffff", bgcolor="#2a2d2e", bold=True),

                bracket_matching_style=Style(bgcolor="#3a3d41", bold=True),

                selection_style=Style(bgcolor="#264f78", color="#ffffff"),

                syntax_styles={**base.syntax_styles, "json.label": Style(color="#569cd6", bold=True), "string": Style(color="#ce9178"), "number": Style(color="#b5cea8"), "boolean": Style(color="#569cd6", bold=True), "json.null": Style(color="#569cd6", italic=True)},

            )

            try:

                _TA.register_theme(custom)  # type: ignore

            except Exception:

                try:

                    self.query_one("#detail-area", _TA).register_theme(custom)  # type: ignore

                except Exception:

                    pass

            try:

                self.query_one("#detail-area", _TA).theme = "readable_dark"

            except Exception:

                pass

        except Exception:

            pass



    # ── Form helpers ──

    def _is_form_cfg(self, cfg: str | None) -> bool:

        return cfg is not None

    def _schedule_build_form(self):
        """延迟到下一帧再重建表单。

        _show_record 可能运行在 Input/DataTable 等消息处理的嵌套链中
        （如过滤输入的每次按键），若同步 remove_children + mount 整个表单，
        新控件的 layout/repaint 标记无法在当帧布局中完成，会导致 Screen
        陷入"等待空闲→重绘→再次 dirty"的死循环（TUI 假死）。
        这里统一调度并去重：一帧内多次调用只重建一次，且始终以最新选中记录为准。
        """
        self._form_build_requested = True
        if getattr(self, "_form_build_scheduled", False):
            return
        self._form_build_scheduled = True

        async def _do_build():
            self._form_build_scheduled = False
            if not getattr(self, "_form_build_requested", False):
                return
            self._form_build_requested = False
            try:
                if not (self._form_mode and self._is_form_cfg(self.current_cfg)):
                    return
                fv = self.query_one("#form-view", VerticalScroll)
                if not fv.has_class("visible"):
                    return
                await self._build_form()
            except Exception as e:
                try:
                    self._update_status(f"[red]表单构建失败: {e}[/]", "error")
                except Exception:
                    pass

        self.call_after_refresh(_do_build)



    def _form_field_keys(self, cfg: str, rec: dict) -> list:
        """计算 _build_form 会为该记录创建的字段顺序列表（与构建循环保持一致）"""
        schema = load_schema().get(cfg, {}) if cfg else {}
        if self._is_form_cfg(cfg) and cfg == "TalkCfg":
            keys = []
            for _, ks in TALK_SECTIONS:
                for k in ks:
                    if k in rec or k in schema:
                        keys.append(k)
            special = {k for _, ks2 in TALK_SECTIONS for k in ks2}
            keys.extend(sorted(k for k in rec.keys() if k not in special))
            return keys
        key_list = sorted(rec.keys())
        if "id" in key_list:
            key_list.remove("id")
            key_list = ["id"] + key_list
        return key_list

    def _build_suggest_pool(self, cfg: str, key: str) -> list:
        """收集某字段的自动补全候选 [(显示文本, 补全值), ...]。

        来源：
          1. 数据字典（角色/背景/地点/物品/属性 → 显示 "ID · 名称"，补全为 ID）
          2. 同 Cfg 其它记录中该字段的取值（数组字段取每个元素）
        """
        pool: list = []
        seen: set = set()

        def _push(label: str, val: str):
            val = str(val)
            if not val or val in seen:
                return
            seen.add(val)
            pool.append((label, val))

        # 1) 数据字典候选
        try:
            from editor.core import data_dicts as _dd
            dmap = None
            if key in ("roleIds", "npcId", "npc", "role"):
                dmap = _dd.ROLE_DICT
            elif key in ("bg", "bgm", "audio"):
                dmap = _dd.BG_DICT
            elif key in ("map", "mapId"):
                dmap = _dd.MAP_DICT
            elif key in ("item", "itemId"):
                dmap = _dd.ITEM_DICT
            elif key == "attr":
                dmap = _dd.ATTR_DICT
            elif cfg == "TalkCfg" and key == "screenEffect":
                # 指南第六节：常用屏幕效果模板（label=描述，value=去括号+示例值的 code 文本）
                for item in getattr(_dd, "SCREEN_EFFECT_DB", ()):
                    _push(item.get("desc", ""), _code_sample(item.get("code", "")))
            elif cfg == "TalkCfg" and key == "roles":
                # 指南第五节：常用人物动作指令模板（2D 数组按行补全）
                for item in getattr(_dd, "ACTION_CMD_DB", ()):
                    _push(item.get("desc", ""), _code_sample(item.get("code", "")))
            if dmap:
                try:
                    keys = sorted(dmap.keys(), key=lambda x: (len(str(x)), str(x)))
                except Exception:
                    keys = list(dmap.keys())
                for k in keys:
                    v = str(k)
                    name = str(dmap.get(k, "")).strip()
                    _push(f"{v} · {name}" if name else v, v)
        except Exception:
            pass

        # 2) 同 Cfg 其它记录取值
        try:
            for rec2 in self.current_records.values():
                if not isinstance(rec2, dict):
                    continue
                v = rec2.get(key)
                if v is None:
                    continue
                if isinstance(v, list):
                    stack = list(v)
                    leaves = []
                    while stack:
                        it = stack.pop(0)
                        if isinstance(it, list):
                            stack = list(it) + stack
                        else:
                            leaves.append(it)
                else:
                    leaves = [v]
                for it in leaves:
                    if it is None or isinstance(it, dict):
                        continue
                    s = str(it)
                    _push(s, s)
        except Exception:
            pass

        if len(pool) > 400:
            pool = pool[:400]
        return pool

    async def _build_form(self):

        # Early return: if same record already built, just update values

        if getattr(self, "_last_form_rid", None) == self.current_selected_id and getattr(self, "_last_form_cfg", None) == self.current_cfg and getattr(self, "_form_inputs", None):

            try:

                rec = self.current_records.get(self.current_selected_id, {})

                cfg = self.current_cfg or ""

                schema = load_schema().get(cfg, {}) if cfg else {}

                for key, w in list(self._form_inputs.items()):

                    if key not in rec:

                        continue

                    ftype = schema.get(key, "String")

                    if key not in schema:

                        cur = rec.get(key)

                        if isinstance(cur, list):

                            ftype = "2D Array" if cur and isinstance(cur[0], list) else "1D Array"

                        elif isinstance(cur, (int, float)):

                            ftype = "Number"

                    enc = _encode(rec.get(key), ftype)

                    try:

                        from textual.widgets import Input, TextArea

                        if isinstance(w, Input):

                            if w.value != enc:

                                w.value = enc

                        elif isinstance(w, TextArea):

                            if w.text != enc:

                                w.text = enc

                    except:

                        pass

                return

            except:

                pass

        try:

            from textual.widgets import Input, Static, TextArea

        except Exception:

            return

        try:

            form = self.query_one("#form-view", VerticalScroll)

        except Exception:

            return

        # ── 原地刷新路径：cfg 未变且控件结构与新记录字段一致时，
        # 直接复用现有输入框仅同步值，避免 remove_children + mount 全量重建。
        # （嵌套消息处理中的全量重建会让新控件永远无法完成布局合成，
        #  触发 Screen 无限重绘循环 / TUI 假死）

        if getattr(self, "_form_inputs", None) and getattr(self, "_last_form_cfg", None) == self.current_cfg and self.current_selected_id:

            try:

                rec_now = self.current_records.get(self.current_selected_id)

                if isinstance(rec_now, dict):

                    cfg_now = self.current_cfg or ""

                    needed = self._form_field_keys(cfg_now, rec_now)

                    have = list(self._form_inputs.keys())

                    if needed == have and all(w.is_attached for w in self._form_inputs.values()):

                        schema_now = load_schema().get(cfg_now, {}) if cfg_now else {}

                        for key, w in self._form_inputs.items():

                            ftype = schema_now.get(key, "String")

                            cur2 = rec_now.get(key)

                            if key not in schema_now:

                                if isinstance(cur2, list):

                                    ftype = "2D Array" if cur2 and isinstance(cur2[0], list) else "1D Array"

                                elif isinstance(cur2, (int, float)):

                                    ftype = "Number"

                            enc2 = _encode(cur2, ftype)

                            from textual.widgets import Input as _I, TextArea as _TA2

                            if isinstance(w, _I):

                                if w.value != enc2:

                                    w.value = enc2

                            elif isinstance(w, _TA2):

                                if w.text != enc2:

                                    w.text = enc2

                        opt_len2 = len(v) if isinstance((v := rec_now.get("option")), list) else 0

                        try:

                            self.query_one("#form-header", Static).update(f"对白节点  ID: {self.current_selected_id}    对白: {opt_len2} 选项")

                        except Exception:

                            pass

                        try:

                            from editor.core.data_dicts import ROLE_DICT as _RD

                            ids2 = rec_now.get("roleIds") if isinstance(rec_now.get("roleIds"), list) else []

                            if not ids2:

                                preview2 = "旁白"

                            else:

                                names2 = []

                                for _id2 in ids2:

                                    n2 = _RD.get(str(_id2), "")

                                    names2.append(f"{_id2}({n2})" if n2 else str(_id2))

                                preview2 = "，".join(names2) if names2 else "旁白"

                            self.query_one("#roleids-preview", Static).update(preview2)

                        except Exception:

                            pass

                        self._last_form_rid = self.current_selected_id

                        self._form_built_for = (self.current_cfg, self.current_selected_id)

                        return

            except Exception:

                pass

        # 关键：remove_children() 返回 AwaitRemove，实际移除是异步的。
        # 若不 await 就立即 mount()，旧控件（fld_* / form-header 等相同 ID）
        # 仍在父节点的 _nodes_by_id 中，批量 mount 会抛 DuplicateIds，
        # 导致表单残缺/空白 + 脱离 DOM 的控件触发无限重绘（TUI 假死）。
        try:

            await form.remove_children()

        except Exception:

            pass

        if not self.current_selected_id or not self.current_records:

            try:

                await form.mount(Static("请选择记录", classes="empty"))

            except: pass

            return

        rec = self.current_records.get(self.current_selected_id)

        if not isinstance(rec, dict):

            try:

                await form.mount(Static("记录不是对象", classes="empty"))

            except: pass

            return

        cfg = self.current_cfg or ""

        schema = load_schema().get(cfg, {}) if cfg else {}

        self._form_inputs.clear()

        widgets = []

        # Header

        try:

            opt_len = 0

            v = rec.get("option")

            if isinstance(v, list):

                opt_len = len(v)

            widgets.append(Static(f"对白节点  ID: {self.current_selected_id}    对白: {opt_len} 选项", id="form-header"))

        except: pass



        def _add_field(key: str, container: list):

            ftype = schema.get(key, "String")

            val = rec.get(key, "" if ftype=="String" else 0 if ftype=="Number" else [])

            if key not in schema and key in rec:

                cur = rec[key]

                if isinstance(cur, list):

                    ftype = "2D Array" if cur and isinstance(cur[0], list) else "1D Array"

                elif isinstance(cur, (int, float)):

                    ftype = "Number"

            label = _field_label(key, cfg)

            hint = _field_hint(key)

            container.append(Static(f"{label}  {key}", classes="form-field-label"))

            if hint:

                container.append(Static(hint, classes="form-field-hint"))

            enc = _encode(val, ftype)

            if key == "content":

                ta = TextArea(text=enc, language=None, theme="vscode_dark", soft_wrap=True, id=f"fld_{key}")

                ta.styles.height = "6"

                ta.styles.min_height = 6

                container.append(ta)

                self._form_inputs[key] = ta

            else:

                inp = FldInput(pool=self._build_suggest_pool(cfg, key), value=enc, placeholder=hint or ftype, id=f"fld_{key}")

                dd = SuggestDropdown(owner=inp)

                inp.dropdown = dd

                container.append(inp)

                container.append(dd)

                self._form_inputs[key] = inp

            if key == "roleIds":

                try:

                    from editor.core.data_dicts import ROLE_DICT

                    ids = val if isinstance(val, list) else []

                    if not ids:

                        preview = "旁白"

                    else:

                        names = []

                        for _id in ids:

                            n = ROLE_DICT.get(str(_id), "")

                            names.append(f"{_id}({n})" if n else str(_id))

                        preview = "，".join(names) if names else "旁白"

                    container.append(Static(preview, classes="form-field-hint", id="roleids-preview"))

                except Exception:

                    pass



        if self._is_form_cfg(cfg) and cfg == "TalkCfg":

            for sec_title, keys in TALK_SECTIONS:

                widgets.append(Static(sec_title, classes="form-section-title"))

                # section container as list, we will flatten

                for key in keys:

                    if key not in rec and key not in schema:

                        continue

                    _add_field(key, widgets)

            special = {k for _, ks in TALK_SECTIONS for k in ks}

            remaining = [k for k in rec.keys() if k not in special]

            if remaining:

                widgets.append(Static(f"高级属性 {len(remaining)} 项", classes="form-section-title"))

                for key in sorted(remaining):

                    _add_field(key, widgets)

        else:

            # 只显示记录中已存在的字段，避免为大量空字段创建输入框

            keys = sorted(rec.keys())

            if "id" in keys:

                keys.remove("id")

                keys = ["id"] + keys

            for key in keys:

                _add_field(key, widgets)

        try:

            await form.mount(*widgets)

        except Exception as e:

            # mount 失败说明状态异常（如 ID 冲突），不再逐个重试掩盖问题，
            # 保持 _form_inputs 为空以避免旧控件值污染记录。
            self._form_inputs.clear()

            self._update_status(f"[red]表单挂载失败: {e}[/]", "error")

            return

        self._last_form_rid = self.current_selected_id

        self._last_form_cfg = self.current_cfg

        self._form_built_for = (self.current_cfg, self.current_selected_id)

        try:

            form.scroll_home(animate=False)

        except: pass



    def _cancel_pending_form(self):
        """取消延迟中的表单重建请求（不执行构建）。"""
        self._form_build_requested = False
        self._form_build_scheduled = False

    def _sync_form_to_record(self) -> bool:

        # 取消未执行的重建请求；若表单结构与当前记录不一致（如刚切换 cfg/记录、
        # 延迟构建尚未运行），控件里还是上一条记录的值，此时同步会把旧值写入新记录，
        # 必须跳过，等调度中的重建完成后再保存。
        self._cancel_pending_form()

        if getattr(self, "_form_built_for", None) != (self.current_cfg, self.current_selected_id):

            return False

        if not self.current_selected_id or not self.current_records:

            return False

        rec = self.current_records.get(self.current_selected_id)

        if not isinstance(rec, dict):

            return False

        cfg = self.current_cfg or ""

        schema = load_schema().get(cfg, {}) if cfg else {}

        changed = False

        for key, w in list(self._form_inputs.items()):

            try:

                from textual.widgets import Input, TextArea

                if isinstance(w, Input):

                    txt = w.value

                elif isinstance(w, TextArea):

                    txt = w.text

                else:

                    continue

                ftype = schema.get(key, "String")

                if key not in schema:

                    # infer

                    cur = rec.get(key)

                    if isinstance(cur, list):

                        ftype = "2D Array" if cur and isinstance(cur[0], list) else "1D Array"

                    elif isinstance(cur, (int, float)):

                        ftype = "Number"

                decoded = _decode(txt, ftype)

                if rec.get(key) != decoded:

                    rec[key] = decoded

                    changed = True

            except Exception:

                continue

        if changed:

            self._dirty = True

            try:

                self._set_detail_title(self.current_selected_id)

            except:

                pass

        return changed



    def action_toggle_form(self):

        self._form_mode = not self._form_mode

        form = self.query_one("#form-view", VerticalScroll)

        area = self.query_one("#detail-area", TextArea)

        if self._form_mode and self._is_form_cfg(self.current_cfg):

            form.add_class("visible")

            area.styles.display = "none"

            self.query_one("#right-title", Static).update(f"📝  {self.current_cfg}[{self.current_selected_id}]  表单" if self.current_selected_id else "📝  Detail / 表单")

            self._schedule_build_form()

            self.notify("已切换到表单视图 (m 切换 JSON)", timeout=2)

        else:

            form.remove_class("visible")

            area.styles.display = "block"

            self.query_one("#right-title", Static).update(f"📝  {self.current_cfg}[{self.current_selected_id}]" if self.current_cfg and self.current_selected_id else "📝  Detail / JSON")

            # refresh JSON preview

            if self.current_selected_id:

                self._show_record(self.current_selected_id)

            self.notify("已切换到 JSON 视图 (m 切换表单)", timeout=2)



    # ── workspace / tree ──





    def _load_workspace(self):

        tree: Tree = self.query_one("#mod-tree", Tree)

        tree.clear()

        mods = list_mods(self.workspace)

        root = tree.root

        root.label = f"📁 Workspace ({len(mods)})"

        root.expand()

        tree.show_root = True

        tree.guide_depth = 2



        # tree-filter 若有内容则过滤

        try:

            tree_kw = self.query_one("#tree-filter", Input).value.strip().lower()

        except Exception:

            tree_kw = ""



        for m in mods:

            cfg_count = len(m["cfg_files"])

            # 标题

            title = m["manifest_title"] or ""

            if title and title != m["name"]:

                if len(title) > 16:

                    title = title[:15] + "…"

                label = f"📦 {m['name']}  [dim]{title}[/] [cyan]({cfg_count})[/]"

            else:

                label = f"📦 {m['name']} [cyan]({cfg_count})[/]" if cfg_count else f"📦 {m['name']} [dim](空)[/]"

            # 树过滤

            if tree_kw and tree_kw not in m["name"].lower() and tree_kw not in title.lower():

                # 仍展示但若无匹配 cfg 则跳过；此处简单跳过 mod

                # 检查 cfg 是否匹配

                matched_cfgs = [c for c in m["cfg_files"] if tree_kw in c.lower()]

                if not matched_cfgs:

                    continue

                # 仅展示匹配的 cfgs

                cfg_list = matched_cfgs

            else:

                cfg_list = m["cfg_files"]

                if tree_kw:

                    cfg_list = [c for c in cfg_list if tree_kw in c.lower()]



            mod_node = root.add(label, data={"kind": "mod", "info": m}, allow_expand=bool(cfg_list))

            for cfg in cfg_list:

                # 统计记录数（轻量：若文件大则不统计）

                rec_cnt = ""

                try:

                    p = cfg_path(Path(m["root"]), cfg)

                    if p.is_file() and p.stat().st_size < 2_000_000:

                        txt = p.read_text(encoding="utf-8-sig")

                        d = json.loads(txt) if txt.strip() else {}

                        if isinstance(d, dict):

                            rec_cnt = f" [dim]{len(d)}[/]"

                except Exception:

                    rec_cnt = ""

                mod_node.add(f"📄 [cyan]{cfg}[/]{rec_cnt}", data={"kind": "cfg", "mod": m, "cfg": cfg}, allow_expand=False)

            # 自动展开当前 mod

            if self.current_mod_name and m["name"] == self.current_mod_name and cfg_list:

                mod_node.expand()



        root.expand()

        # hint

        total = len(mods)

        self.query_one("#left-hint", Static).update(f"[dim]{total} mods · ↑↓ 选择  Enter 打开  → 展开  r 刷新  N 新建Mod[/]")

        if not mods:

            self._update_status("未发现任何 Mod · 请检查 workspace 路径，或按 N 新建 Mod", "warning")

        # auto-select initial mod

        if self.initial_mod:
            info = find_mod(self.initial_mod, self.workspace)
            if info:
                self._select_mod(info)
                try:
                    for child in tree.root.children:
                        data = child.data
                        if data and data.get("kind") == "mod" and data.get("info", {}).get("name") == info["name"]:
                            child.expand()
                            break
                except Exception:
                    pass
                self.initial_mod = None



    def _select_mod(self, info: dict):

        self.current_mod_root = Path(info["root"])

        self.current_mod_name = info["name"]

        self.sub_title = f"{info['name']} @ {info['root']}"

        self._update_status(f"已选择 Mod: [b]{info['name']}[/]  @ {info['root']}", "info")

        self.query_one("#left-title", Static).update(f"📦  {info['name']}")

        # 若当前在 tree，自动聚焦到记录表需手动



    # ── cfg / table ──



    def _choose_columns(self, cfg_name: str, sample_records: dict):

        """根据 schema 与样例自动选择展示列：ID + 最多 3 个关键字段"""

        schema = load_schema().get(cfg_name, {})

        # 优先字段

        preferred = ["title", "name", "desc", "label", "type", "group", "cost", "effect", "cond"]

        cols = ["ID"]

        # 收集候选

        candidates: list[str] = []

        if schema:

            for p in preferred:

                if p in schema and p not in candidates:

                    candidates.append(p)

            for k in schema.keys():

                if k not in candidates and k != "id":

                    candidates.append(k)

                if len(candidates) >= 6:

                    break

        else:

            # 无 schema 时从样例推断

            sample = next(iter(sample_records.values()), {}) if sample_records else {}

            if isinstance(sample, dict):

                for k in list(sample.keys())[:5]:

                    if k != "id":

                        candidates.append(k)

        # 取前 3 个，且在样例中出现的

        chosen = []

        for c in candidates:

            # 检查至少一条记录有该字段

            if any(isinstance(r, dict) and c in r for r in sample_records.values()):

                chosen.append(c)

            if len(chosen) >= 3:

                break

        # 若仍不足，用预览列

        cols.extend(chosen)

        # 若无可选列或几乎无数据，回退到 Preview

        if not chosen:

            cols.append("预览")

        elif len(cols) < 4:

            # 补充预览列便于定位

            if "预览" not in cols:

                cols.append("预览")

        return cols



    def _preview_for(self, rec, chosen_cols: list[str]) -> list[str]:

        """根据 chosen_cols 生成行数据（不含 ID）"""

        if not isinstance(rec, dict):

            s = str(rec)[:80]

            # 填满列数

            return [s] + [""] * (len(chosen_cols) - 2)

        cells: list[str] = []

        for col in chosen_cols[1:]:

            if col == "预览":

                # 拼接前 3 个字段

                items = list(rec.items())[:3]
                preview = ", ".join(f"{k}={str(v)[:20]}" for k, v in items)
                preview = preview.replace("[", "\\[").replace("]", "\\]")
                cells.append(preview[:64])

            else:

                v = rec.get(col, "")

                if isinstance(v, (list, dict)):
                    s = json.dumps(v, ensure_ascii=False)
                    s = s.replace("[", "\\[").replace("]", "\\]")
                    if len(s) > 28:

                        s = s[:27] + "…"

                else:

                    s = str(v)

                    if len(s) > 28:

                        s = s[:27] + "…"

                    # 转义 markup

                    s = s.replace("[", "\\[").replace("]", "\\]")

                cells.append(s)

        return cells



    def _load_cfg(self, cfg_name: str):

        if not self.current_mod_root:

            self._update_status("请先选择一个 Mod", "warning")

            return

        cfg_name = cfg_name_normalize(cfg_name)

        self.current_cfg = cfg_name

        self._filter_kw = ""

        try:

            self.query_one("#filter-input", Input).value = ""

            self.query_one("#filter-bar", Horizontal).remove_class("visible")

        except Exception:

            pass



        try:

            data, path, exists = load_cfg(self.current_mod_root, cfg_name)

        except CfgParseError as e:

            self.current_records = {}

            self.current_selected_id = None

            t: DataTable = self.query_one("#record-table", DataTable)

            t.clear()

            self.query_one("#middle-title", Static).update(f"📋  {cfg_name}  [red]JSON 解析失败[/]")

            area: TextArea = self.query_one("#detail-area", TextArea)

            area.text = str(e) + f"\n\n# 提示：可按 [外部编辑] 用编辑器修复，或手动修正 JSON\n# 文件: {cfg_path(self.current_mod_root, cfg_name)}"

            area.read_only = True

            self._update_status(f"[red]JSON 解析失败: {e}[/]", "error")

            return

        except Exception as e:

            self._update_status(f"[red]加载失败: {e}[/]", "error")

            return



        if data is None:

            data = {}

        self.current_records = data if isinstance(data, dict) else {}

        # 重建表头（避免重复 clear(columns=True) 导致 pilot 挂起）

        t: DataTable = self.query_one("#record-table", DataTable)

        cols = self._choose_columns(cfg_name, self.current_records)

        self._current_cols = cols

        try:

            # 尝试轻量 clear，若列数/列名一致则仅清行

            need_rebuild = False

            try:

                cur_labels = []

                # t.columns is OrderedDict of ColumnKey->Column

                for col in getattr(t, "columns", {}).values():

                    # col.label may be Text or str

                    try:

                        cur_labels.append(col.label.plain if hasattr(col.label, "plain") else str(col.label))

                    except:

                        cur_labels.append(str(col.label))

            except:

                cur_labels = []

            if len(cur_labels) != len(cols) or cur_labels != cols:

                need_rebuild = True

            if need_rebuild:

                t.clear(columns=True)

                for c in cols:

                    if c == "ID":

                        t.add_column(c, width=12)

                    elif c == "预览":

                        t.add_column(c, width=None)

                    else:

                        t.add_column(c, width=18)

            else:

                t.clear()

        except Exception as e:

            # fallback: 强制重建

            try:

                t.clear(columns=True)

                for c in cols:

                    if c == "ID":

                        t.add_column(c, width=12)

                    elif c == "预览":

                        t.add_column(c, width=None)

                    else:

                        t.add_column(c, width=18)

            except Exception:

                pass

        self.query_one("#middle-title", Static).update(f"📋  {cfg_name}  [dim]{len(self.current_records)} 条 · {path.name}[/]")



        # 排序

        def sort_key(k):

            try:

                return (0, int(k))

            except Exception:

                return (1, str(k))



        # 性能：若超过 1500 条，提示并分页显示（先显示前 800，过滤可查全量）

        all_keys = sorted(self.current_records.keys(), key=sort_key)

        display_keys = all_keys

        truncated = False

        if len(all_keys) > 1500:

            display_keys = all_keys[:800]

            truncated = True



        for rid in display_keys:

            rec = self.current_records[rid]

            cells = self._preview_for(rec, cols)

            # add_row 需要与列数匹配：ID + cells

            row = [str(rid)] + cells

            # 补齐/截断

            if len(row) < len(cols):

                row += [""] * (len(cols) - len(row))

            row = row[: len(cols)]

            try:

                t.add_row(*row, key=str(rid))

            except Exception:

                # 兼容部分版本 add_row 签名

                t.add_row(*row)



        if truncated:

            self._update_status(f"{cfg_name}: 共 {len(all_keys)} 条，当前仅显示前 800 条 · 输入 / 过滤可查找全量", "warning")

        elif not self.current_records:

            area = self.query_one("#detail-area", TextArea)

            area.text = (

                f"# {cfg_name} 当前为空表\n"

                "#\n"

                "# 按 n 新建记录（会根据 schema 自动填充默认值）\n"

                "# 按 r 刷新\n"

                "#\n"

                f"# 目标文件: {path}\n"

            )

            area.read_only = True

            self._update_status(f"{cfg_name}: 空表 · 按 n 新建记录", "info")

        else:

            self._update_status(f"{cfg_name}: 已加载 {len(self.current_records)} 条记录 · ↑↓ 选择 · Enter/e 编辑", "info")



        # 自动选中第一条

        if self.current_records and display_keys:

            try:

                t.move_cursor(row=0)

            except Exception:

                pass

            first_id = str(display_keys[0])

            self._show_record(first_id)

        else:

            # 空表保留占位提示，不覆盖为空

            if not self.current_records:

                # placeholder 已在前面设置，这里只更新标题

                self._set_detail_title(None)

            else:

                self.query_one("#detail-area", TextArea).clear()

                self._set_detail_title(None)



        self.query_one("#middle-hint", Static).update("[dim]n 新建  y 复制  d 删除  f 格式化  / 过滤  v 校验[/]")

        # 刷新 preview 过滤缓存

        self._all_sorted_keys = all_keys



    def _apply_filter(self, kw: str):

        """对中栏 DataTable 进行实时过滤（不改底层数据）"""

        self._filter_kw = kw.strip().lower()

        if not self.current_cfg or not self.current_records:

            return

        t: DataTable = self.query_one("#record-table", DataTable)

        cols = getattr(self, "_current_cols", ["ID", "预览"])

        all_keys = getattr(self, "_all_sorted_keys", sorted(self.current_records.keys(), key=lambda k: (0, int(k)) if str(k).isdigit() else (1, str(k))))

        t.clear(columns=False)

        if not self._filter_kw:

            # 恢复显示（考虑截断）

            display = all_keys[:800] if len(all_keys) > 1500 else all_keys

            for rid in display:

                rec = self.current_records[rid]

                cells = self._preview_for(rec, cols)

                row = [str(rid)] + cells

                if len(row) < len(cols):

                    row += [""] * (len(cols) - len(row))

                row = row[: len(cols)]

                try:

                    t.add_row(*row, key=str(rid))

                except Exception:

                    t.add_row(*row)

            self.query_one("#middle-title", Static).update(

                f"📋  {self.current_cfg}  [dim]{len(self.current_records)} 条[/]"

            )

            return

        # 过滤

        matched = []

        for rid in all_keys:

            rec = self.current_records[rid]

            # 匹配 ID 或 JSON 文本

            blob = json.dumps(rec, ensure_ascii=False).lower() if isinstance(rec, dict) else str(rec).lower()

            if self._filter_kw in str(rid).lower() or self._filter_kw in blob:

                matched.append(rid)

        for rid in matched[:500]:

            rec = self.current_records[rid]

            cells = self._preview_for(rec, cols)

            row = [str(rid)] + cells

            if len(row) < len(cols):

                row += [""] * (len(cols) - len(row))

            row = row[: len(cols)]

            try:

                t.add_row(*row, key=str(rid))

            except Exception:

                t.add_row(*row)

        self.query_one("#middle-title", Static).update(

            f"📋  {self.current_cfg}  [dim]{len(matched)}/{len(self.current_records)} 匹配[/]  [yellow]过滤: {kw!r}[/]"

        )

        if matched:

            try:

                t.move_cursor(row=0)

                self._show_record(str(matched[0]))

            except Exception:

                pass

        else:

            self.query_one("#detail-area", TextArea).clear()

            self._set_detail_title(None)



    # ── detail ──



    def _set_detail_title(self, rid: str | None):

        title_w = self.query_one("#right-title", Static)

        if rid and self.current_cfg:

            dirty_mark = " [yellow]● 未保存[/]" if self._dirty else " [dim]● 已同步[/]"

            title_w.update(f"📝  {self.current_cfg}[{rid}]{dirty_mark}")

            if self._dirty:

                title_w.add_class("dirty")

            else:

                title_w.remove_class("dirty")

        elif self.current_cfg:

            title_w.update(f"📝  {self.current_cfg}  [dim]未选中记录[/]")

            title_w.remove_class("dirty")

        else:

            title_w.update("📝  Detail / JSON")

            title_w.remove_class("dirty")



    def _show_record(self, rid: str):

        self.current_selected_id = rid

        rec = self.current_records.get(rid)

        area: TextArea = self.query_one("#detail-area", TextArea)

        self._set_detail_title(rid)

        if rec is None:

            area.clear()

            area.read_only = True

            try:

                fv = self.query_one("#form-view", VerticalScroll)

                fv.remove_children()

                fv.mount(Static("无记录", classes="empty"))

            except:

                pass

            return

        pretty = json.dumps(rec, ensure_ascii=False, indent=2)

        area.text = pretty

        area.read_only = False

        # GUI-like form handling

        if self._form_mode and self._is_form_cfg(self.current_cfg):

            try:

                fv = self.query_one("#form-view", VerticalScroll)

                fv.add_class("visible")

                area.styles.display = "none"

                self.query_one("#right-title", Static).update(f"📝  {self.current_cfg}[{rid}]  表单")

                self._schedule_build_form()

            except Exception:

                pass

        else:

            try:

                fv = self.query_one("#form-view", VerticalScroll)

                fv.remove_class("visible")

                area.styles.display = "block"

                self.query_one("#right-title", Static).update(f"📝  {self.current_cfg}[{rid}]" if self.current_cfg else "📝  Detail / JSON")

            except:

                pass

        if self._dirty:

            self._update_status(f"已切换到 {self.current_cfg}[{rid}] · [yellow]有未保存改动[/] · s 保存 · Esc 丢弃需重载", "warning")



    def _stage_current_edit(self) -> bool:

        """将当前编辑区 JSON 暂存到 current_records，返回是否成功"""

        if not self.current_mod_root or not self.current_cfg or not self.current_selected_id:

            self._update_status("无选中记录", "warning")

            return False

        area: TextArea = self.query_one("#detail-area", TextArea)

        raw = area.text.strip()

        if not raw:

            self._update_status("内容为空，无法保存", "error")

            return False

        try:

            parsed = json.loads(raw)

        except Exception as e:

            # 尝试给出更友好的行号提示

            msg = str(e)

            # 提取行列 if available

            self._update_status(f"[red]JSON 解析失败: {msg}[/] · 请检查逗号/引号/括号", "error")

            self.notify(f"JSON 解析失败: {msg}", severity="error", timeout=4)

            return False

        if not isinstance(parsed, dict):

            self._update_status("记录必须是 JSON 对象（{{ ... }}）", "error")

            return False

        rid = self.current_selected_id

        self.current_records[rid] = parsed

        self._dirty = True

        self._set_detail_title(rid)

        # 刷新表格预览

        try:

            t: DataTable = self.query_one("#record-table", DataTable)

            # 找到行并更新单元格：用 remove + add 简易

            # textual DataTable 不支持直接 update cell 简易，改为重绘过滤后重载？仅更新标题提示

            pass

        except Exception:

            pass

        self._update_status(f"已暂存 {self.current_cfg}[{rid}] · [yellow]● 未保存[/] · s 落盘  v 校验", "warning")

        return True



    def _commit_to_disk(self):

        if not self.current_mod_root or not self.current_cfg:

            self._update_status("未打开任何 cfg", "warning")

            return

        # 若编辑区有焦点且 dirty，尝试暂存

        area: TextArea = self.query_one("#detail-area", TextArea)

        if self.current_selected_id and not area.read_only:

            # 若文本与 current_records 不一致，尝试暂存

            try:

                parsed = json.loads(area.text)

                if isinstance(parsed, dict) and parsed != self.current_records.get(self.current_selected_id):

                    self.current_records[self.current_selected_id] = parsed

                    self._dirty = True

            except Exception as e:

                self._update_status(f"[red]当前编辑区 JSON 有误，无法保存: {e}[/]", "error")

                return

        if not self._dirty:

            self._update_status("无待保存改动", "info")

            return

        # 校验

        issues = validate_cfg(self.current_cfg, self.current_records)

        # 追加跨表引用校验（指南语义层：Evt/Talk/Option 之间的 ID 引用）

        try:

            from editor.core.guide_rules import validate_cross as _validate_cross

            _tables = {}

            for _cn in ("EvtCfg", "TalkCfg", "OptionCfg"):

                if _cn == self.current_cfg:

                    # 当前表用内存中的最新数据（保存前暂存已同步）

                    _tables[_cn] = self.current_records

                    continue

                try:

                    _d, _p, _ok = load_cfg(self.current_mod_root, _cn)

                except Exception:

                    continue  # 缺表/解析失败时跳过

                if _ok and isinstance(_d, dict):

                    _tables[_cn] = _d

            if _tables:

                issues = issues + list(_validate_cross(_tables))

        except Exception:

            pass  # 跨表校验失败不影响保存流程

        has_err = any(lv == "error" for lv, _ in issues)

        if has_err:

            err_cnt = sum(1 for lv, _ in issues if lv == "error")

            self._update_status(f"[red]校验失败：{err_cnt} 个 error，保存已阻断[/] · v 查看详情 · --force 可强制（CLI）", "error")

            self.push_screen(ValidationScreen(self.current_cfg, issues, len(self.current_records)))

            return

        # 有 warn 也提示但允许保存（仅 toast）

        if issues:

            warns = len(issues)

            self.notify(f"校验有 {warns} 条警告，已保存（可按 v 查看详情）", severity="warning", timeout=3.5)

        # 原子写入

        try:

            out = save_cfg(self.current_mod_root, self.current_cfg, self.current_records)

        except Exception as e:

            self._update_status(f"[red]写入失败: {e}[/]", "error")

            return

        self._dirty = False

        if self.current_selected_id:

            self._set_detail_title(self.current_selected_id)

        self._update_status(f"[green]✓ 已保存 {self.current_cfg} ({len(self.current_records)} 条) → {out}[/]", "success")

        self.notify(f"已保存 {self.current_cfg} ({len(self.current_records)} 条)", severity="information", timeout=2.2)

        # 保存后重算过滤缓存的 keys

        def sort_key(k):

            try: return (0, int(k))

            except: return (1, str(k))

        self._all_sorted_keys = sorted(self.current_records.keys(), key=sort_key)

        # 若有过滤，刷新

        try:
            self._apply_filter(self._filter_kw)
        except Exception:
            pass



    def _format_current(self):

        if not self.current_selected_id:

            self._update_status("请先选择一条记录", "warning")

            return

        area: TextArea = self.query_one("#detail-area", TextArea)

        if area.read_only:

            return

        try:

            parsed = json.loads(area.text)

            area.text = json.dumps(parsed, ensure_ascii=False, indent=2)

            self._update_status("已格式化 · 记得 s 保存", "info")

            self.notify("已格式化", timeout=1.5)

        except Exception as e:

            self._update_status(f"[red]格式化失败: {e}[/]", "error")



    # ── helpers ──



    def _update_status(self, msg: str, level: str = "info"):

        w = self.query_one("#status", Static)

        # markup 支持

        w.update(msg)

        # 背景色按 level

        w.remove_class("-success", "-warning", "-error")

        if level == "success":

            w.add_class("-success")

        elif level == "warning":

            w.add_class("-warning")

        elif level == "error":

            w.add_class("-error")



    def _set_status(self, msg: str, style=""):

        # 兼容旧调用

        lvl = "info"

        if "red" in style or "error" in msg.lower() or "失败" in msg:

            lvl = "error"

        elif "yellow" in style or "warn" in msg.lower():

            lvl = "warning"

        elif "green" in style:

            lvl = "success"

        self._update_status(msg, lvl)



    # ── actions ──



    def action_refresh(self):

        self._load_workspace()

        if self.current_cfg:

            # 保存当前选中 id

            keep = self.current_selected_id

            self._load_cfg(self.current_cfg)

            if keep and keep in self.current_records:

                try:

                    t: DataTable = self.query_one("#record-table", DataTable)

                    # 尝试定位

                    idx = list(self._all_sorted_keys).index(keep) if keep in self._all_sorted_keys else -1

                    if idx >= 0 and idx < t.row_count:

                        t.move_cursor(row=min(idx, t.row_count - 1))

                except Exception:

                    pass

                self._show_record(keep)

        self.notify("已刷新", timeout=1.5)



    def action_new_mod(self):
        """在 workspace 下新建 Mod（manifest.json + Cfgs/zh-cn 空骨架），与 OOBE/CLI 行为一致。"""

        def _after_desc(title: str, desc: str | None):
            if desc is None:
                desc = ""
            try:
                from editor.cli.oobe import create_mod

                create_mod(title, self.workspace, desc.strip())
            except ValueError as e:
                self.notify(str(e), severity="error", timeout=4)
                return
            except Exception as e:
                self.notify(f"创建失败: {e}", severity="error", timeout=4)
                return
            # 复用 _load_workspace 的自动选中/展开逻辑定位到新 Mod
            self.initial_mod = title
            self._load_workspace()
            self._update_status(f"[green]已创建 Mod: {title}[/] · 左栏 Enter 展开后选 cfg，n 新建记录", "success")
            self.notify(f"已创建 Mod: {title}", timeout=3)

        def _after_title(result: str | None):
            if result is None:
                return
            title = result.strip()
            if not title:
                self.notify("Mod 名不能为空", severity="error")
                return

            def _cb(desc: str | None):
                _after_desc(title, desc)

            self.push_screen(
                PromptScreen("Mod 描述", f"为 {title} 添加描述（可直接回车跳过）", placeholder="例如：我的第一个剧情 Mod"),
                _cb,
            )

        self.push_screen(
            PromptScreen("新建 Mod", f"输入 Mod 名称（即 workspace 下的目录名）\n[dim]{self.workspace}[/]",
                         placeholder="例如：MyFirstMod"),
            _after_title,
        )

    def action_new_record(self):

        if not self.current_mod_root or not self.current_cfg:

            self._update_status("请先在左栏选择一个 cfg · 或按 N 新建 Mod", "warning")

            self.notify("请先选择一个 cfg", severity="warning", timeout=3)

            # 未选中 cfg 时「新建」退化为新建 Mod，避免无入口死路

            self.action_new_mod()

            return

        # 生成默认 ID（优先用官方指南语义建议：Evt 随机 1XXXXXX / Talk 10位 / Option 9位）

        new_id = None

        try:

            _s = suggest_next_id(self.current_cfg, self.current_records)

            if _s is not None:

                new_id = str(_s)

        except Exception:

            new_id = None

        if new_id is None:

            # 回退：max+1

            try:

                ints = [int(k) for k in self.current_records.keys() if str(k).isdigit()]

                new_id = str(max(ints) + 1) if ints else "1001"

            except Exception:

                new_id = "1001"

            while new_id in self.current_records:

                try:

                    new_id = str(int(new_id) + 1)

                except Exception:

                    new_id += "_1"



        def _after_input(result: str | None):

            if result is None:

                return

            nid = result.strip()

            if not nid:

                self.notify("ID 不能为空", severity="error")

                return

            if nid in self.current_records:

                self.notify(f"ID 已存在: {nid}", severity="error")

                return

            # 构造模板

            schema = load_schema().get(self.current_cfg, {})

            template: dict = {}

            for field, typ in schema.items():

                if typ == "String":

                    template[field] = ""

                elif typ == "Number":

                    template[field] = 0

                elif typ == "1D Array":

                    template[field] = []

                elif typ == "2D Array":

                    template[field] = []

                else:

                    template[field] = None

                if field == "id":

                    try:

                        template[field] = int(nid)

                    except Exception:

                        template[field] = nid

            # 若 schema 无 id，仍保证 id 字段

            if "id" not in template:

                try:

                    template["id"] = int(nid)

                except Exception:

                    template["id"] = nid

            self.current_records[nid] = template

            self._dirty = True

            # 重建 keys

            def sort_key(k):

                try: return (0, int(k))

                except: return (1, str(k))

            self._all_sorted_keys = sorted(self.current_records.keys(), key=sort_key)

            # 若有过滤，清空过滤以显示新记录

            if self._filter_kw:

                self.query_one("#filter-input", Input).value = ""

                self._filter_kw = ""

                self.query_one("#filter-bar", Horizontal).remove_class("visible")

            # 重载表格（保留过滤逻辑：直接重载 cfg 但保留内存数据）

            # 为避免丢失 dirty，直接增量插入表

            t: DataTable = self.query_one("#record-table", DataTable)

            cols = getattr(self, "_current_cols", ["ID", "预览"])

            cells = self._preview_for(template, cols)

            row = [str(nid)] + cells

            if len(row) < len(cols):

                row += [""] * (len(cols) - len(row))

            row = row[: len(cols)]

            try:

                t.add_row(*row, key=str(nid))

            except Exception:

                t.add_row(*row)

            # 更新标题计数

            self.query_one("#middle-title", Static).update(f"📋  {self.current_cfg}  [dim]{len(self.current_records)} 条[/]")

            # 定位

            try:

                t.move_cursor(row=t.row_count - 1)

            except Exception:

                pass

            self._show_record(nid)

            self.query_one("#detail-area", TextArea).focus()

            self._update_status(f"[green]已创建 {self.current_cfg}[{nid}] · 编辑后按 s 保存[/]", "success")

            self.notify(f"已创建 {nid}，编辑后保存", timeout=2.5)



        self.push_screen(

            PromptScreen("新建记录", f"为 {self.current_cfg} 输入新 ID（当前共 {len(self.current_records)} 条）", default=new_id, placeholder="例如：320102"),

            _after_input,

        )



    def action_duplicate(self):

        if not self.current_selected_id or not self.current_cfg:

            self._update_status("请先选择一条记录", "warning")

            return

        src_id = self.current_selected_id

        rec = self.current_records.get(src_id)

        if rec is None:

            return

        # 生成新 ID

        try:

            ints = [int(k) for k in self.current_records.keys() if str(k).isdigit()]

            new_id = str(max(ints) + 1) if ints else "1001"

        except Exception:

            new_id = src_id + "_copy"

        while new_id in self.current_records:

            try:

                new_id = str(int(new_id) + 1)

            except Exception:

                new_id += "_1"



        def _after(result: str | None):

            if result is None:

                return

            nid = result.strip()

            if not nid:

                self.notify("ID 不能为空", severity="error")

                return

            if nid in self.current_records:

                self.notify(f"ID 已存在: {nid}", severity="error")

                return

            import copy as _copy

            new_rec = _copy.deepcopy(rec)

            # 更新 id 字段若存在

            if isinstance(new_rec, dict) and "id" in new_rec:

                try:

                    new_rec["id"] = int(nid)

                except Exception:

                    new_rec["id"] = nid

            self.current_records[nid] = new_rec

            self._dirty = True

            def sort_key(k):

                try: return (0, int(k))

                except: return (1, str(k))

            self._all_sorted_keys = sorted(self.current_records.keys(), key=sort_key)

            if self._filter_kw:

                self.query_one("#filter-input", Input).value = ""

                self._filter_kw = ""

                self.query_one("#filter-bar", Horizontal).remove_class("visible")

            t: DataTable = self.query_one("#record-table", DataTable)

            cols = getattr(self, "_current_cols", ["ID", "预览"])

            cells = self._preview_for(new_rec, cols)

            row = [str(nid)] + cells

            if len(row) < len(cols):

                row += [""] * (len(cols) - len(row))

            row = row[: len(cols)]

            try:

                t.add_row(*row, key=str(nid))

            except Exception:

                t.add_row(*row)

            self.query_one("#middle-title", Static).update(f"📋  {self.current_cfg}  [dim]{len(self.current_records)} 条[/]")

            try:

                t.move_cursor(row=t.row_count - 1)

            except Exception:

                pass

            self._show_record(nid)

            self._update_status(f"[green]已复制 {src_id} → {nid} · s 保存[/]", "success")



        self.push_screen(PromptScreen("复制记录", f"复制 {self.current_cfg}[{src_id}] 为新 ID", default=new_id), _after)



    def action_delete_record(self):

        if not self.current_selected_id or not self.current_cfg:

            self.notify("未选中记录", severity="warning")

            return

        rid = self.current_selected_id

        cfg = self.current_cfg



        def _after(ok: bool):

            if not ok:

                self.notify("已取消删除", timeout=1.4)

                return

            if rid not in self.current_records:

                return

            del self.current_records[rid]

            t: DataTable = self.query_one("#record-table", DataTable)

            try:

                t.remove_row(rid)

            except Exception:

                # 兼容：key 可能为 RowKey 对象

                try:

                    t.remove_row(str(rid))

                except Exception:

                    # 重载

                    self._load_cfg(cfg)

                    self._dirty = True

                    self._update_status(f"[yellow]已删除 {cfg}[{rid}] · s 落盘生效[/]", "warning")

                    return

            self.query_one("#detail-area", TextArea).clear()

            self.query_one("#detail-area", TextArea).read_only = True

            self.current_selected_id = None

            self._dirty = True

            self._set_detail_title(None)

            # 更新标题

            self.query_one("#middle-title", Static).update(f"📋  {cfg}  [dim]{len(self.current_records)} 条[/]  [yellow]● 未保存[/]")

            # 重算 keys

            def sort_key(k):

                try: return (0, int(k))

                except: return (1, str(k))

            self._all_sorted_keys = sorted(self.current_records.keys(), key=sort_key)

            self._update_status(f"[yellow]已删除 {cfg}[{rid}] · s 保存后落盘[/]", "warning")

            self.notify(f"已删除 {rid}（未保存）", severity="warning", timeout=2.5)

            # 选中下一条

            if t.row_count > 0:

                try:

                    t.move_cursor(row=0)

                    # 获取当前行 key

                    # RowHighlighted 会触发 _show_record

                except Exception:

                    pass



        self.push_screen(ConfirmScreen("确认删除", f"确定删除 {cfg}[{rid}] 吗？\n删除后需按 s 保存才会写入文件。", ok_label="删除", ok_variant="error"), _after)



    def action_edit_record(self):

        if self._form_mode and self._is_form_cfg(self.current_cfg):

            try:

                fv = self.query_one("#form-view", VerticalScroll)

                if fv.has_class("visible"):

                    # 聚焦首个输入框

                    first = fv.query("Input")

                    if first:

                        first[0].focus()

                        return

                    tfs = fv.query("TextArea")

                    if tfs:

                        tfs[0].focus()

                        return

            except:

                pass

        area = self.query_one("#detail-area", TextArea)

        if area.read_only:

            self.notify("当前记录不可编辑（未选中或 JSON 解析失败）", severity="warning")

            return

        area.focus()



    def action_format(self):

        self._format_current()



    def action_save(self):

        # 表单模式先同步

        if self._form_mode and self._is_form_cfg(self.current_cfg):

            self._sync_form_to_record()

        # 若焦点在编辑区，先暂存当前

        area: TextArea = self.query_one("#detail-area", TextArea)

        if area.has_focus and self.current_selected_id and not area.read_only:

            ok = self._stage_current_edit()

            if not ok:

                return

        self._commit_to_disk()



    def action_validate(self):

        if not self.current_cfg:

            self.notify("未打开 cfg", severity="warning")

            return

        # 暂存当前编辑

        if self.current_selected_id:

            try:

                area = self.query_one("#detail-area", TextArea)

                if not area.read_only:

                    parsed = json.loads(area.text)

                    if isinstance(parsed, dict):

                        self.current_records[self.current_selected_id] = parsed

            except Exception as e:

                self._update_status(f"[red]JSON 解析失败: {e}[/]", "error")

                return

        issues = validate_cfg(self.current_cfg, self.current_records)

        self.push_screen(ValidationScreen(self.current_cfg, issues, len(self.current_records)))

        if not issues:

            self._update_status(f"[green]✓ {self.current_cfg} 校验通过 ({len(self.current_records)} 条)[/]", "success")

        else:

            warns = sum(1 for lv, _ in issues if lv == "warn")

            errs = len(issues) - warns

            self._update_status(f"[yellow]校验完成：{errs} error / {warns} warn[/] · 弹窗查看详情", "warning")



    def action_filter(self):

        # 若中栏无 cfg，进入全局搜索

        if not self.current_cfg:

            self.action_global_search()

            return

        bar = self.query_one("#filter-bar", Horizontal)

        bar.add_class("visible")

        inp = self.query_one("#filter-input", Input)

        inp.focus()

        inp.action_select_all()



    def action_global_search(self):

        def _after(result):

            if not result:

                self.query_one("#mod-tree", Tree).focus()

                return

            cfg = result.get("cfg")

            rid = result.get("id")

            # 定位：先选中 mod（当前 mod），再加载 cfg，再选中记录

            if cfg:

                # 确保当前 mod 已选

                if self.current_mod_root:

                    self._load_cfg(cfg)

                    # 延迟选中记录（等待表加载）

                    def _select():

                        try:

                            t: DataTable = self.query_one("#record-table", DataTable)

                            # 查找行索引

                            # DataTable 没有直接 get_row_index 稳定 API，遍历

                            for idx, key in enumerate(getattr(self, "_all_sorted_keys", [])):

                                if str(key) == str(rid):

                                    try:

                                        t.move_cursor(row=idx if idx < t.row_count else 0)

                                    except Exception:

                                        pass

                                    break

                            self._show_record(str(rid))

                            self.query_one("#detail-area", TextArea).focus()

                        except Exception:

                            pass

                    self.set_timer(0.15, _select)



        self.push_screen(GlobalSearchScreen(self.workspace, self.current_mod_root), _after)



    def _modal_open(self) -> bool:
        # 面板已打开时忽略 c/a/t/u/p（避免叠加弹屏）
        return isinstance(self.screen, (CloudScreen, CloudProviderEditScreen,
                                        AgentChatScreen, AgentConfigScreen,
                                        TtsScreen, UpdateCheckScreen,
                                        PluginsScreen, PluginInfoScreen))

    def action_cloud(self):
        if self._modal_open():
            return
        self.push_screen(CloudScreen(mod_name=self.current_mod_name, workspace=self.workspace))

    def action_agent_chat(self):
        if self._modal_open():
            return
        self.push_screen(AgentChatScreen(
            mod_root=self.current_mod_root, mod_name=self.current_mod_name,
            workspace=self.workspace))

    def action_tts(self):
        if self._modal_open():
            return
        self.push_screen(TtsScreen(
            mod_root=self.current_mod_root, mod_name=self.current_mod_name,
            workspace=self.workspace))

    def action_plugins(self):
        if self._modal_open():
            return
        # 打开插件屏前确保 load_all() 已执行（离线模式，收集命令/工具/面板）
        try:
            from editor.core import plugin_system
            plugin_system.load_all(None)
        except Exception:
            pass
        self.push_screen(PluginsScreen())

    def action_check_update(self):
        """检查 GitHub 更新：立即弹窗显示「检查中…」，worker 返回后就地刷新结果。"""
        if self._modal_open():
            return
        self.push_screen(UpdateCheckScreen())

    def action_help(self):

        self.push_screen(HelpScreen())



    def _panel_focusable(self, w) -> bool:

        """判断面板当前是否可接收焦点（目标可聚焦，且自身及祖先均未被 display:none / visibility 隐藏）"""

        try:

            if not getattr(w, "can_focus", True):

                return False

        except Exception:

            return False

        node = w

        while node is not None:

            try:

                st = getattr(node, "styles", None)

                if st is not None:

                    if getattr(st, "display", "block") == "none":

                        return False

                    if getattr(st, "visibility", "visible") == "hidden":

                        return False

            except Exception:

                return False

            node = getattr(node, "_parent", None)

        return True



    def _focus_panel(self, direction: int):

        """按 direction(+1/-1) 在主面板间循环切换焦点。

        以当前实际焦点为准计算起点（避免 _panel_idx 与焦点状态脱节），
        跳过不可聚焦/隐藏的目标（如 form 模式下被隐藏的编辑区）。
        """

        order = self._panel_order

        if not order:

            return

        focused = self.focused

        base = self._panel_idx

        if focused is not None:

            try:

                base = order.index(focused.id)

            except (ValueError, AttributeError):

                pass

        for step in range(1, len(order) + 1):

            idx = (base + direction * step) % len(order)

            try:

                w = self.query_one(f"#{order[idx]}")

            except Exception:

                continue

            if not self._panel_focusable(w):

                continue

            w.focus()

            self._panel_idx = idx

            return

    def action_next_panel(self):

        # Tab 循环

        self._focus_panel(1)

    def action_prev_panel(self):

        self._focus_panel(-1)



    def action_quit(self):

        if self._dirty:

            def _after(ok: bool):

                if ok:

                    # 放弃保存直接退出

                    self.exit()

                else:

                    self.notify("已取消退出 · 请按 s 保存", timeout=2)

            self.push_screen(ConfirmScreen("未保存的改动", "有未保存的改动，直接退出将丢失修改。\n确定要退出吗？", ok_label="直接退出", ok_variant="warning", cancel_label="留在此处"), _after)

        else:

            self.exit()



    # ── events ──



    @on(Tree.NodeSelected, "#mod-tree")

    def on_tree_select(self, event: Tree.NodeSelected):

        data = event.node.data

        node = event.node

        if not data:

            if node.allow_expand:

                node.toggle()

            return

        if data.get("kind") == "mod":

            self._select_mod(data["info"])

            # 不自动 toggle，避免双重切换；箭头点击已处理

            # 但若用户按 Enter 期望展开，可在第二次 Enter 时手动

            # 这里仅选中，不切换

        elif data.get("kind") == "cfg":

            mod = data["mod"]

            self._select_mod(mod)

            self._load_cfg(data["cfg"])



    @on(DataTable.RowSelected, "#record-table")

    def on_row_selected(self, event: DataTable.RowSelected):

        try:

            rid = str(event.row_key.value) if event.row_key and event.row_key.value else str(event.row_key)

        except Exception:

            rid = str(getattr(event, "row_key", ""))

        # 过滤模式下 key 仍是 id

        rid = rid.split(":")[-1] if ":" in rid else rid

        if rid and rid in self.current_records:

            self._show_record(rid)

            # 同步焦点到编辑区便于直接 e 编辑？保持在表格

        # 允许 y/d 等操作



    @on(DataTable.RowHighlighted, "#record-table")
    def on_row_highlighted(self, event: DataTable.RowHighlighted):
        if event.row_key and event.row_key.value:
            rid = str(event.row_key.value)
            rid = rid.split(":")[-1] if ":" in rid else rid
            area = self.query_one("#detail-area", TextArea)
            has_form_focus = False
            try:
                form = self.query_one("#form-view", VerticalScroll)
                if form.has_class("visible"):
                    for w in getattr(self, "_form_inputs", {}).values():
                        try:
                            if w.has_focus:
                                has_form_focus = True
                                break
                        except Exception:
                            continue
                    if getattr(form, "has_focus_within", False):
                        has_form_focus = True
            except Exception:
                pass
            if not area.has_focus and not has_form_focus and rid in self.current_records:
                self._show_record(rid)



    @on(Button.Pressed, "#btn-save")

    def on_btn_save(self, _):

        self.action_save()



    @on(Button.Pressed, "#btn-validate")

    def on_btn_validate(self, _):

        self.action_validate()



    @on(Button.Pressed, "#btn-format")

    def on_btn_format(self, _):

        self.action_format()



    @on(Button.Pressed, "#btn-dup")

    def on_btn_dup(self, _):

        self.action_duplicate()



    @on(Button.Pressed, "#btn-external")

    def on_btn_external(self, _):

        if not self.current_mod_root or not self.current_cfg:

            return

        path = cfg_path(self.current_mod_root, self.current_cfg)

        if not path.exists():

            # 先落盘当前内存数据

            if self._dirty:

                self._commit_to_disk()

            else:

                save_cfg(self.current_mod_root, self.current_cfg, self.current_records)

        editor = os.environ.get("EDITOR") or ("notepad" if os.name == "nt" else "nano")

        self._update_status(f"正在启动 {editor} … 关闭编辑器后自动重载", "info")

        try:
            with self.suspend():
                import subprocess
                try:
                    subprocess.run([editor, str(path)])
                except Exception as e:
                    self._update_status(f"[red]外部编辑失败: {e}[/]", "error")
        except Exception as e:
            try:
                import subprocess
                subprocess.run([editor, str(path)])
            except Exception as e2:
                self._update_status(f"[red]外部编辑失败: {e2}[/]", "error")
                return
        self._load_cfg(self.current_cfg)



    @on(Input.Changed, "#filter-input")

    def on_filter_changed(self, event: Input.Changed):

        self._apply_filter(event.value)



    @on(Input.Submitted, "#filter-input")

    def on_filter_submitted(self, event: Input.Submitted):

        # 回车后聚焦表格

        self.query_one("#record-table", DataTable).focus()



    @on(Input.Changed, "#tree-filter")
    def on_tree_filter_changed(self, event: Input.Changed):
        try:
            if self._tree_filter_timer:
                self._tree_filter_timer.stop()
        except Exception:
            pass
        self._tree_filter_timer = self.set_timer(0.35, self._load_workspace)



    @on(TextArea.SelectionChanged, "#detail-area")

    def on_detail_cursor_moved(self, event: TextArea.SelectionChanged):

        """\u5149\u6807\u79fb\u52a8\u65f6\u9884\u89c8"""

        try:

            area = self.query_one("#detail-area", TextArea)

            if area.read_only or not self.current_selected_id:

                return

            row = area.cursor_location[0] if hasattr(area, "cursor_location") else 0

            try:

                lines = area.text.splitlines()

                line = lines[row] if 0 <= row < len(lines) else ""

            except Exception:

                line = ""

            import re as _re, json as _json

            # \u5339\u914d引号内字符串（含双反斜杠路径）

            m = _re.search(r"\"([^\"]*\\[^\"]*)\"", line)

            target = m.group(1) if m else ""

            if target:

                try:

                    decoded = _json.loads(f"\"{target}\"")

                except Exception:

                    decoded = target.replace("\\\\", "\\")

                if len(decoded) > 24 and any(x in decoded for x in ["/", ".png", ".jpg", "\\", "Textures", "Role"]):

                    short = decoded if len(decoded) < 88 else decoded[:85] + "\u2026"

                    self._update_status(f"\u21b3 {short}  \u00b7 \u884c {row+1} \u00b7 e \u7f16\u8f91 f \u683c\u5f0f\u5316", "info")

        except Exception:

            pass



    @on(Input.Changed, "#form-view Input")

    def on_form_input_changed(self, event: Input.Changed):

        # 表单输入实时同步到记录

        try:

            iid = event.input.id or ""

            if not iid.startswith("fld_"):

                return

            key = iid[4:]

            if not self.current_selected_id or key not in self.current_records.get(self.current_selected_id, {}):

                # 允许新增 key 也同步

                pass

            txt = event.value

            cfg = self.current_cfg or ""

            schema = load_schema().get(cfg, {}) if cfg else {}

            ftype = schema.get(key, "String")

            if key not in schema:

                cur = self.current_records.get(self.current_selected_id, {}).get(key)

                if isinstance(cur, list):

                    ftype = "2D Array" if cur and isinstance(cur[0], list) else "1D Array"

                elif isinstance(cur, (int, float)):

                    ftype = "Number"

            decoded = _decode(txt, ftype)

            if self.current_selected_id and self.current_selected_id in self.current_records:

                rec = self.current_records[self.current_selected_id]

                if isinstance(rec, dict) and rec.get(key) != decoded:

                    rec[key] = decoded

                    self._dirty = True

                    self._set_detail_title(self.current_selected_id)

                    # 同步 JSON 预览（若 JSON 视图隐藏也更新）

                    try:

                        area = self.query_one("#detail-area", TextArea)

                        area.text = json.dumps(rec, ensure_ascii=False, indent=2)

                    except:

                        pass

        except Exception:

            pass



    @on(Input.Changed, "#form-view Input")

    def on_form_input_suggest(self, event: Input.Changed):

        # 输入变化时刷新自动补全候选

        try:

            if isinstance(event.input, FldInput):

                event.input.refresh_suggestions()

        except Exception:

            pass



    @on(Input.Blurred, "#form-view Input")

    def on_form_input_blurred(self, event: Input.Blurred):

        # 焦点移出输入框（且未转向其候选列表）时收起下拉

        try:

            inp = event.input

            if isinstance(inp, FldInput) and inp.dropdown is not None:

                if self.focused is not inp.dropdown:

                    inp.dropdown.hide()

        except Exception:

            pass



    @on(OptionList.OptionSelected)

    def on_suggest_selected(self, event: OptionList.OptionSelected):

        # 点击候选项 → 补全

        try:

            dd = event.option_list

            if isinstance(dd, SuggestDropdown):

                event.stop()

                val = dd.current_value()

                if dd.owner is not None and val is not None:

                    dd.owner.apply_completion(val)

        except Exception:

            pass



    @on(TextArea.Changed, "#form-view TextArea")

    def on_form_textarea_changed(self, event: TextArea.Changed):

        try:

            ta = event.text_area

            iid = ta.id or ""

            if not iid.startswith("fld_"):

                return

            key = iid[4:]

            txt = ta.text

            cfg = self.current_cfg or ""

            schema = load_schema().get(cfg, {}) if cfg else {}

            ftype = schema.get(key, "String")

            decoded = _decode(txt, ftype)

            if self.current_selected_id and self.current_selected_id in self.current_records:

                rec = self.current_records[self.current_selected_id]

                if isinstance(rec, dict) and rec.get(key) != decoded:

                    rec[key] = decoded

                    self._dirty = True

                    self._set_detail_title(self.current_selected_id)

                    try:

                        area = self.query_one("#detail-area", TextArea)

                        area.text = json.dumps(rec, ensure_ascii=False, indent=2)

                    except:

                        pass

        except Exception:

            pass



    @on(TextArea.Changed, "#detail-area")

    def on_detail_changed(self, event: TextArea.Changed):

        # 输入时标记为“待暂存”，但不直接 dirty（需 s 暂存+落盘）

        # 为给用户即时反馈，若内容与内存不一致则显示 ● 待暂存

        if not self.current_selected_id:

            return

        area = self.query_one("#detail-area", TextArea)

        if area.read_only:

            return

        # 简单对比：若文本 json 解析后与内存不同则提示

        try:

            parsed = json.loads(area.text)

            cur = self.current_records.get(self.current_selected_id)

            if parsed != cur:

                self._dirty = True
                self.query_one("#right-title", Static).update(f"📝  {self.current_cfg}[{self.current_selected_id}] [yellow]● 待暂存(s)[/]")

                self.query_one("#right-title", Static).add_class("dirty")

        except Exception:

            # 解析失败也提示

            self._dirty = True
            self.query_one("#right-title", Static).update(f"📝  {self.current_cfg}[{self.current_selected_id}] [red]● JSON 有误[/]")

            self.query_one("#right-title", Static).add_class("dirty")



    def on_key(self, event):

        # Esc 处理：按优先级关闭过滤栏 / 搜索

        if event.key == "escape":

            # 若过滤栏可见，先关闭

            try:

                bar = self.query_one("#filter-bar", Horizontal)

                if bar.has_class("visible"):

                    bar.remove_class("visible")

                    self.query_one("#filter-input", Input).value = ""

                    self._apply_filter("")

                    self.query_one("#record-table", DataTable).focus()

                    event.stop()

                    return

            except Exception:

                pass

            # 若树过滤有内容，清空

            try:

                tf = self.query_one("#tree-filter", Input)

                if tf.has_focus and tf.value:

                    tf.value = ""

                    event.stop()

                    return

            except Exception:

                pass

        # j/k 在表格/树中上下移动（vim 风格）— 仅当不在输入框时

        if event.key in ("j", "k", "h", "l"):

            # 若焦点在 Input/TextArea，不处理

            focused = self.focused

            if isinstance(focused, (Input, TextArea)):

                return

            if event.key == "j":

                event.stop()

                self.action_cursor_down()

            elif event.key == "k":

                event.stop()

                self.action_cursor_up()

            elif event.key == "h":

                # 左：若在中/右则回到左

                event.stop()

                self.query_one("#mod-tree", Tree).focus()

            elif event.key == "l":

                event.stop()

                # 右：若在左则去中，若在中则去右

                if self.focused and self.focused.id == "mod-tree":

                    self.query_one("#record-table", DataTable).focus()

                elif self.focused and self.focused.id == "record-table":

                    self.query_one("#detail-area", TextArea).focus()



    # 简易光标移动代理

    def action_cursor_down(self):

        try:

            focused = self.focused

            if focused and hasattr(focused, "action_cursor_down"):

                focused.action_cursor_down()

        except Exception:

            pass



    def action_cursor_up(self):

        try:

            focused = self.focused

            if focused and hasattr(focused, "action_cursor_up"):

                focused.action_cursor_up()

        except Exception:

            pass





def run(workspace=None, initial_mod=None, force_oobe: bool = False):

    app = EditorTUI(workspace=workspace, initial_mod=initial_mod,

                    force_oobe=force_oobe)

    app.run()





if __name__ == "__main__":

    run()


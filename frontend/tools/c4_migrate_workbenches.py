#!/usr/bin/env python3
"""C4 迁移：把各工作台自带的 _loading/_error 早返回替换成 WorkbenchScaffold 的
status/error/onRetry 参数（骨架层统一渲染骨架屏与错误面板）。

匹配的形态（10 个工作台一致）：

    @override
    Widget build(BuildContext context) {
      if (_loading) {
        return Container(
          color: palette.bgDeep2,
          child: const Center(child: fluent.ProgressRing()),
        );
      }
      if (_error != null) {
        return Container(... _error ... fluent.Button(onPressed: _loadAll, ...));
      }

      return WorkbenchScaffold(
        ...
      );
    }

替换为：

    @override
    Widget build(BuildContext context) {
      return WorkbenchScaffold(
        status: _loading
            ? WorkbenchStatus.loading
            : (_error != null ? WorkbenchStatus.error : WorkbenchStatus.ready),
        error: _error,
        onRetry: _loadAll,
        errorTitle: '<原标题>',
        ...
      );
    }
"""
import re
import sys
from pathlib import Path

TARGETS = [
    ("lib/features/chats/idle_chat_workbench.dart", "闲聊数据加载失败"),
    ("lib/features/events/event_workbench.dart", "事件数据加载失败"),
    ("lib/features/external/external_dialogues_workbench.dart", "外部对话数据加载失败"),
    ("lib/features/goals/goals_workbench.dart", "目标数据加载失败"),
    ("lib/features/messages/messages_workbench.dart", "消息数据加载失败"),
    ("lib/features/minigames/minigames_workbench.dart", "小游戏数据加载失败"),
    ("lib/features/person/person_workbench.dart", "人物数据加载失败"),
    ("lib/features/social/social_workbench.dart", "社交数据加载失败"),
    ("lib/features/space/space_workbench.dart", "空间数据加载失败"),
    ("lib/features/warehouse/warehouse_workbench.dart", "仓库数据加载失败"),
]

# 匹配从 `if (_loading) {` 到 `return WorkbenchScaffold(` 之间的整段。
PAT = re.compile(
    r"(?P<indent>[ \t]*)if \(_loading\) \{.*?return WorkbenchScaffold\(\n",
    re.DOTALL,
)

STATUS_LINES = (
    "{indent}  status: _loading\n"
    "{indent}      ? WorkbenchStatus.loading\n"
    "{indent}      : _error != null\n"
    "{indent}          ? WorkbenchStatus.error\n"
    "{indent}          : WorkbenchStatus.ready,\n"
    "{indent}  error: _error,\n"
    "{indent}  onRetry: _loadAll,\n"
)


def migrate(path: Path, title: str) -> str:
    src = path.read_text(encoding="utf-8")
    m = PAT.search(src)
    if not m:
        return "NO_MATCH"
    indent = m.group("indent")
    repl = (
        "{indent}return WorkbenchScaffold(\n"
        "{indent}  errorTitle: '{title}',\n"
    ).format(indent=indent, title=title) + STATUS_LINES.format(indent=indent)
    out = src[: m.start()] + repl + src[m.end():]
    if out == src:
        return "UNCHANGED"
    path.write_text(out, encoding="utf-8")
    return "OK"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    for rel, title in TARGETS:
        p = root / rel
        if not p.exists():
            print(f"MISSING  {rel}")
            continue
        print(f"{migrate(p, title):9} {rel}")


if __name__ == "__main__":
    main()

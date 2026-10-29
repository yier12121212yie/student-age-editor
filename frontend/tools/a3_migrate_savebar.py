#!/usr/bin/env python3
"""把 10 个工作台的私有 `_saveBar()` 实现替换为公共 `SaveBar` 的薄包装。
保留 `_saveBar()` 方法名（调用点 `_saveBar(),` 不改），方法体改为 return SaveBar(...)。
"""
import re
from pathlib import Path

FILES = [
    'chats/idle_chat_workbench.dart',
    'events/event_workbench.dart',
    'external/external_dialogues_workbench.dart',
    'goals/goals_workbench.dart',
    'messages/messages_workbench.dart',
    'minigames/minigames_workbench.dart',
    'person/person_workbench.dart',
    'social/social_workbench.dart',
    'space/space_workbench.dart',
    'warehouse/warehouse_workbench.dart',
]

NEW_BODY = """Widget _saveBar() {
    return SaveBar(
      dirty: _dirty,
      saving: _saving,
      onSave: _saveAll,
      onDiscard: _discard,
      onOpenSearch: widget.onOpenSearch,
    );
  }"""


def replace_block(src: str) -> str:
    i = src.find('Widget _saveBar() {')
    if i < 0:
        return src
    # 从 i 起按花括号配平找方法结束
    depth = 0
    j = src.find('{', i)
    k = j
    while k < len(src):
        if src[k] == '{':
            depth += 1
        elif src[k] == '}':
            depth -= 1
            if depth == 0:
                k += 1
                break
        k += 1
    return src[:i] + NEW_BODY + src[k:]


def main():
    for rel in FILES:
        p = Path('lib/features') / rel
        s = p.read_text(encoding='utf-8')
        s2 = replace_block(s)
        print(f'  {"OK " if s2 != s else "---"} {p}')
        if s2 != s:
            p.write_text(s2, encoding='utf-8')


if __name__ == '__main__':
    main()

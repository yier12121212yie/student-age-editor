#!/usr/bin/env python3
"""删除各工作台残留的 `class _MiniBtnState extends State<_MiniBtn> { ... }` 块。
用花括号配平确定块尾（比正则可靠）。
"""
from pathlib import Path

FILES = [
    'chats/idle_chat_workbench.dart',
    'events/event_workbench.dart',
    'external/external_dialogues_workbench.dart',
    'messages/messages_workbench.dart',
    'minigames/minigames_workbench.dart',
    'social/social_workbench.dart',
    'space/space_workbench.dart',
    'warehouse/warehouse_workbench.dart',
]

HEADER = 'class _MiniBtnState extends State<_MiniBtn> {'


def strip_block(src: str, header: str) -> str:
    i = src.find(header)
    if i < 0:
        return src
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                j += 1
                break
        j += 1
    end = j
    # 吞掉块后的空行
    while end < len(src) and src[end] == '\n':
        end += 1
    # 吞掉块前的空行
    start = i
    while start > 0 and src[start - 1] == '\n' and (start < 2 or src[start - 2] == '\n'):
        start -= 1
    return src[:start] + src[end:]


def main():
    for rel in FILES:
        p = Path('lib/features') / rel
        s = p.read_text(encoding='utf-8')
        n = s.count(HEADER)
        if n == 0:
            print(f'  --- {p} (none)')
            continue
        s2 = strip_block(s, HEADER)
        p.write_text(s2, encoding='utf-8')
        print(f'  OK  {p} (removed {n})')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""A3 工作台控件层迁移：
1. 删除各工作台私有的 _SyncedText / _SyncedTextState / _NumBox / _NumBoxState /
   _MiniBtn / _MiniBtnState / _ListNumField / _ListNumFieldState 类定义；
2. 把调用点改名到公共组件（SyncedTextField / NumBox / WorkbenchMiniButton /
   ListNumField），并按各文件的原始行为补上构造参数（intOnly / format）；
3. 加 import。

不触碰 load/save/dirty（那是控制器迁移，分批做）。
"""
import re
import sys
from pathlib import Path

ROOT = Path('lib/features')

# 每个文件的 (路径, NumBox 是否为 intOnly, NumBox 是否 use _fmt(显示整数))
FILES = {
    'chats/idle_chat_workbench.dart': (False, False),
    'events/event_workbench.dart': (False, False),
    'external/external_dialogues_workbench.dart': (False, True),
    'goals/goals_workbench.dart': (True, False),
    'messages/messages_workbench.dart': (False, False),
    'minigames/minigames_workbench.dart': (False, True),
    'person/person_workbench.dart': (True, False),
    'social/social_workbench.dart': (True, False),
    'space/space_workbench.dart': (True, False),
    'warehouse/warehouse_workbench.dart': (False, True),
}

CLASS_BLOCKS = [
    'class _SyncedText extends StatefulWidget',
    'class _SyncedTextState extends State<_SyncedText>',
    'class _NumBox extends StatefulWidget',
    'class _NumBoxState extends State<_NumBox>',
    'class _MiniBtn extends StatefulWidget',
    'class _MiniBtnState extends State<_MiniBtn>',
    'class _ListNumField extends StatefulWidget',
    'class _ListNumFieldState extends State<_ListNumField>',
]


def drop_class(src: str, header: str) -> str:
    """删除以 header 开头、到下一个顶格 class/const/typedef/等宽注释 为止的整块。"""
    i = src.find(header)
    if i < 0:
        return src
    # 找块结束：下一个顶格（第 0 列）的 class / const / typedef / extension / /// 之前的孤立声明
    j = i + len(header)
    m = re.search(r'\n(?=(?:class |const |typedef |extension |abstract class ))', src[j:])
    if not m:
        return src
    end = j + m.start() + 1  # 保留下一个声明的换行
    # 连同前面的空行一起删
    start = i
    while start > 0 and src[start - 1] == '\n' and (start < 2 or src[start - 2] == '\n'):
        start -= 1
    return src[:start] + src[end:]


def migrate(path: Path, int_only: bool, use_fmt: bool) -> bool:
    src = path.read_text(encoding='utf-8')
    orig = src

    for h in CLASS_BLOCKS:
        src = drop_class(src, h)

    # 调用点改名
    src = re.sub(r'\b_SyncedText\(', 'SyncedTextField(', src)
    src = re.sub(r'\b_ListNumField\(', 'ListNumField(', src)
    src = re.sub(r'\b_MiniBtn\(', 'WorkbenchMiniButton(', src)

    # _NumBox( 调用点：需要补 intOnly / format
    extra = ''
    if int_only:
        extra += 'intOnly: true, '
    if use_fmt:
        extra += 'format: true, '
    if extra:
        # 只在「实参列表里没有 intOnly/format」时插入。匹配 _NumBox( + 可选换行缩进
        def repl(m):
            return 'NumBox(' + m.group(1) + extra
        src = re.sub(r'\b_NumBox\((\s*)', repl, src)
    else:
        src = re.sub(r'\b_NumBox\(', 'NumBox(', src)

    # 加 import（放在 workbench_scaffold import 之后；没有就放在 core/models 之后）
    if "features/editor/synced_fields.dart" not in src:
        anchor = "import '../../core/workbench_scaffold.dart';"
        if anchor in src:
            src = src.replace(
                anchor,
                anchor + "\nimport '../editor/synced_fields.dart';",
                1)
        else:
            anchor2 = "import '../../core/models.dart';"
            src = src.replace(
                anchor2,
                anchor2 + "\nimport '../editor/synced_fields.dart';",
                1)

    if "core/save_bar.dart" not in src:
        anchor = "import '../../core/workbench_scaffold.dart';"
        if anchor in src:
            src = src.replace(
                anchor,
                anchor + "\nimport '../../core/save_bar.dart';",
                1)

    if src != orig:
        path.write_text(src, encoding='utf-8')
        return True
    return False


def main():
    changed = []
    for rel, (io_, fmt) in FILES.items():
        p = ROOT / rel
        if not p.exists():
            print(f'  MISSING {p}')
            continue
        ok = migrate(p, io_, fmt)
        print(f'  {"OK " if ok else "---"} {p}')
        if ok:
            changed.append(rel)
    print(f'\nchanged {len(changed)} / {len(FILES)}')


if __name__ == '__main__':
    main()

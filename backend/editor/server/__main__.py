# -*- coding: utf-8 -*-
"""python -m editor.server 入口。"""
import sys

from editor.server import main

if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as e:
        print("错误：无法监听端口：%s" % e)
        print("若端口已被占用，请先关闭残留的后端进程（如任务管理器中的 python.exe）后重试。")
        sys.exit(1)

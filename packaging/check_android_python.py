import sys

sys.path.insert(0, "frontend/android/app/src/main/python")
import editor.server  # noqa: E402
import UnityPy  # noqa: E402
import texture2ddecoder  # noqa: E402,F401  占位模块
import fmod_toolkit  # noqa: E402,F401  占位模块

print("IMPORT_OK", UnityPy.__version__)
try:
    UnityPy.load  # noqa: B018
    print("UnityPy.load OK")
except Exception as e:
    print("FAIL", e)
try:
    texture2ddecoder.decode_bc7
except RuntimeError as e:
    print("STUB_RAISES_OK")

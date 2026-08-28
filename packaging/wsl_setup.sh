#!/usr/bin/env bash
# WSL Ubuntu 24.04 构建环境准备：Linux 桌面工具链 + Flutter SDK(linux) + Python 打包依赖。
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  build-essential curl ca-certificates unzip xz-utils git \
  python3.12 python3.12-venv python3-pip

# Flutter Linux SDK（与 Windows 侧同为 3.47.0 stable）
if [ ! -x /opt/flutter/bin/flutter ]; then
  curl -fL -o /tmp/flutter.tar.xz \
    https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.0-stable.tar.xz
  tar -xJf /tmp/flutter.tar.xz -C /opt
  rm /tmp/flutter.tar.xz
fi
export PATH="/opt/flutter/bin:$PATH"
git config --global --add safe.directory /opt/flutter
flutter config --no-analytics >/dev/null
flutter doctor -v || true

# Python 打包依赖（系统 pip 有 PEP668 限制，用 venv）
python3.12 -m venv /opt/pyvenv
/opt/pyvenv/bin/pip install --upgrade pip
/opt/pyvenv/bin/pip install pyinstaller unitypy

# appimagetool（AppImage 打包工具，与 CI 同款 continuous 版本）
if [ ! -f /opt/appimagetool-x86_64.AppImage ]; then
  curl -fL -o /opt/appimagetool-x86_64.AppImage \
    https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x /opt/appimagetool-x86_64.AppImage
fi

echo "=== WSL build env ready ==="

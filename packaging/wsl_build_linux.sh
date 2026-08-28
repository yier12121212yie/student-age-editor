#!/usr/bin/env bash
# 在 WSL 内构建 Linux 发行版（便携 zip + deb + AppImage 安装包）。
# 没有游戏资源缓存时安装包无法内嵌官方资源包，可 SKIP_INSTALLERS=1 跳过。
set -euxo pipefail
export PATH="/opt/flutter/bin:$PATH"
export APPIMAGETOOL=/opt/appimagetool-x86_64.AppImage
# WSL NAT 模式无法使用宿主机 127.0.0.1 代理，改用国内镜像
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
cd /root/editorbuild/editor
# 版本号取 frontend/pubspec.yaml 的 version: x.y.z+n
VER=$(grep -m1 '^version:' frontend/pubspec.yaml \
  | sed -E 's/^version:[[:space:]]*([0-9]+(\.[0-9]+){1,3})(\+[0-9]+)?[[:space:]]*$/\1/')
EXTRA_ARGS=""
if [ "${SKIP_INSTALLERS:-0}" = "1" ]; then
  EXTRA_ARGS="--no-installer"
fi
/opt/pyvenv/bin/python build_release.py --target linux --version "$VER" $EXTRA_ARGS

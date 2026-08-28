#!/usr/bin/env bash
set -euxo pipefail
# 清理被污染的 /usr/local 文件
cd /root/editorbuild/editor/frontend/build/linux/x64/release
if [ -f install_manifest.txt ]; then xargs rm -f < install_manifest.txt; fi
rm -rf /usr/local/data/flutter_assets
# 清掉残缺的构建缓存，全新配置
cd /root/editorbuild/editor/frontend
rm -rf build/linux
export PATH="/opt/flutter/bin:$PATH"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn
flutter build linux --release 2>&1 | tail -n 3
echo "=== bundle ==="
ls build/linux/x64/release/bundle/

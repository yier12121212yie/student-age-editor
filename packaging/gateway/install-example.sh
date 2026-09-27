#!/usr/bin/env bash
# 「学生时代模组编辑器」自托管网关 · 部署引导脚本（示例，按需修改）
#
# 干什么：建 editor 专用系统用户 → 创建三大目录（/opt/editor、/etc/editor、
# /srv/editor-data）并 chown + 设权限 → 放置 gateway.json 与 systemd 单元。
# 不干什么：不解压发行包、不启动服务、不装 Caddy、不开防火墙——
# 这些步骤见 README-部署.md（步骤 1、2、5、6）。
#
# 运行：bash install-example.sh
#       非 root 可运行：脚本内自动为特权命令加 sudo（需要 sudo 权限）。
#       全部路径可用环境变量覆盖：
#         EDITOR_USER=editor OPT_DIR=/opt/editor ETC_DIR=/etc/editor \
#         DATA_DIR=/srv/editor-data bash install-example.sh
set -u -o pipefail

# ------------------------------------------------------------- 可调参数 ----
EDITOR_USER="${EDITOR_USER:-editor}"      # 专用系统用户（组同名）
OPT_DIR="${OPT_DIR:-/opt/editor}"         # server-linux 包解压目录
ETC_DIR="${ETC_DIR:-/etc/editor}"         # gateway.json 所在目录
DATA_DIR="${DATA_DIR:-/srv/editor-data}"  # gateway.json 的 user_data_root
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # 本示例资产目录

if [[ $EUID -eq 0 ]]; then
  SUDO=""                                  # 已是 root，直接执行
else
  SUDO="sudo"                              # 非 root：特权命令走 sudo
fi

info() { echo "[gateway] $*"; }
die()  { echo "[gateway] 错误：$*" >&2; exit 1; }

# ------------------------------------------- 1) 专用系统用户（WEB_GUIDE §2.3 步骤3）----
if getent passwd "$EDITOR_USER" >/dev/null 2>&1; then
  info "用户 $EDITOR_USER 已存在，跳过创建"
else
  # -r 系统账户（无密码登录）；-m 建家目录。组与用户同名（useradd 默认）。
  $SUDO useradd -r -m "$EDITOR_USER" || die "创建用户 $EDITOR_USER 失败"
  info "已创建系统用户 $EDITOR_USER"
fi

# ------------------------------- 2) 三大目录 + 属主/权限（含密钥的目录一律 700）----
$SUDO mkdir -p "$OPT_DIR" "$ETC_DIR" "$DATA_DIR" || die "创建目录失败"
$SUDO chown "$EDITOR_USER:$EDITOR_USER" "$OPT_DIR" "$ETC_DIR" "$DATA_DIR" \
  || die "chown 失败"
$SUDO chmod 700 "$ETC_DIR" "$DATA_DIR"  # 配置（密码哈希/平台 key）与用户数据：仅属主可入
$SUDO chmod 755 "$OPT_DIR"              # 程序目录：其他用户可读可执行即可
info "目录就绪：$OPT_DIR(755) $ETC_DIR(700) $DATA_DIR(700)，属主 $EDITOR_USER"

# -------------------------- 3) gateway.json 模板（已存在则不覆盖，见 README 步骤 4）----
if [[ ! -e "$ETC_DIR/gateway.json" ]]; then
  if [[ -f "$SRC_DIR/gateway.json.example" ]]; then
    # install 一并设好属主与 600（仅 editor 可读，里面有密码哈希与 ai_relay.api_key）
    $SUDO install -m 600 -o "$EDITOR_USER" -g "$EDITOR_USER" \
      "$SRC_DIR/gateway.json.example" "$ETC_DIR/gateway.json" \
      || die "放置 gateway.json 失败"
    info "已放置 ${ETC_DIR}/gateway.json（来自示例，占位哈希必须替换）"
  else
    info "未找到 $SRC_DIR/gateway.json.example，跳过配置放置"
  fi
else
  info "$ETC_DIR/gateway.json 已存在，保留现有配置（不覆盖）"
fi

# --------------------------------- 4) systemd 单元（启停在 README 步骤 5 手动执行）----
if [[ -f "$SRC_DIR/editor-gateway.service" ]]; then
  $SUDO install -m 644 "$SRC_DIR/editor-gateway.service" \
    "/etc/systemd/system/editor-gateway.service" || die "安装 systemd 单元失败"
  info "已安装单元 editor-gateway.service（尚未启用）"
fi

info "完成。后续步骤见 README-部署.md："
echo "  - 解压 server-linux 包 → $OPT_DIR（含 backend 与 backend_gateway）"
echo "  - 解压 web-app.zip     → $OPT_DIR/web（对应 gateway.json 的 web_root）"
echo "  - 用 '$EDITOR_USER 身份跑 backend_gateway --hash-password' 生成真实哈希，"
echo "    编辑 $ETC_DIR/gateway.json（accounts、trusted_origins 换成你的域名）"
echo "  - sudo systemctl daemon-reload && sudo systemctl enable --now editor-gateway"
echo "  - 配置 Caddy（Caddyfile.example）并放行防火墙 443"

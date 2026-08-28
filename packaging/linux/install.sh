#!/usr/bin/env bash
# 「学生时代模组编辑器」Linux 安装向导（体验对齐 Windows Inno 安装包）。
#
# 交互安装：        ./install.sh
# 静默安装：        ./install.sh --yes [--dir <目录>] \
#                     [--components gui,tui,cli,officialpack] \
#                     [--commands gui,tui,cli] \
#                     [--desktop-icon|--no-desktop-icon]
# 卸载：            ./install.sh --uninstall [--dir <目录>] [--yes]
#
# 组件：Core（必选）、GUI / TUI / CLI（至少选一个）、官方资源扩展包；
# 命令：editor-gui / editor-tui / editor-cli（仅所选组件的命令可选）。
set -u -o pipefail

APP_NAME="学生时代模组编辑器"
PKG_ID="student-age-editor"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=""
COMPONENTS=""
COMMANDS=""
DESKTOP_ICON=""
MODE="install"
ASSUME_YES=0
BIN_DIR=""
DATA_DIR=""

# ---------------------------------------------------------------- 参数 ----

usage() {
  cat <<'EOF'
用法：install.sh [选项]

交互安装：直接运行（需 TTY）。静默安装需 --yes：
  --yes                     非交互执行（用缺省值或下方参数的指定值）
  --dir <目录>              安装目录（默认 ~/.local/share/student-age-editor，root 为 /opt/student-age-editor）
  --components <csv>        gui,tui,cli,officialpack（Core 必装；GUI/TUI/CLI 至少一个）
  --commands <csv>          创建命令，取值 gui,tui,cli（默认仅 cli）
  --desktop-icon            创建桌面图标（默认，仅 GUI 时有效）
  --no-desktop-icon         不创建桌面图标
  --uninstall               卸载（默认目录同 --dir 或上次安装目录）
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --components) COMPONENTS="${2:-}"; shift 2 ;;
    --commands) COMMANDS="${2:-}"; shift 2 ;;
    --desktop-icon) DESKTOP_ICON=1; shift ;;
    --no-desktop-icon) DESKTOP_ICON=0; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *)
      echo "错误：未知参数 $1（--help 查看用法）" >&2
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------ 交互工具 ----

if command -v whiptail >/dev/null 2>&1; then
  HAVE_WHIPTAIL=1
else
  HAVE_WHIPTAIL=0
fi

have_tty() { [[ -t 0 && -t 1 ]]; }
interactive() { [[ $ASSUME_YES -eq 0 && -t 0 ]]; }

prompt() {
  # prompt <标题> <缺省值> → 回显输入（交互）；静默模式回显缺省值
  local title="$1" def="${2:-}"
  if interactive; then
    if [[ $HAVE_WHIPTAIL -eq 1 ]]; then
      local out
      out="$(whiptail --title "$APP_NAME 安装" --inputbox "$title" 10 60 "$def" 3>&1 1>&2 2>&3)" || return 1
      echo "$out"
      return 0
    fi
    printf '%s [%s]: ' "$title" "$def"
    local v
    read -r v
    echo "${v:-$def}"
    return 0
  fi
  echo "$def"
}

checklist() {
  # checklist <标题> <高> <宽> <列表高> <item on/off 标题...>
  # 输出勾选项（csv），失败输出空串
  local title="$1"; shift
  local h="$1"; shift
  local w="$1"; shift
  local lh="$1"; shift
  local args=("$@")
  if interactive && [[ $HAVE_WHIPTAIL -eq 1 ]]; then
    local out
    out="$(whiptail --title "$APP_NAME 安装" --checklist "$title" "$h" "$w" "$lh" "${args[@]}" 3>&1 1>&2 2>&3)" || return 1
    # whiptail 输出形如 "gui" "cli"，去掉引号转 csv
    echo "$out" | sed 's/[" ]//g' | tr -s ',' ','
    return 0
  fi
  # 纯 bash 回退或多选不可用：逐个 yes/no
  local i pick v ret=""
  for ((i = 0; i < ${#args[@]}; i += 3)); do
    v="${args[$i]}"
    pick="${args[$((i + 1))]}"
    if interactive; then
      printf '%s（%s）[y/N]: ' "$pick" "$v"
      local r
      read -r r
      if [[ "${r,,}" == y* ]]; then
        ret="${ret:+$ret,}${args[$i]}"
      fi
    elif [[ "${pick,,}" == on ]]; then
      ret="${ret:+$ret,}${args[$i]}"
    fi
  done
  echo "$ret"
}

yesno() {
  # yesno <提示> → 0=是 1=否（交互 yesno；静默按 ASSUME_YES/缺省）
  local title="$1"
  if interactive; then
    if [[ $HAVE_WHIPTAIL -eq 1 ]]; then
      whiptail --title "$APP_NAME 安装" --yesno "$title" 10 60
      return $?
    fi
    printf '%s [y/N]: ' "$title"
    local r
    read -r r
    [[ "${r,,}" == y* ]]
    return $?
  fi
  return 0
}

info() { echo "[安装] $*"; }
warn() { echo "[警告] $*" >&2; }
die() { echo "[错误] $*" >&2; exit 1; }

# ------------------------------------------------------------ 数据目录 ----

# 与 backend/editor/core/paths.py 一致：exe 同目录可写探测（建+删临时文件）
dir_writable() {
  local d="$1"
  mkdir -p "$d" 2>/dev/null || return 1
  local p="$d/.write_probe_$$"
  if ( : > "$p" ) 2>/dev/null; then
    rm -f "$p"
    return 0
  fi
  return 1
}

app_data_dir() {
  if dir_writable "$INSTALL_DIR"; then
    echo "$INSTALL_DIR"
  else
    local base="${XDG_DATA_HOME:-$HOME/.local/share}"
    echo "$base/student-age-editor"
  fi
}

# ------------------------------------------------------------ Steam 探测 ----

steam_library_paths() {
  local roots home
  roots=()
  home="$(printf '%s' "$HOME")"
  for r in "$home/.steam/steam" "$home/.steam/root" "$home/.local/share/Steam" \
           "$home/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [[ -d "$r" ]] && roots+=("$r")
  done
  for root in "${roots[@]}"; do
    local vdf lib
    vdf="$root/steamapps/libraryfolders.vdf"
    [[ -f "$vdf" ]] || vdf="$root/config/libraryfolders.vdf"
    [[ -f "$vdf" ]] || continue
    while IFS= read -r line; do
      line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*"path"[[:space:]]*"([^"]*)".*$/\1/')"
      # 仅保留确实命中 "path" 行的内容
      [[ "$line" == *\"path\"* ]] && continue
      [[ -n "$line" ]] && echo "$line"
    done < "$vdf"
  done | sort -u
}

detect_mods_dirs() {
  # 返回第一个存在的候选 mods 工作区
  local lib
  while IFS= read -r lib; do
    local p="$lib/steamapps/compatdata/1991040/pfx/drive_c/users/steamuser/AppData/LocalLow/PakyiGame/StudentAge/Mods"
    if [[ -d "$p" ]]; then
      echo "$p"
      return 0
    fi
  done < <(steam_library_paths)
  return 1
}

detect_workshop_dir() {
  local lib
  while IFS= read -r lib; do
    local p="$lib/steamapps/workshop/content/1991040"
    if [[ -d "$p" ]]; then
      echo "$p"
      return 0
    fi
  done < <(steam_library_paths)
  return 1
}

# ---------------------------------------------------------------- 安装 ----

default_install_dir() {
  if [[ $EUID -eq 0 ]]; then
    echo "/opt/$PKG_ID"
  else
    echo "$HOME/.local/share/$PKG_ID"
  fi
}

resolve_components() {
  # 组件校验：Core 必选、GUI/TUI/CLI 至少一个；officialpack 可选
  local raw="$1" selected=0
  [[ -z "$raw" ]] && die "未指定组件（见 --help）"
  CORE_OK=1
  GUI=0; TUI=0; CLI=0; OFFICIAL=0
  case ",$raw," in
    *,gui,*) GUI=1 ;;
  esac
  case ",$raw," in
    *,tui,*) TUI=1 ;;
  esac
  case ",$raw," in
    *,cli,*) CLI=1 ;;
  esac
  case ",$raw," in
    *,officialpack,*) OFFICIAL=1 ;;
  esac
  ((GUI || TUI || CLI)) || return 1
  return 0
}

write_command() {
  # write_command <命令名> <可执行相对路径> <模式>
  local name="$1" rel="$2" mode="$3"
  if ! mkdir -p "$BIN_DIR"; then
    warn "无法创建命令目录 ${BIN_DIR}，跳过 $name"
    return 1
  fi
  local esc
  esc="${INSTALL_DIR//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  cat > "$BIN_DIR/$name" <<EOF
#!/bin/sh
# 学生时代模组编辑器 - $name 启动命令（由安装向导生成）
exec "$esc/$rel" $mode "\$@"
EOF
  chmod 0755 "$BIN_DIR/$name" || true
  echo "$BIN_DIR/$name"
}

install_component_gui() {
  local src="$SRC_DIR/$APP_NAME"
  [[ -e "$src" ]] || die "未找到 GUI 主程序 ${src}（zip 不完整？）"
  cp -R "$src" "$INSTALL_DIR/" || die "复制 GUI 主程序失败"
  for d in lib data; do
    if [[ -d "$SRC_DIR/$d" ]]; then
      cp -R "$SRC_DIR/$d" "$INSTALL_DIR/" || die "复制 $d/ 失败"
    fi
  done
  chmod 0755 "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
}

install_component_core() {
  cp -R "$SRC_DIR/backend" "$SRC_DIR/_internal" \
        "$SRC_DIR/使用说明.txt" "$INSTALL_DIR/" 2>/dev/null \
    || die "复制核心文件失败（zip 不完整？）"
  chmod 0755 "$INSTALL_DIR/backend" 2>/dev/null || true
}

install_official_pack() {
  if [[ -d "$SRC_DIR/official_pack" ]]; then
    cp -R "$SRC_DIR/official_pack" "$INSTALL_DIR/"

  else
    warn "本 zip 未内嵌官方资源包（official_pack/ 缺失），跳过该组件"
  fi
}

install_desktop_icon() {
  local apps_dir icons_dir
  if [[ $EUID -eq 0 ]]; then
    apps_dir="/usr/local/share/applications"
    icons_dir="/usr/local/share/icons/hicolor/512x512/apps"
  else
    apps_dir="$HOME/.local/share/applications"
    icons_dir="$HOME/.local/share/icons/hicolor/512x512/apps"
  fi
  mkdir -p "$apps_dir" "$icons_dir" || return 1
  sed "s|__INSTALL_DIR__|$INSTALL_DIR|g" "$SRC_DIR/student-age-editor.desktop" \
    > "$apps_dir/$PKG_ID.desktop" 2>/dev/null
  if [[ -f "$SRC_DIR/editor_icon.png" ]]; then
    cp "$SRC_DIR/editor_icon.png" "$icons_dir/$PKG_ID.png"
  else
    warn "未找到 editor_icon.png，图标留空"
    sed -i "s|^Icon=.*|Icon=|" "$apps_dir/$PKG_ID.desktop" 2>/dev/null || true
  fi
  chmod 0644 "$apps_dir/$PKG_ID.desktop" 2>/dev/null || true
  if [[ $EUID -ne 0 && -d "$HOME/Desktop" ]]; then
    cp "$apps_dir/$PKG_ID.desktop" "$HOME/Desktop/学生时代模组编辑器.desktop" 2>/dev/null || true
  fi
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -q "$icons_dir" >/dev/null 2>&1 || true
}

write_env_file() {
  DATA_DIR="$(app_data_dir)"
  mkdir -p "$DATA_DIR" || die "无法创建数据目录 $DATA_DIR"
  local env_file="$DATA_DIR/editor_env.json"
  if [[ -f "$env_file" ]]; then
    info "已有 ${env_file}，保留现有配置（不覆盖）"
    return 0
  fi
  local ws_def ws wk_def wk
  ws_def="$(detect_mods_dirs)" || ws_def="$DATA_DIR/Mods"
  wk_def="$(detect_workshop_dir)" || wk_def=""
  ws="$(prompt "本地模组工作区（Mods 存放位置）:" "$ws_def")"
  wk="$(prompt "Steam 创意工坊目录（留空跳过）:" "$wk_def")"
  [[ -z "$ws" ]] && ws="$ws_def"
  [[ -n "$ws" ]] && mkdir -p "$ws" 2>/dev/null
  local ws_esc wk_esc
  ws_esc="${ws//\\/\\\\}"; ws_esc="${ws_esc//\"/\\\"}"
  wk_esc="${wk//\\/\\\\}"; wk_esc="${wk_esc//\"/\\\"}"
  printf '{\n  "workspace_root": "%s",\n  "workshop_root": "%s"\n}\n' \
    "$ws_esc" "$wk_esc" > "$env_file"
  info "已写入 $env_file"
}

path_hint() {
  if case ":$PATH:" in *":$BIN_DIR:"*) false ;; *) true ;; esac; then
    warn "$BIN_DIR 不在 PATH 中；可手动执行：export PATH=\"$BIN_DIR:\$PATH\""
    if interactive && yesno "是否将 $BIN_DIR 追加到 ~/.bashrc 与 ~/.zshrc？"; then
      local block=""
      block="
# 学生时代模组编辑器命令路径（由 install.sh 追加）
case \":\$\{PATH\}:\" in *\":$BIN_DIR:\"*) ;; *) export PATH=\"$BIN_DIR:\$PATH\" ;; esac"
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -q "$BIN_DIR" "$rc"; then
          printf '%s\n' "$block" >> "$rc"
        fi
      done
      info "已写入 shell 配置文件，重开终端后生效"
    fi
  else
    info "命令已可用：editor-gui / editor-tui / editor-cli"
  fi
}

do_install() {
  INSTALL_DIR="${INSTALL_DIR:-$(default_install_dir)}"
  [[ -n "$INSTALL_DIR" ]] || die "未指定安装目录"
  if [[ $EUID -eq 0 ]]; then
    BIN_DIR="/usr/local/bin"
  else
    BIN_DIR="$HOME/.local/bin"
  fi
  resolve_components "${COMPONENTS:-gui,tui,cli,officialpack}" \
    || die "组件中必须至少选择 GUI / TUI / CLI 中的一项"
  mkdir -p "$INSTALL_DIR" || die "无法创建安装目录 $INSTALL_DIR"
  info "安装目录：$INSTALL_DIR"

  install_component_core
  if [[ $GUI -eq 1 ]]; then
    install_component_gui
  fi
  if [[ $OFFICIAL -eq 1 ]]; then
    install_official_pack
  fi

  # 命令（仅允许所选组件对应的命令；默认 cli，对齐 Windows 安装包勾选状态）
  local cmd_csv cmds
  cmd_csv="${COMMANDS:-cli}"
  cmds=""
  case ",$cmd_csv," in
    *,gui,*)
      if [[ $GUI -eq 1 ]]; then cmds="${cmds:+$cmds }editor-gui"; else warn "未选 GUI 组件，忽略 editor-gui"; fi ;;
  esac
  case ",$cmd_csv," in
    *,tui,*)
      if [[ $TUI -eq 1 ]]; then cmds="${cmds:+$cmds }editor-tui"; else warn "未选 TUI 组件，忽略 editor-tui"; fi ;;
  esac
  case ",$cmd_csv," in
    *,cli,*)
      if [[ $CLI -eq 1 ]]; then cmds="${cmds:+$cmds }editor-cli"; else warn "未选 CLI 组件，忽略 editor-cli"; fi ;;
  esac
  for c in $cmds; do
    case "$c" in
      editor-gui) write_command editor-gui "$APP_NAME" "" ;;
      editor-tui) write_command editor-tui backend tui ;;
      editor-cli) write_command editor-cli backend cli ;;
    esac
  done

  if [[ $GUI -eq 1 ]] && [[ "${DESKTOP_ICON:-1}" == 1 ]]; then
    install_desktop_icon
  fi

  write_env_file
  path_hint
  echo
  info "完成！启动方式："
  [[ $GUI -eq 1 ]] && echo "    $INSTALL_DIR/$APP_NAME"
  case " $cmds " in
    *" editor-tui "*) echo "    editor-tui（终端界面）" ;;
  esac
  case " $cmds " in
    *" editor-cli "*) echo "    editor-cli（命令行）" ;;
  esac
  echo "    卸载：${BASH_SOURCE[0]} --uninstall --dir $INSTALL_DIR"
}

# ---------------------------------------------------------------- 卸载 ----

remove_desktop_icon() {
  for dir in "$HOME/.local/share/applications" \
              "$HOME/.local/share/icons/hicolor/512x512/apps" \
              "$HOME/Desktop"; do
    rm -f "$dir/$PKG_ID.desktop" 2>/dev/null || true
    rm -f "$dir/学生时代模组编辑器.desktop" 2>/dev/null || true
    rm -f "$dir/$PKG_ID.png" 2>/dev/null || true
  done
  if [[ $EUID -eq 0 ]]; then
    rm -f "/usr/local/share/applications/$PKG_ID.desktop" \
          "/usr/local/share/icons/hicolor/512x512/apps/$PKG_ID.png" 2>/dev/null || true
  fi
}

do_uninstall() {
  INSTALL_DIR="${INSTALL_DIR:-$(default_install_dir)}"
  [[ -d "$INSTALL_DIR" ]] || die "$INSTALL_DIR 不存在，无需卸载"
  info "卸载安装目录：$INSTALL_DIR"
  if interactive && ! yesno "确认删除 ${INSTALL_DIR}？"; then
    echo "已取消卸载"
    exit 0
  fi
  # 命令
  local bin2
  for bin2 in "$HOME/.local/bin" /usr/local/bin; do
    rm -f "$bin2/editor-gui" "$bin2/editor-tui" "$bin2/editor-cli" 2>/dev/null || true
  done
  remove_desktop_icon
  # 数据目录（可能位于安装目录内，单独询问是否连同删除）
  local data
  data="$(app_data_dir)"
  if interactive && yesno "是否同时删除数据目录 ${data}（缓存/日志/配置）？"; then
    rm -rf "$data"
  fi
  rm -rf "$INSTALL_DIR"
  info "卸载完成"
}

# ----------------------------------------------------------------- 主流程 ----

if [[ $MODE == "uninstall" ]]; then
  do_uninstall
  exit 0
fi

if [[ $ASSUME_YES -eq 0 && $HAVE_WHIPTAIL -eq 1 && ! -t 0 ]]; then
  die "非交互环境（无 TTY）请加 --yes 参数"
fi

# 交互向导：目录 → 组件 → 命令 → 桌面图标 → 确认
if interactive; then
  INSTALL_DIR="$(prompt "安装目录:" "$(default_install_dir)")" || { echo "已取消"; exit 1; }
  while :; do
    COMPONENTS="$(checklist "选择组件（Core 必选；GUI/TUI/CLI 至少一个）:" 14 66 5 \
      gui "图形用户界面 (GUI) - 桌面主程序" on \
      tui "终端用户界面 (TUI) - 终端字符界面" off \
      cli "命令行接口 (CLI) - 自动化与脚本工具" on \
      officialpack "官方资源扩展包（适用于未安装游戏的创作者）" on)" || { echo "已取消"; exit 1; }
    if resolve_components "$COMPONENTS"; then
      break
    else
      if [[ $HAVE_WHIPTAIL -eq 1 ]]; then
        whiptail --title "$APP_NAME 安装" --msgbox "需要至少选择 GUI / TUI / CLI 之一。" 8 50 || { echo "已取消"; exit 1; }
      else
        echo "[提示] 需要至少选择 GUI / TUI / CLI 之一。"
      fi
    fi
  done
  # 命令清单仅列出已选组件对应的命令（默认勾选 editor-cli，对齐 Windows 安装包）
  local_cmds=()
  [[ $GUI -eq 1 ]] && local_cmds+=("editor-gui" "图形界面命令" "off")
  [[ $TUI -eq 1 ]] && local_cmds+=("editor-tui" "终端界面命令" "off")
  [[ $CLI -eq 1 ]] && local_cmds+=("editor-cli" "命令行命令" "on")
  COMMANDS="$(checklist "选择要加入 PATH 的命令:" 12 62 3 "${local_cmds[@]}")" || { echo "已取消"; exit 1; }
  if [[ $GUI -eq 1 ]]; then
    if yesno "是否将图标添加到桌面？"; then DESKTOP_ICON=1; else DESKTOP_ICON=0; fi
  else
    DESKTOP_ICON=0
  fi
  if interactive; then
    echo
    echo "安装目录：$INSTALL_DIR"
    echo "组件：Core + ${COMPONENTS:-（无）}"
    echo "命令：${COMMANDS:-（无）}"
    if ! yesno "确认开始安装？"; then
      echo "已取消"
      exit 1
    fi
  fi
else
  # 静默模式：_resolve 需要 resolve_components 校验；直接走 do_install
  :
fi

do_install
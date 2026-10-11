#!/usr/bin/env bash
# =============================================================================
#  NapCat 启动包装脚本（由 systemd / botctl 调用）
#
#  依据官方 NapCat-Installer 的 Linux rootless 安装方式：
#      INSTALL_BASE_DIR = $HOME/Napcat
#      QQ_EXECUTABLE    = $HOME/Napcat/opt/QQ/qq
#      TARGET_FOLDER    = $HOME/Napcat/opt/QQ/resources/app/app_launcher/napcat
#  启动就是直接跑那个 qq（它已经被注入 loadNapCat.js），无桌面环境要用 xvfb 兜底：
#      xvfb-run -a "$QQ_EXECUTABLE" --no-sandbox
#
#  ⚠️ 没有 napcat.sh 这种东西；/usr/local/bin/napcat 是独立的
#     NapCat-TUI-CLI 交互式菜单，需要终端，不能当启动器。
# =============================================================================
set -uo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd -P "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_self="$(cd -P "$(dirname "$_self")" && pwd)/$(basename "$_self")"

if [ -z "${_BOTAPP_CRLF:-}" ] && grep -q $'\r' "$_self" 2>/dev/null; then
  export _BOTAPP_CRLF=1
  sed -i 's/\r$//' "$_self" 2>/dev/null
  exec bash "$_self" "$@"
fi

SCRIPT_DIR="$(dirname "$_self")"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF_FILE="$BASE_DIR/config.conf"

if [ -f "$CONF_FILE" ]; then
  _SELF_BASE="$BASE_DIR"
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$CONF_FILE")
  BASE_DIR="${BASE_DIR:-$_SELF_BASE}"
fi

NAPCAT_MODE="${NAPCAT_MODE:-auto}"
NAPCAT_USE_XVFB="${NAPCAT_USE_XVFB:-yes}"

log()  { printf '[napcat] %s\n' "$*"; }
warn() { printf '[napcat] %s\n' "$*" >&2; }

# systemd 下没有终端，很多依赖会因为 TERM/LANG 未设置而报错
export TERM="${TERM:-xterm}"
export LANG="${LANG:-C.UTF-8}"

# ------------------------------------------------------------------ 定位安装目录
# 判据是「存在可执行的 opt/QQ/qq」，而不是「目录存在」或「有没有 napcat 命令」
detect_napcat_home() {
  local d hit
  for d in "${NAPCAT_DIR:-}" "$HOME/Napcat" /root/Napcat /opt/Napcat /home/*/Napcat; do
    [ -n "$d" ] || continue
    [ -x "$d/opt/QQ/qq" ] && { printf '%s' "$d"; return 0; }
  done
  hit="$(find /root /home /opt /vol1 /vol2 -maxdepth 7 -path '*/opt/QQ/qq' -type f 2>/dev/null | head -1)"
  if [ -n "$hit" ]; then printf '%s' "${hit%/opt/QQ/qq}"; return 0; fi
  return 1
}

# ------------------------------------------------------------------ custom 模式
if [ "$NAPCAT_MODE" = "custom" ] && [ -n "${NAPCAT_CUSTOM_CMD:-}" ]; then
  log "使用自定义启动命令：$NAPCAT_CUSTOM_CMD"
  exec bash -lc "$NAPCAT_CUSTOM_CMD"
fi

# ------------------------------------------------------------------ 启动
if NAPCAT_HOME="$(detect_napcat_home)"; then
  QQ_EXEC="$NAPCAT_HOME/opt/QQ/qq"
  log "NapCat 目录：$NAPCAT_HOME"
  log "QQ 可执行文件：$QQ_EXEC"
  cd "$NAPCAT_HOME" || exit 1

  if [ "$NAPCAT_USE_XVFB" = "yes" ] && [ -z "${DISPLAY:-}" ]; then
    if command -v xvfb-run >/dev/null 2>&1; then
      log "无 DISPLAY，使用 Xvfb 虚拟显示启动"
      exec xvfb-run -a -s "-screen 0 1080x900x24" "$QQ_EXEC" --no-sandbox
    fi
    warn "警告：没装 xvfb，QQ 很可能起不来。请执行： apt-get install -y xvfb"
  fi
  exec "$QQ_EXEC" --no-sandbox
fi

# ------------------------------------------------------------------ 没找到
cat >&2 <<'EOF'
[napcat] 启动失败：没找到 NapCat（判据是存在可执行的 <目录>/opt/QQ/qq）。

排查：
  1) 看看到底装到哪了：
       ls -la /root/Napcat/opt/QQ/qq
       find / -maxdepth 7 -path '*/opt/QQ/qq' -type f 2>/dev/null
       cat /usr/local/bin/napcat        # 这是 TUI-CLI，不是启动器，但能看到线索

  2) 如果确实没装，重装（注意 --cli n，TUI-CLI 对 systemd 没用）：
       cd /tmp && curl -fL -o napcat.sh \
         https://gh-proxy.com/https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh
       bash napcat.sh --docker n --cli n --proxy 1

  3) 如果装在了非默认位置，在 config.conf 里写死：
       NAPCAT_DIR="/你的/Napcat"

  4) 完全自定义启动方式：
       NAPCAT_MODE="custom"
       NAPCAT_CUSTOM_CMD="cd /root/Napcat && xvfb-run -a ./opt/QQ/qq --no-sandbox"
EOF
exit 1

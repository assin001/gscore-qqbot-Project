#!/usr/bin/env bash
# =============================================================================
#  botctl - bot-app 统一管理脚本（NapCat + GsCore + NoneBot2）
#  只跑 fnOS / Debian / Ubuntu，不依赖 Docker。
#
#  用法： ./botctl.sh <命令> [服务] [参数]
#
#    install            执行安装脚本（等价于 bash install.sh）
#    fetch-gscore [源URL] 只重新获取 GsCore 源码（多源自动探测，带进度）
#    start   [服务|all] 启动      stop  [服务|all] 停止
#    restart [服务|all] 重启      status           查看总览状态
#    log <服务> [行数|-f]        查看日志
#    units              生成/刷新 systemd 单元
#    enable  [服务|all] 配置开机自启（并立即启动）
#    disable [服务|all] 取消开机自启
#    qr                 显示 NapCat 登录二维码
#    napcat-ws <QQ号>   把 NapCat 反向 WS 指向 NoneBot2（自动填 token）
#    gscore-host        把 GsCore 监听地址改为 0.0.0.0（方便局域网开控制台）
#    gscore-config      显示 GsCore 配置文件路径与关键项
#    doctor             一键自检（venv/端口/令牌/连通性）
#    update             更新代码与依赖
#    uninstall          卸载（保留数据）
#
#  服务名：napcat | gscore | nonebot | all
# =============================================================================
set -uo pipefail
VERSION="1.0.0"

# ------------------------------ 解析脚本真实路径 -------------------------------
# 必须先把软链解到底：通过 /usr/local/bin/botctl 调用时，
# dirname $BASH_SOURCE 会得到 /usr/local/bin，从而找不到同目录的 config.conf。
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd -P "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_self="$(cd -P "$(dirname "$_self")" && pwd)/$(basename "$_self")"

# ------------------------------ CRLF 自愈 -------------------------------------
# 注意对「真实路径」操作，否则 sed -i 会把软链替换成普通文件副本
if [ -z "${_BOTAPP_CRLF:-}" ] && grep -q $'\r' "$_self" 2>/dev/null; then
  export _BOTAPP_CRLF=1
  sed -i 's/\r$//' "$_self" 2>/dev/null
  exec bash "$_self" "$@"
fi

SCRIPT_DIR="$(dirname "$_self")"
BASE_DIR="$SCRIPT_DIR"
CONF_FILE="$BASE_DIR/config.conf"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s[·]%s %s\n' "$CYA" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

if [ ! -f "$CONF_FILE" ]; then
  err "找不到 config.conf"
  err "  脚本真实路径  : $_self"
  err "  推断的安装目录: $BASE_DIR"
  err "  期望的配置文件: $CONF_FILE"
  err "  把整个 bot-app 目录整体搬走时漏了 config.conf？或用完整路径调用脚本试试："
  err "    /你的路径/botctl.sh status"
  exit 1
fi

# 从 Windows 传上来的脚本经常丢可执行位，顺手补上，省得下次还要手动 chmod
for _f in "$BASE_DIR/botctl.sh" "$BASE_DIR/install.sh" "$BASE_DIR/scripts/"*.sh; do
  if [ -f "$_f" ] && [ ! -x "$_f" ]; then
    chmod +x "$_f" 2>/dev/null || true
  fi
done
unset _f
# shellcheck disable=SC1090
source <(sed 's/\r$//' "$CONF_FILE")
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR}"

ENV_DIR="$BASE_DIR/env"
APP_DIR="$BASE_DIR/app"
LOG_DIR="$BASE_DIR/logs"
RUN_DIR="$BASE_DIR/run"
GSCORE_DIR="$APP_DIR/gscore"
NONEBOT_DIR="$APP_DIR/nonebot"
GSCORE_VENV="$ENV_DIR/gscore-venv"
NONEBOT_VENV="$ENV_DIR/nonebot-venv"

RUN_USER="${RUN_USER:-root}"
UNIT_DIR="/etc/systemd/system"
ALL_SERVICES="napcat gscore nonebot"
PANEL_PORT="${PANEL_PORT:-10236}"
NONEBOT_PORT="${NONEBOT_PORT:-8080}"
GSCORE_PORT="${GSCORE_PORT:-8765}"
NAPCAT_WEBUI_PORT="${NAPCAT_WEBUI_PORT:-6099}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# JSON 字符串转义（给面板用的机器可读输出）
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# 修改 config.conf 里的某个键（不存在则追加），改前先备份
conf_set() {
  local key="$1" val="$2" conf="$BASE_DIR/config.conf"
  [ -f "$conf" ] || { err "找不到 $conf"; return 1; }
  cp -a "$conf" "$conf.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$conf" "$key" "$val" <<'PY'
import io, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(path, encoding="utf-8").read()
new_line = '%s="%s"' % (key, val)
pat = re.compile(r'^[ \t]*' + re.escape(key) + r'=.*$', re.M)
if pat.search(text):
    text = pat.sub(lambda m: new_line, text, count=1)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += new_line + "\n"
io.open(path, "w", encoding="utf-8").write(text)
PY
}

# 交互确认。Web 后台调用时 BOTAPP_YES=1 自动通过，避免卡住。
ask_yes() {
  local prompt="$1" def="${2:-N}" ans
  if [ "${BOTAPP_YES:-0}" = "1" ]; then
    printf '%s[自动确认]\n' "$prompt"
    return 0
  fi
  read -r -p "$prompt" ans
  case "${ans:-$def}" in y|Y) return 0 ;; *) return 1 ;; esac
}

# =============================================================================
#  通用
# =============================================================================
systemd_ok() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
unit_path()  { printf '%s/bot-%s.service' "$UNIT_DIR" "$1"; }

svc_workdir() {
  case "$1" in
    napcat)  printf '%s' "$BASE_DIR" ;;
    gscore)  printf '%s' "$GSCORE_DIR" ;;
    nonebot) printf '%s' "$NONEBOT_DIR" ;;
    *) return 1 ;;
  esac
}

svc_exec() {
  case "$1" in
    napcat)  printf '%s' "$BASE_DIR/scripts/napcat-wrapper.sh" ;;
    # GsCore 的 --host/--port 命令行参数优先级高于 config.json，且会被写回配置。
    # 用它来保证监听地址与 config.conf 一致，不用去手改 JSON。
    gscore)  printf '%s' "$GSCORE_VENV/bin/python -m gsuid_core.core --host ${GSCORE_HOST:-0.0.0.0} --port $GSCORE_PORT" ;;
    nonebot) printf '%s' "$NONEBOT_VENV/bin/python $NONEBOT_DIR/bot.py" ;;
    *) return 1 ;;
  esac
}

svc_desc() {
  case "$1" in
    napcat)  printf 'NapCat (QQ 协议端)' ;;
    gscore)  printf 'GsCore (业务核心)' ;;
    nonebot) printf 'NoneBot2 (机器人框架)' ;;
  esac
}

svc_port() {
  case "$1" in
    napcat)  printf '%s' "$NAPCAT_WEBUI_PORT" ;;
    gscore)  printf '%s' "$GSCORE_PORT" ;;
    nonebot) printf '%s' "$NONEBOT_PORT" ;;
  esac
}

validate_service() {
  case "$1" in
    napcat|gscore|nonebot) return 0 ;;
    *) die "未知服务：$1（可选：napcat | gscore | nonebot | all）" ;;
  esac
}

expand_targets() {
  case "${1:-all}" in
    all) printf '%s' "$ALL_SERVICES" ;;
    *) validate_service "$1"; printf '%s' "$1" ;;
  esac
}

ensure_dirs() { mkdir -p "$LOG_DIR" "$RUN_DIR"; }
pid_file() { printf '%s/%s.pid' "$RUN_DIR" "$1"; }

lan_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-127.0.0.1}"
}

# 判断端口是否在监听。
# 之前只靠 `ss -ltn | grep`，在 ss 缺失或输出格式不同的系统上一律返回否，
# 于是三个服务明明在跑却全显示 ✗。现在多路兜底。
port_listening() {
  local p="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltn 2>/dev/null)"
  fi
  if [ -z "$out" ] && command -v netstat >/dev/null 2>&1; then
    out="$(netstat -ltn 2>/dev/null)"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | awk 'NF>=4 {print $4}' | grep -qE "[:.]$p\$" && return 0
    printf '%s\n' "$out" | grep -qE "[:.]$p[[:space:]]" && return 0
  fi
  # 最后直接实测一次 TCP 连接
  tcp_probe "$p"
}

tcp_probe() {
  timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$1" 2>/dev/null
}

# 定位 NapCat 安装目录（就是 $HOME/Napcat 这种根目录）。
# 判据是存在可执行的 opt/QQ/qq —— 官方 rootless 安装的产物。
# 不要用 `command -v napcat`：那是独立的 TUI 交互菜单，装了它不代表 NapCat 装好了。
napcat_home() {
  local d hit
  for d in "${NAPCAT_DIR:-}" "$HOME/Napcat" /root/Napcat /opt/Napcat /home/*/Napcat; do
    [ -n "$d" ] || continue
    [ -x "$d/opt/QQ/qq" ] && { printf '%s' "$d"; return 0; }
  done
  hit="$(find /root /home /opt /vol1 /vol2 -maxdepth 7 -path '*/opt/QQ/qq' -type f 2>/dev/null | head -1)"
  [ -n "$hit" ] && { printf '%s' "${hit%/opt/QQ/qq}"; return 0; }
  return 1
}

# 反查 GsCore 桥接插件的真实模块名。
# 发行包名与模块名不一致：nonebot-plugin-genshinuid 的模块叫 GenshinUID，
# 所以不能用 `import nonebot_plugin_genshinuid` 来判断是否安装。
bridge_module() {
  local venv="${1:-$NONEBOT_VENV}"
  [ -x "$venv/bin/python" ] || return 1
  "$venv/bin/python" - <<'PY' 2>/dev/null
import importlib.metadata as md
want = {"nonebot-plugin-genshinuid", "nonebot-plugin-gscore"}
try:
    mapping = md.packages_distributions()
except Exception:
    raise SystemExit(1)
for mod, dists in mapping.items():
    if any((d or "").lower().replace("_", "-") in want for d in dists):
        print(mod)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# NapCat 的配置目录：webui.json、onebot11_<QQ>.json 都在这里
napcat_config_dir() {
  local home
  home="$(napcat_home)" || return 1
  printf '%s' "$home/opt/QQ/resources/app/app_launcher/napcat/config"
}

find_gscore_config() {
  local c
  for c in "$GSCORE_DIR/data/config.json" "$GSCORE_DIR/gsuid_core/data/config.json"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  # 兜底：在仓库里搜（不同版本数据目录位置变过）
  c="$(find "$GSCORE_DIR" -maxdepth 4 -name config.json 2>/dev/null | head -1)"
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# =============================================================================
#  systemd 单元
# =============================================================================
write_units() {
  if ! systemd_ok; then
    warn "当前环境没有 systemd，将使用 nohup + PID 文件方式管理服务"
    return 1
  fi
  mkdir -p "$UNIT_DIR" "$LOG_DIR" "$RUN_DIR"

  cat > "$(unit_path napcat)" <<EOF
[Unit]
Description=bot-app - $(svc_desc napcat)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$(svc_workdir napcat)
ExecStart=$(svc_exec napcat)
Restart=always
RestartSec=10
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TERM=xterm
Environment=LANG=C.UTF-8
StandardOutput=append:$LOG_DIR/napcat.log
StandardError=append:$LOG_DIR/napcat.log

[Install]
WantedBy=multi-user.target
EOF

  # 配了本地代理就透传给 GsCore，它自己装插件时要 clone GitHub，没代理会失败
  local gs_proxy_env=""
  if [ -n "${HTTP_PROXY_URL:-}" ]; then
    gs_proxy_env="Environment=GSCORE_HTTP_PROXY=$HTTP_PROXY_URL
Environment=GSCORE_HTTPS_PROXY=$HTTP_PROXY_URL
Environment=HTTPS_PROXY=$HTTP_PROXY_URL"
  fi

  cat > "$(unit_path gscore)" <<EOF
[Unit]
Description=bot-app - $(svc_desc gscore)
After=network-online.target bot-napcat.service
Wants=network-online.target bot-napcat.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$(svc_workdir gscore)
ExecStart=$(svc_exec gscore)
Restart=always
RestartSec=8
$gs_proxy_env
Environment=PATH=$GSCORE_VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:$LOG_DIR/gscore.log
StandardError=append:$LOG_DIR/gscore.log

[Install]
WantedBy=multi-user.target
EOF

  cat > "$(unit_path nonebot)" <<EOF
[Unit]
Description=bot-app - $(svc_desc nonebot)
After=network-online.target bot-gscore.service
Wants=network-online.target bot-gscore.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$(svc_workdir nonebot)
ExecStart=$(svc_exec nonebot)
Restart=always
RestartSec=8
Environment=PATH=$NONEBOT_VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:$LOG_DIR/nonebot.log
StandardError=append:$LOG_DIR/nonebot.log

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log "systemd 单元已生成：bot-napcat / bot-gscore / bot-nonebot"
}

# =============================================================================
#  启停实现
# =============================================================================
using_systemd() { systemd_ok && [ -f "$(unit_path "$1")" ]; }

svc_state() {
  local s="$1"
  if using_systemd "$s"; then
    systemctl is-active "bot-$s.service" 2>/dev/null || true
  else
    local pf; pf="$(pid_file "$s")"
    if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
      printf 'active'
    else
      printf 'inactive'
    fi
  fi
}

nohup_start() {
  local s="$1" pf logf wd cmd
  pf="$(pid_file "$s")"; logf="$LOG_DIR/$s.log"
  wd="$(svc_workdir "$s")"; cmd="$(svc_exec "$s")"
  if [ ! -d "$wd" ]; then err "$s 工作目录不存在：$wd"; return 1; fi
  ensure_dirs
  ( cd "$wd" && nohup bash -c "$cmd" >>"$logf" 2>&1 & echo $! > "$pf" )
  sleep 1
  if kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    log "$s 已启动（PID $(cat "$pf")）"
  else
    err "$s 启动失败，查看日志： ./botctl.sh log $s"
    return 1
  fi
}

nohup_stop() {
  local s="$1" pf pid
  pf="$(pid_file "$s")"
  [ -f "$pf" ] || { info "$s 未在运行"; return 0; }
  pid="$(cat "$pf" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 15); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    log "$s 已停止"
  fi
  rm -f "$pf"
}

svc_start() {
  local s="$1"
  if systemd_ok; then
    [ -f "$(unit_path "$s")" ] || write_units || { nohup_start "$s"; return $?; }
    systemctl start "bot-$s.service" && log "$s 已启动"
  else
    nohup_start "$s"
  fi
}

svc_stop() {
  local s="$1"
  if using_systemd "$s"; then
    systemctl stop "bot-$s.service" && log "$s 已停止"
  else
    nohup_stop "$s"
  fi
}

svc_restart() {
  local s="$1"
  if using_systemd "$s"; then
    systemctl restart "bot-$s.service" && log "$s 已重启"
  else
    nohup_stop "$s"; nohup_start "$s"
  fi
}

# =============================================================================
#  Web 后台
# =============================================================================
write_panel_unit() {
  local py="${1:-python3}"
  [ -f "$BASE_DIR/panel/panel.py" ] || die "缺少 panel/panel.py"
  cat > "$(unit_path panel)" <<EOF
[Unit]
Description=bot-app - Web 后台
# 刻意不依赖另外三个服务：服务挂了也要能进后台操作
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$BASE_DIR
ExecStart=$py $BASE_DIR/panel/panel.py
Restart=always
RestartSec=5
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TERM=xterm
Environment=LANG=C.UTF-8
StandardOutput=append:$LOG_DIR/panel.log
StandardError=append:$LOG_DIR/panel.log

[Install]
WantedBy=multi-user.target
EOF
}

cmd_panel_url() {
  printf '  后台地址： %shttp://%s:%s%s\n' "$GRN" "$(lan_ip)" "$PANEL_PORT" "$RST"
}

# 改 Web 后台端口
cmd_panel_port() {
  local port="${1:-}"
  if [ -z "$port" ]; then
    info "当前面板端口：$PANEL_PORT"
    info "改端口： ./botctl.sh panel port 新端口（比如 10236）"
    return 0
  fi
  case "$port" in *[!0-9]*) die "端口必须是纯数字" ;; esac
  if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    die "端口范围应为 1024-65535（1024 以下需要额外权限）"
  fi
  if [ "$port" = "$PANEL_PORT" ]; then
    info "面板已经是 $port，无需修改"
    return 0
  fi

  if port_listening "$port"; then
    warn "端口 $port 看起来已被占用："
    if command -v ss >/dev/null 2>&1; then
      ss -ltnp 2>/dev/null | grep -E "[:.]$port[[:space:]]" | sed 's/^/      /'
    fi
    ask_yes "  仍然改用它？[y/N] " N || return 0
  fi

  conf_set PANEL_PORT "$port" || die "写入 config.conf 失败"
  log "面板端口已改为 $port（config.conf 已备份）"

  if systemd_ok && [ -f "$(unit_path panel)" ]; then
    if systemctl restart bot-panel.service; then
      sleep 1
      info "面板已重启"
    else
      warn "重启失败，看 ./botctl.sh panel log"
    fi
  else
    warn "面板没装成系统服务，请手动重启： python3 $BASE_DIR/panel/panel.py"
  fi

  PANEL_PORT="$port"
  cmd_panel_url
  warn "别忘了在 fnOS 防火墙放通 $port"
}

# 端口总览（看谁在用、有没有冲突）
show_port_line() {
  local label="$1" port="$2" note="$3" st
  if port_listening "$port"; then
    st="${GRN}监听中${RST}"
  else
    st="${YEL}未监听${RST}"
  fi
  printf '    %-18s %-7s %s   %s\n' "$label" "$port" "$st" "$note"
}

cmd_ports() {
  printf '\n  %s端口一览%s\n\n' "$BLD" "$RST"
  printf '    %-18s %-7s %-14s %s\n' "用途" "端口" "状态" "说明"
  show_port_line "Web 后台"     "$PANEL_PORT"        "不常用（10236）"
  show_port_line "NoneBot2"     "$NONEBOT_PORT"      "8080 极常用，最容易冲突"
  show_port_line "GsCore"       "$GSCORE_PORT"       "8765"
  show_port_line "NapCat WebUI" "$NAPCAT_WEBUI_PORT" "6099"

  echo
  printf '    %s改端口：%s\n' "$BLD" "$RST"
  printf '      Web 后台     : ./botctl.sh panel port 新端口      （自动改配置并重启）\n'
  printf '      NoneBot2     : 改 config.conf 的 NONEBOT_PORT，然后\n'
  printf '                       ./botctl.sh napcat-ws 你的QQ号 && ./botctl.sh restart all\n'
  printf '      GsCore       : 改 config.conf 的 GSCORE_PORT，同时改 app/nonebot/.env 的\n'
  printf '                       gsuid_core_port，再 ./botctl.sh restart all\n'
  printf '      NapCat WebUI : 改 config.conf 的 NAPCAT_WEBUI_PORT，同时改 NapCat 的\n'
  printf '                       webui.json 里的 port，再 ./botctl.sh restart napcat\n\n'
}

cmd_panel_password() {
  local conf="$BASE_DIR/panel/panel.conf" new="${1:-}" old
  if [ ! -f "$conf" ]; then
    warn "还没有生成密码（面板首次启动时自动创建）"
    info "先执行： ./botctl.sh panel install"
    return 0
  fi

  if [ -n "$new" ]; then
    cp -a "$conf" "$conf.bak.$(date +%Y%m%d%H%M%S)"
    if grep -q '^PANEL_PASSWORD=' "$conf"; then
      python3 - "$conf" "$new" <<'PY'
import io, sys
path, val = sys.argv[1], sys.argv[2]
lines = io.open(path, encoding="utf-8").read().splitlines()
out = ['PANEL_PASSWORD="%s"' % val if ln.startswith("PANEL_PASSWORD=") else ln
       for ln in lines]
io.open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
    else
      printf 'PANEL_PASSWORD="%s"\n' "$new" >> "$conf"
    fi
    log "面板密码已更新"
    if systemd_ok && [ -f "$(unit_path panel)" ]; then
      systemctl restart bot-panel.service >/dev/null 2>&1 && info "面板已重启"
    fi
    return 0
  fi

  old="$(grep -E '^PANEL_PASSWORD=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
  if [ -n "$old" ]; then
    printf '  面板密码： %s%s%s\n' "$GRN" "$old" "$RST"
  else
    warn "配置文件里没有 PANEL_PASSWORD"
  fi
  printf '  修改密码： ./botctl.sh panel password 你的新密码\n'
}

# 面板没装成服务时，start/stop/restart 自动补装，而不是甩一条 systemctl 报错
panel_ensure_installed() {
  using_systemd panel && return 0
  if [ ! -f "$BASE_DIR/panel/panel.py" ]; then
    err "缺少 $BASE_DIR/panel/panel.py"
    err "  说明 panel/ 目录没同步到 NAS（面板是后加的，早期安装包里没有）"
    err "  把整个 panel/ 目录（panel.py + index.html）传到 $BASE_DIR/ 下面即可"
    return 1
  fi
  info "面板还没装成系统服务，先自动安装…"
  cmd_panel install
  using_systemd panel
}

cmd_panel() {
  local sub="${1:-status}" arg="${2:-}" py st pid
  py="$(command -v "$PYTHON_BIN" 2>/dev/null || command -v python3 || echo python3)"

  case "$sub" in
    install)
      systemd_ok || die "本机没有 systemd"
      if [ ! -f "$BASE_DIR/panel/panel.py" ]; then
        err "缺少 $BASE_DIR/panel/panel.py，先把 panel/ 目录同步到 $BASE_DIR/"
        return 1
      fi
      mkdir -p "$LOG_DIR" "$BASE_DIR/panel"
      write_units >/dev/null 2>&1 || true
      write_panel_unit "$py"
      systemctl daemon-reload
      systemctl enable bot-panel.service >/dev/null 2>&1 || true
      systemctl restart bot-panel.service >/dev/null 2>&1 || true
      sleep 1
      if systemctl is-active --quiet bot-panel.service; then
        log "Web 后台已安装并启动（已设为开机自启）"
        cmd_panel_url
        cmd_panel_password
      else
        warn "Web 后台没能启动。"
        if [ -s "$LOG_DIR/panel.log" ]; then
          printf '      最近日志（%s）：\n' "$LOG_DIR/panel.log"
          tail -n 20 "$LOG_DIR/panel.log" | sed 's/^/      /'
        else
          warn "  日志还是空的：$LOG_DIR/panel.log"
          warn "  手动跑一次直接看报错： $py $BASE_DIR/panel/panel.py"
        fi
        warn "常见原因：端口 $PANEL_PORT 被占用、panel.py 传输时被截断、Python 版本太低"
      fi
      ;;
    start)   panel_ensure_installed || return 1
             systemctl start bot-panel.service && log "后台已启动" ;;
    stop)    if ! using_systemd panel; then info "面板本来就没在跑"; return 0; fi
             systemctl stop bot-panel.service && log "后台已停止（之后只能用 SSH 恢复了）" ;;
    restart) panel_ensure_installed || return 1
             systemctl restart bot-panel.service && log "后台已重启" ;;
    enable)  panel_ensure_installed || return 1
             systemctl enable bot-panel.service >/dev/null 2>&1 && log "面板已设为开机自启" ;;
    disable) systemctl disable bot-panel.service >/dev/null 2>&1 && log "面板已取消开机自启" ;;
    url)     cmd_panel_url ;;
    port)    cmd_panel_port "$arg" ;;
    password) cmd_panel_password "$arg" ;;
    log|logs)
      if [ -s "$LOG_DIR/panel.log" ]; then
        tail -n "${arg:-50}" "$LOG_DIR/panel.log"
      else
        warn "还没有日志（面板可能没启动过）：$LOG_DIR/panel.log"
        info "手动跑一次看看： $py $BASE_DIR/panel/panel.py"
      fi
      ;;
    status|*)
      printf '\n  %sWeb 后台%s\n\n' "$BLD" "$RST"
      if [ ! -f "$BASE_DIR/panel/panel.py" ]; then
        printf '      %s未安装（缺少 panel/panel.py）%s\n\n' "$RED" "$RST"
        return 0
      fi
      if using_systemd panel; then
        st="$(systemctl is-active bot-panel.service 2>/dev/null || true)"
        pid="$(systemctl show -p MainPID --value bot-panel.service 2>/dev/null)"
        if [ "$st" = "active" ]; then
          printf '      状态：%s运行中%s（PID %s）\n' "$GRN" "$RST" "$pid"
        else
          printf '      状态：%s%s%s\n' "$YEL" "$st" "$RST"
        fi
        systemctl is-enabled bot-panel.service >/dev/null 2>&1 \
          && printf '      自启：%s已启用%s\n' "$GRN" "$RST" \
          || printf '      自启：%s未启用（./botctl.sh panel install）%s\n' "$YEL" "$RST"
      else
        printf '      状态：%s未安装为系统服务（./botctl.sh panel install）%s\n' "$YEL" "$RST"
      fi
      cmd_panel_url
      cmd_panel_password
      printf '      日志： ./botctl.sh panel log 100\n\n'
      ;;
  esac
}

# 给 Web 后台用的机器可读总览（JSON）
cmd_json_overview() {
  local s st pid listening enabled first=1
  printf '{"version":%s,"base_dir":%s,"lan_ip":%s,' \
    "$(json_str "$VERSION")" "$(json_str "$BASE_DIR")" "$(json_str "$(lan_ip)")"
  printf '"gscore_port":%s,"napcat_webui_port":%s,"panel_port":%s,"services":[' \
    "$(json_str "$GSCORE_PORT")" "$(json_str "$NAPCAT_WEBUI_PORT")" "$(json_str "$PANEL_PORT")"

  for s in $ALL_SERVICES; do
    [ "$first" = "1" ] || printf ','
    first=0
    st="$(svc_state "$s")"
    if using_systemd "$s"; then
      pid="$(systemctl show -p MainPID --value "bot-$s.service" 2>/dev/null)"
      if systemctl is-enabled "bot-$s.service" >/dev/null 2>&1; then enabled="true"; else enabled="false"; fi
    else
      pid="$(cat "$(pid_file "$s")" 2>/dev/null)"
      enabled="false"
    fi
    [ -n "$pid" ] && [ "$pid" != "0" ] || pid=""
    if port_listening "$(svc_port "$s")"; then listening="true"; else listening="false"; fi
    printf '{"name":"%s","desc":%s,"state":"%s","pid":"%s","port":"%s","listening":%s,"enabled":%s}' \
      "$s" "$(json_str "$(svc_desc "$s")")" "$st" "$pid" "$(svc_port "$s")" "$listening" "$enabled"
  done
  printf ']}'
  echo
}

# =============================================================================
#  命令：状态
# =============================================================================
cmd_status() {
  local ip; ip="$(lan_ip)"
  printf '\n%sbot-app %s  安装目录：%s%s\n\n' "$BLD" "$VERSION" "$BASE_DIR" "$RST"

  if systemd_ok; then
    info "管理模式：systemd"
  else
    info "管理模式：nohup + PID 文件"
  fi
  echo
  printf '  %-9s %-10s %-8s %-7s %s\n' "服务" "状态" "PID" "端口" "说明"
  printf '  %s\n' "----------------------------------------------------------------------"
  local s st pid port note
  for s in $ALL_SERVICES; do
    st="$(svc_state "$s")"
    port="$(svc_port "$s")"
    if using_systemd "$s"; then
      pid="$(systemctl show -p MainPID --value "bot-$s.service" 2>/dev/null)"
    else
      pid="$(cat "$(pid_file "$s")" 2>/dev/null)"
    fi
    [ -n "${pid:-}" ] && [ "$pid" != "0" ] || pid="-"
    case "$s" in
      napcat)  note="WebUI http://$ip:$port" ;;
      gscore)  note="控制台 http://$ip:$port/app" ;;
      nonebot) note="反向上报 ws://127.0.0.1:$port/onebot/v11/ws" ;;
    esac
    if [ "$st" = "active" ]; then
      printf '  %-9s %s%-10s%s %-8s %-7s %s\n' "$s" "$GRN" "运行中" "$RST" "$pid" "$port" "$note"
    else
      printf '  %-9s %s%-10s%s %-8s %-7s %s\n' "$s" "$RED" "已停止" "$RST" "$pid" "$port" "$note"
    fi
  done
  echo
  printf '  %-9s ' "端口监听:"
  for s in $ALL_SERVICES; do
    if port_listening "$(svc_port "$s")"; then printf '%s(%s✓) ' "$s" "$(svc_port "$s")"; else printf '%s(%s✗) ' "$s" "$(svc_port "$s")"; fi
  done
  echo; echo
  printf '  开机自启: '
  local any=0
  for s in $ALL_SERVICES; do
    if using_systemd "$s" && systemctl is-enabled "bot-$s.service" >/dev/null 2>&1; then printf '%s(启用) ' "$s"; any=1; fi
  done
  [ "$any" = "0" ] && printf '未配置（执行 ./botctl.sh enable all）'
  echo

  if using_systemd panel; then
    if [ "$(systemctl is-active bot-panel.service 2>/dev/null || true)" = "active" ]; then
      printf '  Web 后台: %s运行中%s  http://%s:%s  （密码： ./botctl.sh panel password）\n' \
        "$GRN" "$RST" "$(lan_ip)" "$PANEL_PORT"
    else
      printf '  Web 后台: %s未运行%s  → ./botctl.sh panel start\n' "$YEL" "$RST"
    fi
  fi
  echo
}

# =============================================================================
#  命令：日志 / 二维码
# =============================================================================
cmd_log() {
  local s="${1:-}" n="${2:-60}" logf
  [ -n "$s" ] || die "用法： ./botctl.sh log <napcat|gscore|nonebot> [行数|-f]"
  validate_service "$s"
  logf="$LOG_DIR/$s.log"
  if [ ! -f "$logf" ]; then
    warn "日志文件还不存在：$logf"
    if using_systemd "$s"; then
      info "改从 journalctl 读取"
      systemctl status "bot-$s.service" --no-pager -n "$n" 2>/dev/null || true
    fi
    return 0
  fi
  if [ "$n" = "-f" ] || [ "$n" = "follow" ]; then
    info "实时跟踪 $logf（Ctrl+C 退出）"
    tail -f "$logf"
  else
    tail -n "$n" "$logf"
  fi
}

cmd_qr() {
  local logf="$LOG_DIR/napcat.log" home
  printf '\n%sNapCat 登录二维码%s\n\n' "$BLD" "$RST"

  if [ -f "$logf" ]; then
    if grep -qiE 'qrcode|二维码' "$logf"; then
      info "日志中的二维码相关记录："
      grep -inE 'qrcode|二维码' "$logf" | tail -n 10
      echo
    fi
    local urls
    urls="$(grep -oE 'https?://[^ "]+' "$logf" | tail -n 5)"
    if [ -n "$urls" ]; then
      info "日志里出现的链接（可能是二维码页，复制到浏览器打开后截图扫码）："
      printf '%s\n\n' "$urls"
    fi
  else
    warn "还没有日志：$logf（先执行 ./botctl.sh start napcat）"
  fi

  if home="$(napcat_home)"; then
    info "NapCat 目录：$home"
    local imgs
    imgs="$(find "$home" "$HOME/.config/QQ" -maxdepth 7 -iname '*qr*' -type f -mmin -120 2>/dev/null | head -n 5)"
    if [ -n "$imgs" ]; then
      info "最近 1 小时生成的二维码图片："
      printf '%s\n' "$imgs"
      echo
      info "把图片下载到手机同局域网可访问的位置，或用 WebUI 打开。"
    fi
  fi

  cat <<EOF
最省事的两种扫码方式：
  1) 打开 NapCat WebUI → http://$(lan_ip):$NAPCAT_WEBUI_PORT
     登录 token 用 ./botctl.sh napcat-token 查看（它会直接给出带 token 的链接）。
  2) 用 SCP 之类把二维码图片拉到本地看：
     find $(napcat_home 2>/dev/null || echo '/root/Napcat') -name '*qr*' -type f

EOF
}

# =============================================================================
#  命令：开机自启
# =============================================================================
cmd_enable() {
  local targets; targets="$(expand_targets "${1:-all}")"
  if ! systemd_ok; then
    warn "没有 systemd，改用 cron @reboot 实现开机自启"
    local line="@reboot $BASE_DIR/botctl.sh start all"
    ( crontab -l 2>/dev/null | grep -v 'botctl.sh start all'; echo "$line" ) | crontab -
    log "已写入 crontab：$line"
    return 0
  fi
  write_units || return 1
  for s in $targets; do
    systemctl enable --now "bot-$s.service" >/dev/null 2>&1 \
      && log "$s 已设为开机自启并启动" \
      || warn "$s 设置失败，可执行 ./botctl.sh log $s 查看"
  done
}

cmd_disable() {
  local targets; targets="$(expand_targets "${1:-all}")"
  for s in $targets; do
    if using_systemd "$s"; then
      systemctl disable --now "bot-$s.service" >/dev/null 2>&1 && log "$s 已取消开机自启并停止"
    fi
  done
  crontab -l 2>/dev/null | grep -v 'botctl.sh start all' | crontab - 2>/dev/null || true
}

# =============================================================================
#  命令：配置辅助
# =============================================================================
cmd_napcat_token() {
  local home cfg token url nb_token found=0
  printf '\n%sNapCat 里有两个 token，别搞混%s\n\n' "$BLD" "$RST"

  # ---------------- ① WebUI 登录 token ----------------
  printf '  %s[1] WebUI 登录 token%s  登录 %s 控制台时用\n' "$BLD" "$RST" "$NAPCAT_WEBUI_PORT"
  local cdir=""
  if cdir="$(napcat_config_dir)"; then
    info "NapCat 目录：$(napcat_home)"
    info "配置目录  ：$cdir"
    cfg="$cdir/webui.json"
    if [ -f "$cfg" ]; then
      found=1
      token="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('token',''))" "$cfg" 2>/dev/null)"
      if [ -z "$token" ]; then
        token="$(grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')"
      fi
      if [ -n "$token" ]; then
        printf '      token = %s%s%s\n' "$GRN" "$token" "$RST"
        printf '      免手填直达（局域网内）：http://%s:%s/webui?token=%s\n' "$(lan_ip)" "$NAPCAT_WEBUI_PORT" "$token"
      else
        warn "读到了 $cfg，但没解析出 token 字段，手动看一眼"
      fi
    else
      warn "还没有 $cfg"
      warn "→ NapCat 从未成功启动过。先： botctl start napcat  然后： botctl log napcat"
    fi
  else
    warn "没找到 NapCat 安装目录（判据：存在可执行的 <目录>/opt/QQ/qq）"
    warn "→ 说明 NapCat 没装好，执行： bash install.sh --only-napcat"
  fi

  # 启动日志里也有，格式：.../webui?token=xxxxx
  if [ -f "$LOG_DIR/napcat.log" ]; then
    url="$(grep -oE 'https?://[^ ]*/webui\?token=[^ ]*' "$LOG_DIR/napcat.log" 2>/dev/null | tail -1)"
    [ -n "$url" ] && info "启动日志里也有一份：$url"
  fi

  # ---------------- ② 反向 WS token ----------------
  echo
  printf '  %s[2] 反向 WS token%s  NapCat 上报给 NoneBot2 时校验用（我们生成的）\n' "$BLD" "$RST"
  nb_token="$(grep -E '^ONEBOT_ACCESS_TOKEN=' "$NONEBOT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$nb_token" ]; then
    printf '      token = %s%s%s\n' "$GRN" "$nb_token" "$RST"
    printf '      位置  : %s/.env\n' "$NONEBOT_DIR"
    printf '      用法  : NapCat WebUI → 网络配置 → 新建 → WebSocket 客户端\n'
    printf '              URL = ws://127.0.0.1:%s/onebot/v11/ws\n' "$NONEBOT_PORT"
    printf '              或者直接跑： botctl napcat-ws <你的QQ号>\n'
  else
    warn "读不到 ONEBOT_ACCESS_TOKEN（$NONEBOT_DIR/.env）"
  fi
  echo
}

cmd_napcat_ws() {
  local qq="${1:-}"
  [ -n "$qq" ] || die "用法： ./botctl.sh napcat-ws <你的QQ号>"

  local cdir cfg url token
  cdir="$(napcat_config_dir)" || die "找不到 NapCat 配置目录（判据：存在可执行的 <目录>/opt/QQ/qq）。先执行： bash install.sh --only-napcat"
  cfg="$cdir/onebot11_$qq.json"
  url="ws://127.0.0.1:$NONEBOT_PORT/onebot/v11/ws"
  token="$(grep -E '^ONEBOT_ACCESS_TOKEN=' "$NONEBOT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"

  mkdir -p "$cdir"
  [ -f "$cfg" ] && cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"

  python3 - "$cfg" "$url" "$token" <<'PY' || die "写入 NapCat 配置失败"
import json, os, sys
path, url, token = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f) or {}
    except Exception:
        data = {}
net = data.setdefault("network", {})
clients = net.setdefault("websocketClients", [])
item = {
    "name": "NoneBot2",
    "enable": True,
    "url": url,
    "reportSelfMessage": False,
    "messagePostFormat": "array",
    "token": token,
    "debug": False,
    "heartInterval": 30000,
    "reconnectInterval": 3000,
}

def is_ours(c):
    # 按名称或 URL 认领：名称是脚本用来定位条目的标识，URL 用来兜住改名过的情况
    return isinstance(c, dict) and (c.get("name") == "NoneBot2" or c.get("url") == url)

hit = [i for i, c in enumerate(clients) if is_ours(c)]
if hit:
    keep = hit[0]
    clients[keep] = {**item, **clients[keep], "url": url, "token": token, "enable": True}
    # 同一目标挂了多条会重复上报消息，清掉多余的
    for i in reversed(hit[1:]):
        clients.pop(i)
    if len(hit) > 1:
        print("已清理重复的 WebSocket 客户端条目：%d 条" % (len(hit) - 1))
else:
    clients.append(item)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("已写入:", path)
PY

  log "已把 NapCat 反向 WS 指向 $url"
  info "配置里的 token 与 NoneBot2 .env 的 ONEBOT_ACCESS_TOKEN 保持一致"
  warn "如果 NapCat 已经在运行，请在 WebUI 里确认这条「WebSocket 客户端」是启用状态（或重启 napcat）"
}

# GsCore 控制台专项诊断：页面能开但接口全挂时用这个。
# GsCore 的前端(dist)和 API 路由是分开挂载的，API 导入失败只写日志不报错，
# 所以必须看日志 + 直接 curl 接口状态码。
# 用符合要求的 Python 重建 GsCore 虚拟环境并重装依赖。
# GsCore 控制台在 Python < 3.12 上整体不可用，所以版本不对时必须重建。
cmd_gscore_rebuild() {
  local gpy
  if [ -x "$GSCORE_VENV/bin/python" ]; then
    gpy="$("$GSCORE_VENV/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    info "当前 GsCore 虚拟环境：Python $gpy"
  fi
  warn "即将删除 ${GSCORE_VENV}，用 Python ${GSCORE_PYTHON_VERSION:-3.13} 重建（依赖会重新下载）"
  ask_yes "  继续？[y/N] " N || { info "已取消"; return 0; }

  rm -rf "$GSCORE_VENV"
  bash "$BASE_DIR/install.sh" --skip-napcat --skip-nonebot
  log "重建完成，重启： ./botctl.sh restart gscore"
  info "然后跑 ./botctl.sh gscore-check 确认接口不再是 404"
}

# 手动给 GsCore 装插件（GsCore 自己的 Git 下载在国内经常失败，这里走加速前缀重试）
cmd_gscore_plugin() {
  local url="${1:-}" pdir name dest p
  [ -n "$url" ] || die "用法： ./botctl.sh gscore-plugin <git 仓库地址>
  例： ./botctl.sh gscore-plugin https://github.com/tyql688/NTEUID.git"

  pdir="$GSCORE_DIR/gsuid_core/plugins"
  [ -d "$GSCORE_DIR/gsuid_core" ] || pdir="$GSCORE_DIR/plugins"
  name="$(basename "$url" .git)"
  dest="$pdir/$name"
  mkdir -p "$pdir"

  if [ -d "$dest" ]; then
    warn "目标已存在：$dest"
    info "要重装先移走： mv $dest ${dest}.bak"
    return 0
  fi

  log "把插件克隆到 $dest"
  for p in $GH_PROXY_LIST; do
    [ -n "$p" ] || continue
    info "尝试加速：$p"
    if timeout 300 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
         clone --depth=1 --single-branch "$p/$url" "$dest" 2>/dev/null; then
      log "完成：$dest"
      info "重启 GsCore 生效： ./botctl.sh restart gscore"
      return 0
    fi
    rm -rf "$dest"
  done

  info "加速都失败，试直连"
  if timeout 300 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
       clone --depth=1 --single-branch "$url" "$dest"; then
    log "完成：$dest"
    info "重启 GsCore 生效： ./botctl.sh restart gscore"
    return 0
  fi
  rm -rf "$dest"
  die "克隆失败。建议在 config.conf 里设置 HTTP_PROXY_URL 后重试"
}

# =============================================================================
#  公网暴露（Cloudflare Tunnel）
#  用途：群里其他人要能打开 NTEUID 的登录页，就必须有一个真正的公网地址。
#  Tailscale/ZeroTier 这类私有网络不适用（群友不可能都装客户端）。
# =============================================================================
cf_unit_name="cloudflared"

cf_bin() { command -v cloudflared 2>/dev/null; }

cmd_expose_install() {
  if cf_bin >/dev/null; then
    info "cloudflared 已安装：$(cloudflared --version 2>&1 | head -1)"
    return 0
  fi
  [ "$(id -u)" = "0" ] || die "安装 cloudflared 需要 root 权限"

  local arch bin
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  bin="cloudflared-linux-amd64" ;;
    aarch64|arm64) bin="cloudflared-linux-arm64" ;;
    *) die "没适配的架构：$arch" ;;
  esac

  # ---------- 1) Cloudflare 官方 apt 源（走 CF 自己的 CDN，不经过 GitHub）----------
  if command -v apt-get >/dev/null 2>&1; then
    log "尝试 1/3：Cloudflare 官方 apt 源"
    mkdir -p -m 0755 /usr/share/keyrings
    if curl -fsSL --connect-timeout 20 --max-time 120 \
         -o /usr/share/keyrings/cloudflare-main.gpg \
         https://pkg.cloudflare.com/cloudflare-main.gpg; then
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
        > /etc/apt/sources.list.d/cloudflared.list
      export DEBIAN_FRONTEND=noninteractive
      if apt-get update -qq >/dev/null 2>&1 && apt-get install -y cloudflared >/dev/null 2>&1; then
        log "已通过官方 apt 源安装：$(cloudflared --version 2>&1 | head -1)"
        return 0
      fi
      warn "官方源装不上，去掉它避免影响后续 apt"
      rm -f /etc/apt/sources.list.d/cloudflared.list
    else
      warn "官方 key 下载失败，改用加速前缀"
    fi
  fi

  # ---------- 2) GitHub 加速前缀 ----------
  log "尝试 2/3：GitHub 加速前缀下载二进制"
  local p
  for p in $GH_PROXY_LIST; do
    [ -n "$p" ] || continue
    info "试 $p"
    if curl -fL --connect-timeout 10 --max-time 300 --progress-bar \
         -o /usr/local/bin/cloudflared \
         "$p/https://github.com/cloudflare/cloudflared/releases/latest/download/$bin"; then
      chmod +x /usr/local/bin/cloudflared
      if cloudflared --version >/dev/null 2>&1; then
        log "已安装：$(cloudflared --version 2>&1 | head -1)"
        return 0
      fi
      warn "下载到的文件跑不起来，换下一个"
      rm -f /usr/local/bin/cloudflared
    fi
  done

  # ---------- 3) 直连 ----------
  log "尝试 3/3：GitHub 直连"
  if curl -fL --connect-timeout 15 --max-time 300 --progress-bar \
       -o /usr/local/bin/cloudflared \
       "https://github.com/cloudflare/cloudflared/releases/latest/download/$bin"; then
    chmod +x /usr/local/bin/cloudflared
    if cloudflared --version >/dev/null 2>&1; then
      log "已安装：$(cloudflared --version 2>&1 | head -1)"
      return 0
    fi
  fi
  rm -f /usr/local/bin/cloudflared

  err "全部失败。手动方案（最保底）："
  err "  1) 在电脑上打开下面链接下载 $bin"
  err "     https://github.com/cloudflare/cloudflared/releases/latest/download/$bin"
  err "  2) 用 WinSCP / SMB 传到 /usr/local/bin/cloudflared"
  err "  3) chmod +x /usr/local/bin/cloudflared"
  return 1
}

cmd_expose_start() {
  local port="${1:-$GSCORE_PORT}" cf logf pidf url="" i
  cf="$(cf_bin)" || die "没装 cloudflared，先执行： ./botctl.sh expose install"
  ensure_dirs
  logf="$LOG_DIR/cloudflared.log"
  pidf="$(pid_file cloudflared)"

  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
    warn "隧道已在运行（PID $(cat "$pidf")）"
    cmd_expose_url
    return 0
  fi

  log "启动临时隧道 -> http://127.0.0.1:$port"
  : > "$logf"
  nohup "$cf" tunnel --url "http://127.0.0.1:$port" --no-autoupdate >>"$logf" 2>&1 &
  echo $! > "$pidf"

  info "等待隧道建立（最多 30 秒）…"
  for i in $(seq 1 30); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$logf" 2>/dev/null | head -1)"
    [ -n "$url" ] && break
    sleep 1
  done

  if [ -z "$url" ]; then
    err "30 秒内没拿到公网地址，看日志： ./botctl.sh expose log"
    return 1
  fi

  printf '\n  %s公网地址：%s%s\n\n' "$GRN" "$url" "$RST"
  printf '  把这行填到  GsCore 控制台 → 插件 → NTEUID → 异环登录页面 URL：\n'
  printf '      %s\n\n' "$url"
  warn "免费临时隧道的地址每次重启都会变，只适合临时验证"
  info "停止： ./botctl.sh expose stop      日志： ./botctl.sh expose log"
  info "长期用请看 README 的「命名隧道」做法（需要一个自己的域名）"
}

cmd_expose_url() {
  local url
  url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -1)"
  if [ -n "$url" ]; then
    printf '  %s公网地址：%s%s\n' "$GRN" "$url" "$RST"
    printf '  别忘了同步更新 GsCore 里 NTEUID 的「异环登录页面 URL」\n'
  else
    warn "日志里还没有公网地址，先执行： ./botctl.sh expose start"
  fi
}

cmd_expose_stop() {
  local pidf; pidf="$(pid_file cloudflared)"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$pidf")" 2>/dev/null
    sleep 1
    kill -9 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null || true
    log "隧道已停止"
  else
    info "隧道没在运行"
  fi
  rm -f "$pidf"
}

cmd_expose_status() {
  local pidf; pidf="$(pid_file cloudflared)"
  printf '\n  %s公网隧道（cloudflared）%s\n\n' "$BLD" "$RST"
  if ! cf_bin >/dev/null; then
    printf '      %s未安装 → ./botctl.sh expose install%s\n\n' "$YEL" "$RST"
    return 0
  fi
  printf '      cloudflared：%s\n' "$(cloudflared --version 2>&1 | head -1)"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then
    printf '      状态：%s运行中%s（PID %s）\n' "$GRN" "$RST" "$(cat "$pidf")"
    cmd_expose_url
  else
    printf '      状态：%s未运行%s\n' "$YEL" "$RST"
  fi
  echo
}

# 命名隧道：地址固定成 https://<你的域名>，重启不变，适合长期（放群里）使用。
# 前提：域名已经托管在 Cloudflare。
cmd_expose_named() {
  local host="${1:-}" port="${2:-$GSCORE_PORT}" tname="botapp"
  host="${host#https://}"; host="${host#http://}"; host="${host%/}"

  [ -n "$host" ] || die "用法： ./botctl.sh expose named <完整域名> [本地端口]
  例： ./botctl.sh expose named nte.487510.xyz
  （域名必须先托管在 Cloudflare，且当前是 root）"

  local cf; cf="$(cf_bin)" || die "先安装： ./botctl.sh expose install"
  [ "$(id -u)" = "0" ] || die "命名隧道需要 root 权限"

  # ---------- 1) 浏览器授权 ----------
  if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    cat <<EOF

  接下来要授权。cloudflared 会打印一个 https://dash.cloudflare.com/... 的网址，
  用电脑或手机浏览器打开它，登录 Cloudflare，选中「$host 所属的那个域名」，点授权。
  授权成功后证书会回传到本机，这个命令会自动继续 —— 中途别按 Ctrl+C。

EOF
    ask_yes "  准备好了？[Y/n] " Y || return 0
    cloudflared tunnel login || die "授权失败（没拿到 cert.pem）"
  fi
  [ -f "$HOME/.cloudflared/cert.pem" ] || die "没找到 $HOME/.cloudflared/cert.pem"

  # ---------- 2) 创建隧道 ----------
  local uuid
  uuid="$(cloudflared tunnel list 2>/dev/null | awk -v n="$tname" '$2==n {print $1; exit}')"
  if [ -z "$uuid" ]; then
    log "创建隧道：$tname"
    cloudflared tunnel create "$tname" || die "创建隧道失败"
    uuid="$(cloudflared tunnel list 2>/dev/null | awk -v n="$tname" '$2==n {print $1; exit}')"
  else
    info "隧道已存在：$tname（$uuid）"
  fi
  [ -n "$uuid" ] || die "拿不到隧道 ID，手动看： cloudflared tunnel list"

  # ---------- 3) 绑定域名 ----------
  log "把 $host 指向隧道 $tname"
  cloudflared tunnel route dns "$tname" "$host" || warn "DNS 路由没成功（可能已存在同名记录，去 CF 面板确认）"

  # ---------- 4) 写系统级配置 ----------
  mkdir -p /etc/cloudflared
  [ -f /etc/cloudflared/config.yml ] && cp -a /etc/cloudflared/config.yml "/etc/cloudflared/config.yml.bak.$(date +%Y%m%d%H%M%S)"
  cat > /etc/cloudflared/config.yml <<EOF
# 由 botctl 生成
tunnel: $uuid
credentials-file: $HOME/.cloudflared/$uuid.json

ingress:
  # 想要"只暴露登录页、不暴露控制台"，把下面这行的端口改成 nginx 的端口，
  # 并在 nginx 里按路径做白名单（见 README「公网访问」一节）
  - hostname: $host
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF
  log "已写配置：/etc/cloudflared/config.yml（指向 127.0.0.1:$port）"

  # ---------- 5) 注册成系统服务 ----------
  cmd_expose_stop >/dev/null 2>&1 || true   # 先停掉临时隧道，避免抢
  if cloudflared service install >/dev/null 2>&1; then
    systemctl enable --now cloudflared >/dev/null 2>&1 || systemctl restart cloudflared
    log "cloudflared 已注册为系统服务并启动（开机自启）"
  else
    warn "service install 失败，请手动： cloudflared service install && systemctl enable --now cloudflared"
  fi

  cat <<EOF

  ── 固定公网地址 ──────────────────────────────────
      https://$host

  下一步：
    1) 把这个地址填到  GsCore 控制台 → 插件 → NTEUID → 异环登录页面 URL
    2) ./botctl.sh restart gscore
    3) 手机切 4G 打开 https://$host/app 验证一下能不能通
    4) 看服务状态： systemctl status cloudflared

  ⚠️ 这样会把整个 GsCore 控制台（/app）也暴露到这个域名上。
     发到群里之前建议先做 nginx 路径白名单（见 README）。

EOF
}

cmd_expose() {
  case "${1:-status}" in
    install) cmd_expose_install ;;
    named)   cmd_expose_named "${2:-}" "${3:-}" ;;
    start)   cmd_expose_start "${2:-}" ;;
    stop)    cmd_expose_stop ;;
    url)     cmd_expose_url ;;
    log|logs) [ -f "$LOG_DIR/cloudflared.log" ] && tail -n "${2:-50}" "$LOG_DIR/cloudflared.log" || warn "还没有日志" ;;
    status|*) cmd_expose_status ;;
  esac
}

cmd_gscore_check() {
  local base="http://127.0.0.1:$GSCORE_PORT" logf="$LOG_DIR/gscore.log" p code
  printf '\n  %sGsCore 控制台诊断%s\n\n' "$BLD" "$RST"

  printf '  %s[0] GsCore 的 Python 版本与发行包%s\n' "$BLD" "$RST"
  if [ -x "$GSCORE_VENV/bin/python" ]; then
    local gpy
    gpy="$("$GSCORE_VENV/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    case "$gpy" in
      3.12|3.13|3.14) printf '      Python %s%s%s（满足 >= 3.12）\n' "$GRN" "$gpy" "$RST" ;;
      *)
        printf '      Python %s%s%s  %s← 低于 3.12，控制台必然全部接口 404%s\n' "$RED" "$gpy" "$RST" "$RED" "$RST"
        printf '      %s原因：logs_api.py 用 typing.TypedDict 做 FastAPI response_model，\n' "$CYA" "$RST"
        printf '      pydantic 在 Python < 3.12 上无法生成 schema（PydanticUserError）。%s\n' "$CYA"
        printf '      %s修复： ./botctl.sh gscore-rebuild%s\n' "$BLD" "$RST"
        ;;
    esac
    local pkgver
    pkgver="$("$GSCORE_VENV/bin/python" -c "import importlib.metadata as m;print(m.version('gsuid-core'))" 2>&1)"
    case "$pkgver" in
      *Error*|*error*|*Traceback*)
        printf '      %s未安装为发行包 → importlib.metadata 取不到 gsuid-core 版本%s\n' "$RED" "$RST"
        printf '      %s「加载版本信息失败」这类报错很可能就是它引起的。修复：%s\n' "$CYA" "$RST"
        printf '        cd %s\n' "$GSCORE_DIR"
        printf '        UV_PROJECT_ENVIRONMENT=%s %s/env/uv-venv/bin/uv sync --no-dev\n' "$GSCORE_VENV" "$BASE_DIR"
        printf '      然后： ./botctl.sh restart gscore\n'
        ;;
      *)
        printf '      已安装：gsuid-core %s\n' "$pkgver"
        ;;
    esac
  else
    printf '      %sGsCore 虚拟环境不存在：%s%s\n' "$RED" "$GSCORE_VENV" "$RST"
  fi

  printf '\n  %s[1] 监听与端口%s\n' "$BLD" "$RST"
  if port_listening "$GSCORE_PORT"; then
    printf '      %s[OK]%s 端口 %s 可连接\n' "$GRN" "$RST" "$GSCORE_PORT"
    if command -v ss >/dev/null 2>&1; then
      ss -ltnp 2>/dev/null | grep -E "[:.]$GSCORE_PORT[[:space:]]" | sed 's/^/      /'
    fi
  else
    printf '      %s[FAIL]%s 端口 %s 连不上 → ./botctl.sh log gscore 50\n' "$RED" "$RST" "$GSCORE_PORT"
  fi

  printf '\n  %s[2] 本机直接探接口（绕过浏览器，看真实状态码）%s\n' "$BLD" "$RST"
  local api_code=""
  for p in "/app" "/app/" "/api/version" "/api/version/bots"; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$base$p" 2>/dev/null)"
    case "$p" in /api/version) api_code="$code" ;; esac
    case "$code" in
      200) printf '      %-22s -> %s%s%s\n' "$p" "$GRN" "$code" "$RST" ;;
      401) printf '      %-22s -> %s%s%s  %s(路由存在，只是未登录 — 正常)%s\n' "$p" "$GRN" "$code" "$RST" "$CYA" "$RST" ;;
      000) printf '      %-22s -> %s无响应%s\n' "$p" "$RED" "$RST" ;;
      *)   printf '      %-22s -> %s%s%s\n' "$p" "$YEL" "$code" "$RST" ;;
    esac
  done

  printf '\n      %s判读：%s\n' "$CYA" "$RST"
  case "$api_code" in
    200|401) printf '      %s[OK]%s   /api/version 返回 %s → API 路由已注册（401 只是未登录）\n' "$GRN" "$RST" "$api_code" ;;
    404)     printf '      %s[FAIL]%s /api/version 返回 404 → API 路由没注册，看 [5] 逐模块导入和 [7] 日志\n' "$RED" "$RST" ;;
    000)     printf '      %s[FAIL]%s /api/version 无响应 → 服务没起来，看 [1]\n' "$RED" "$RST" ;;
    *)       printf '      %s[?]%s    /api/version 返回 %s\n' "$YEL" "$RST" "$api_code" ;;
  esac

  printf '\n  %s[3] GsCore 侧已连接的 Bot 实例%s\n' "$BLD" "$RST"
  local bots
  bots="$(curl -s -m 5 "http://127.0.0.1:$GSCORE_PORT/api/version/bots" 2>/dev/null)"
  if [ -n "$bots" ]; then
    printf '%s\n' "$bots" | head -c 700 | sed 's/^/      /'
    echo
    printf '      %s上面没有 NoneBot2/onebot 条目 → 第三段链路没通，看下面的 [4]%s\n' "$CYA" "$RST"
  else
    printf '      %s/api/version/bots 无响应或需要登录鉴权%s\n' "$YEL" "$RST"
  fi

  printf '\n  %s[4] NoneBot2 -> GsCore 这一段%s\n' "$BLD" "$RST"
  if [ "$(svc_state nonebot)" = "active" ]; then
    printf '      %s[OK]%s   NoneBot2 运行中\n' "$GRN" "$RST"
  else
    printf '      %s[FAIL]%s NoneBot2 没在运行 → ./botctl.sh start nonebot 然后看 ./botctl.sh log nonebot\n' "$RED" "$RST"
  fi
  local bmod=""
  if bmod="$(bridge_module)"; then
    printf '      %s[OK]%s   桥接插件已安装，模块名：%s\n' "$GRN" "$RST" "$bmod"
  else
    printf '      %s[FAIL]%s 没有安装 GsCore 桥接插件 → ./botctl.sh plugin-install\n' "$RED" "$RST"
    printf '        %s注：发行包名 nonebot-plugin-genshinuid 的模块名是 GenshinUID，\n' "$CYA" "$RST"
    printf '        不能用 import nonebot_plugin_genshinuid 判断。%s\n' "$CYA" "$RST"
  fi

  # 是否真的加载成功，看日志才准 —— 裸 import 会因为 NoneBot 未初始化而失败，是误报
  if [ -f "$LOG_DIR/nonebot.log" ]; then
    local loaded
    loaded="$(grep -oE '已加载 GsCore 连接插件：.*' "$LOG_DIR/nonebot.log" 2>/dev/null | tail -1)"
    if [ -n "$loaded" ]; then
      printf '      %s[OK]%s   NoneBot2 日志：%s\n' "$GRN" "$RST" "$loaded"
    elif grep -q '没有加载到任何 GsCore 连接插件' "$LOG_DIR/nonebot.log" 2>/dev/null; then
      printf '      %s[FAIL]%s NoneBot2 报告「没有加载到任何 GsCore 连接插件」\n' "$RED" "$RST"
      printf '        → ./botctl.sh plugin-install 然后 ./botctl.sh restart nonebot\n'
    else
      printf '      %s[..]%s   日志里没找到插件加载记录（NoneBot2 刚重启过？）\n' "$CYA" "$RST"
    fi
  fi

  # 最权威的信号：GsCore 那边有没有收到 ws 连接
  if [ -f "$LOG_DIR/gscore.log" ]; then
    local wsline
    wsline="$(grep -oE '"WebSocket /ws/[^"?]+' "$LOG_DIR/gscore.log" 2>/dev/null | grep -v livechat | tail -1)"
    if [ -n "$wsline" ]; then
      printf '      %s[OK]%s   GsCore 已接受连接：%s\n' "$GRN" "$RST" "$wsline"
    else
      printf '      %s[FAIL]%s GsCore 日志里没有收到 /ws/<botid> 连接\n' "$RED" "$RST"
    fi
  fi

  printf '      .env 中的连接配置：\n'
  grep -E '^(gsuid_core|GSUID_CORE)' "$NONEBOT_DIR/.env" 2>/dev/null | sed 's/^/        /' \
    || printf '        %s没找到 gsuid_core_* 配置%s\n' "$YEL" "$RST"

  printf '\n  %s[5] 逐模块导入 webconsole（定位是哪个 API 模块炸的）%s\n' "$BLD" "$RST"
  if [ -x "$GSCORE_VENV/bin/python" ] && [ -d "$GSCORE_DIR/gsuid_core" ]; then
    local m firstfail="" detail=""
    for m in version_api system_api dashboard_api plugins_api auth_api logs_api history_api; do
      if ( cd "$GSCORE_DIR" && "$GSCORE_VENV/bin/python" -c "import gsuid_core.webconsole.$m" ) >/dev/null 2>&1; then
        printf '      %s[OK]%s   %s\n' "$GRN" "$RST" "$m"
      else
        printf '      %s[FAIL]%s %s\n' "$RED" "$RST" "$m"
        [ -z "$firstfail" ] && firstfail="$m"
      fi
    done
    if [ -n "$firstfail" ]; then
      printf '\n      %s首个失败模块 %s 的完整异常（这个才是根因）：%s\n' "$BLD" "$firstfail" "$RST"
      detail="$( cd "$GSCORE_DIR" && "$GSCORE_VENV/bin/python" -c "import gsuid_core.webconsole.$firstfail" 2>&1 )"
      printf '%s\n' "$detail" | tail -25 | sed 's/^/      /'
      printf '\n      说明：只要有一个模块 import 失败，setup_frontend 里那句\n'
      printf '      `from gsuid_core.webconsole import (...)` 整体就会失败，\n'
      printf '      结果是【所有 /api/* 路由都没注册】→ 页面能开但全部接口 404。\n'
    else
      printf '      全部导入成功\n'
    fi
  else
    printf '      %s跳过（venv 或源码目录不存在）%s\n' "$YEL" "$RST"
  fi

  printf '\n  %s[6] 前端 dist 与版本文件%s\n' "$BLD" "$RST"
  local hits
  hits="$(find "$GSCORE_DIR" -maxdepth 6 -name version.json 2>/dev/null | head -10)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    printf '      %s没找到 version.json → 前端可能没准备好%s\n' "$YEL" "$RST"
  fi
  hits="$(find "$GSCORE_DIR" -maxdepth 6 -type d -name dist 2>/dev/null | head -5)"
  [ -n "$hits" ] && printf '%s\n' "$hits" | sed 's/^/      /'

  printf '\n  %s[7] 日志里的 webconsole 关键行%s\n' "$BLD" "$RST"
  if [ -f "$logf" ]; then
    grep -inE 'webconsole|dist_path|api_import|version\.json|Traceback|Error|Exception' "$logf" 2>/dev/null | tail -30 | sed 's/^/      /'
  else
    printf '      %s日志不存在：%s%s\n' "$YEL" "$logf" "$RST"
  fi

  printf '\n  %s[8] 最近 40 行原始日志%s\n' "$BLD" "$RST"
  [ -f "$logf" ] && tail -40 "$logf" | sed 's/^/      /'
  echo
}

# 打印（或设置）GsCore 网页控制台的注册码 REGISTER_CODE
cmd_gscore_code() {
  local cfg new="${1:-}"
  cfg="$(find_gscore_config)" || die "找不到 GsCore 配置，请先启动一次 GsCore： ./botctl.sh start gscore"

  # 带参数 = 改注册码
  if [ -n "$new" ]; then
    cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
    python3 - "$cfg" "$new" <<'PY' || die "写入 GsCore 配置失败"
import json, sys
path, code = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f) or {}
print("  旧注册码:", data.get("REGISTER_CODE"))
data["REGISTER_CODE"] = code
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=4)
print("  新注册码:", code)
PY
    log "注册码已更新，重启生效： ./botctl.sh restart gscore"
    return 0
  fi

  local code host
  code="$(python3 -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')) or {}).get('REGISTER_CODE',''))" "$cfg" 2>/dev/null)"
  host="$(python3 -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')) or {}).get('HOST',''))" "$cfg" 2>/dev/null)"

  printf '\n  %sGsCore 控制台%s\n\n' "$BLD" "$RST"
  printf '    控制台地址 : http://%s:%s/app\n' "$(lan_ip)" "$GSCORE_PORT"
  printf '    注册码     : %s%s%s\n' "$GRN" "${code:-（读不到，见下面的配置文件）}" "$RST"
  printf '    配置文件   : %s\n\n' "$cfg"
  printf '    用法：浏览器打开控制台 → 首次使用点「注册」→ 把注册码填进去。\n'
  printf '    换一个   ： botctl gscore-code 你的新注册码\n\n'

  case "$host" in
    0.0.0.0|all|none|dual|"") : ;;
    *) warn "当前 HOST=$host，只绑本机，局域网打不开控制台 → 先执行 ./botctl.sh gscore-host" ;;
  esac
}

# 同时设置 GsCore 的 WS_TOKEN 与 NoneBot2 .env 里的 gsuid_core_ws_token，
# 保证两端永远一致（这也正是最初 docker 环境下最容易踩的坑）。
cmd_gscore_token() {
  local cfg token="${1:-}"
  cfg="$(find_gscore_config)" || die "找不到 GsCore 配置，请先启动一次 GsCore： ./botctl.sh start gscore"
  [ -n "$token" ] || token="${GSUID_CORE_WS_TOKEN:-}"
  [ -n "$token" ] || die "用法： ./botctl.sh gscore-token <令牌>   （或在 config.conf 里设 GSUID_CORE_WS_TOKEN）"

  cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$cfg" "$token" <<'PY' || die "写入 GsCore 配置失败"
import json, sys
path, token = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f) or {}
data["WS_TOKEN"] = token
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=4)
print("  GsCore  WS_TOKEN =", token)
PY

  local envfile="$NONEBOT_DIR/.env"
  if [ -f "$envfile" ]; then
    cp -a "$envfile" "$envfile.bak.$(date +%Y%m%d%H%M%S)"
    python3 - "$envfile" "$token" <<'PY' || warn "更新 .env 失败，请手动改 gsuid_core_ws_token"
import io, sys
path, token = sys.argv[1], sys.argv[2]
keys = ("gsuid_core_ws_token", "GSUID_CORE_WS_TOKEN")
lines = io.open(path, encoding="utf-8").read().splitlines()
out, seen = [], set()
for ln in lines:
    k = ln.split("=", 1)[0].strip() if "=" in ln else None
    if k in keys:
        out.append("%s=%s" % (k, token))
        seen.add(k)
    else:
        out.append(ln)
for k in keys:
    if k not in seen:
        out.append("%s=%s" % (k, token))
io.open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("  NoneBot2 .env 已同步：", ", ".join(keys))
PY
  else
    warn "没找到 $envfile，只改了 GsCore 一侧"
  fi

  log "两端 WS_TOKEN 已对齐"
  info "重启两个服务生效： ./botctl.sh restart gscore   然后   ./botctl.sh restart nonebot"
}

cmd_gscore_config() {
  local cfg
  if cfg="$(find_gscore_config)"; then
    log "GsCore 配置文件：$cfg"
  else
    warn "还没生成配置文件（GsCore 首次启动后才会创建）"
    info "预期位置：$GSCORE_DIR/data/config.json"
    info "先执行： ./botctl.sh start gscore  然后重试"
    return 0
  fi
  echo
  python3 - "$cfg" <<'PY' 2>/dev/null || grep -nE '"(HOST|PORT|WS_TOKEN|TRUSTED_IPS|ENABLE_HTTP)"' "$cfg"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")) or {}
keys = ["HOST", "PORT", "ENABLE_HTTP", "WS_TOKEN", "TRUSTED_IPS", "REGISTER_CODE", "web_max_sessions"]
for k in keys:
    if k in d:
        print("  %-18s = %r" % (k, d[k]))
print()
print("  说明：HOST=localhost 只能在 NAS 本机访问控制台；改成 0.0.0.0 才能局域网访问。")
print("        ENABLE_HTTP 只控制 POST /api/send_msg，与网页控制台无关。")
print("  注册码单独打印： ./botctl.sh gscore-code")
PY
}

cmd_gscore_host() {
  local cfg host="${1:-${GSCORE_HOST:-0.0.0.0}}"
  cfg="$(find_gscore_config)" || die "找不到 GsCore 配置，请先启动一次 GsCore： ./botctl.sh start gscore"
  info "配置文件：$cfg"
  cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"

  python3 - "$cfg" "$host" "$GSCORE_PORT" <<'PY' || die "修改失败"
import json, sys
path, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    data = json.load(f) or {}

before = {k: data.get(k) for k in ("HOST", "PORT", "host", "port")}

# GsCore 的真实字段是【大写】HOST / PORT，且 PORT 是字符串。
data["HOST"] = host
data["PORT"] = str(port)
# 早期版本误加的小写 host/port 是无效字段，顺手清掉，避免误导
data.pop("host", None)
data.pop("port", None)

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=4)

print("修改前 :", before)
print("修改后 : HOST=%r PORT=%r" % (data["HOST"], data["PORT"]))
PY

  log "已把 GsCore 的 HOST 改为 $host（PORT=$GSCORE_PORT）"
  info "ENABLE_HTTP 与网页控制台无关（它只管 POST /api/send_msg），没有改动"
  info "重启生效： ./botctl.sh restart gscore"
  info "控制台地址： http://$(lan_ip):$GSCORE_PORT/app"
}

# =============================================================================
#  命令：自检
# =============================================================================
cmd_doctor() {
  local fail=0
  ok()   { printf '  %s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
  bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; fail=$((fail+1)); }
  note() { printf '  %s[ .. ]%s %s\n' "$CYA" "$RST" "$*"; }

  printf '\n%sbot-app 自检%s\n\n' "$BLD" "$RST"

  note "--- 目录与虚拟环境 ---"
  [ -d "$GSCORE_DIR" ]  && ok "GsCore 源码：$GSCORE_DIR"  || bad "缺少 GsCore 源码目录"
  [ -d "$NONEBOT_DIR" ] && ok "NoneBot2 项目：$NONEBOT_DIR" || bad "缺少 NoneBot2 项目目录"
  [ -x "$GSCORE_VENV/bin/python" ]  && ok "GsCore venv 正常"  || bad "GsCore venv 缺失，执行 ./botctl.sh install"
  [ -x "$NONEBOT_VENV/bin/python" ] && ok "NoneBot2 venv 正常" || bad "NoneBot2 venv 缺失，执行 ./botctl.sh install"
  [ -f "$NONEBOT_DIR/.env" ] && ok "NoneBot2 .env 存在" || bad "缺少 $NONEBOT_DIR/.env"

  note "--- Python 依赖 ---"
  if [ -x "$NONEBOT_VENV/bin/python" ]; then
    "$NONEBOT_VENV/bin/python" -c "import nonebot, nonebot.adapters.onebot.v11" 2>/dev/null \
      && ok "nonebot2 + OneBot V11 适配器可用" || bad "nonebot2/适配器 导入失败"
    local bmod
    if bmod="$(bridge_module)"; then
      ok "GsCore 桥接插件已安装（模块名：$bmod）"
      ( cd "$NONEBOT_DIR" && "$NONEBOT_VENV/bin/python" -c "import $bmod" ) 2>/dev/null \
        && ok "桥接插件可导入" \
        || bad "桥接插件装上了但导入失败 → ./botctl.sh log nonebot 100"
    else
      bad "没有安装 GsCore 桥接插件 → ./botctl.sh plugin-install"
    fi
  fi
  if [ -x "$GSCORE_VENV/bin/python" ]; then
    local gpy
    gpy="$("$GSCORE_VENV/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    case "$gpy" in
      3.12|3.13|3.14) ok "GsCore venv Python $gpy（满足 >= 3.12）" ;;
      *) bad "GsCore venv 是 Python $gpy —— 必须 >= 3.12，否则控制台所有接口 404 → ./botctl.sh gscore-rebuild" ;;
    esac
    ( cd "$GSCORE_DIR" && "$GSCORE_VENV/bin/python" -c "import gsuid_core" 2>/dev/null ) \
      && ok "GsCore 可导入" || bad "GsCore 导入失败，试试 ./botctl.sh update"
  fi

  note "--- 服务与端口 ---"
  local s st
  for s in $ALL_SERVICES; do
    st="$(svc_state "$s")"
    if [ "$st" = "active" ]; then ok "$s 运行中"; else bad "$s 未运行（./botctl.sh start $s）"; fi
    if port_listening "$(svc_port "$s")"; then ok "$s 端口 $(svc_port "$s") 已监听"; else bad "$s 端口 $(svc_port "$s") 未监听"; fi
  done
  tcp_probe "$GSCORE_PORT" && ok "NoneBot2 -> GsCore 端口连通" || bad "连不上 GsCore 的 $GSCORE_PORT"
  tcp_probe "$NONEBOT_PORT" && ok "NapCat -> NoneBot2 端口连通" || bad "连不上 NoneBot2 的 $NONEBOT_PORT"

  note "--- NapCat ---"
  local nb_token home cfg nap_token found hits units
  nb_token="$(grep -E '^ONEBOT_ACCESS_TOKEN=' "$NONEBOT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
  if home="$(napcat_home)"; then
    ok "NapCat 目录：$home"

    local cdir
    if cdir="$(napcat_config_dir)"; then
      ok "配置目录：$cdir"
      if [ -f "$cdir/webui.json" ]; then
        ok "webui.json 已生成（token 用 ./botctl.sh napcat-token 查看）"
      else
        bad "webui.json 未生成 → NapCat 还没成功启动过，看 ./botctl.sh log napcat"
      fi
    else
      bad "目录结构不对：应存在 <目录>/opt/QQ/qq，建议重装： bash install.sh --only-napcat --force"
    fi

    found=0
    for cfg in "$home"/config/onebot11_*.json; do
      [ -f "$cfg" ] || continue
      found=1
      nap_token="$(python3 -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));c=d.get('network',{}).get('websocketClients',[]);print(c[0].get('token','') if c else '')" "$cfg" 2>/dev/null)"
      if [ "$nap_token" = "${nb_token:-}" ]; then
        ok "$(basename "$cfg") 的反向 WS token 与 .env 一致"
      else
        bad "$(basename "$cfg") 反向 WS token 不一致 → 执行 ./botctl.sh napcat-ws <QQ号> 自动对齐"
      fi
    done
    [ "$found" = "0" ] && note "还没生成 onebot11_*.json（NapCat 尚未登录过），扫码登录后执行 napcat-ws 即可"
  else
    bad "没找到 NapCat 目录 → 很可能还没安装，执行： bash install.sh --only-napcat"
    hits="$(find /root /opt /usr/local /vol1 /vol2 -maxdepth 5 -name webui.json 2>/dev/null | head -3)"
    if [ -n "$hits" ]; then
      note "不过在下列位置发现了 webui.json，说明装在别处，把它填进 config.conf 的 NAPCAT_DIR："
      printf '%s\n' "$hits" | sed 's/^/         /'
    fi
  fi

  if systemd_ok; then
    units="$(systemctl list-unit-files 2>/dev/null | awk '/napcat/ {print $1}' | grep -v '^bot-napcat' | head -5)"
    if [ -n "$units" ]; then
      warn "发现官方安装器自带的 unit：$(printf '%s' "$units" | tr '\n' ' ')"
      warn "它和 bot-napcat.service 会抢同一个 QQ 登录，建议先停掉： systemctl disable --now <它>"
    fi
  fi

  note "--- GsCore 配置 ---"
  if cfg="$(find_gscore_config)"; then
    ok "配置文件：$cfg"
    local gs_host gs_port
    gs_host="$(python3 -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')) or {}).get('HOST',''))" "$cfg" 2>/dev/null)"
    gs_port="$(python3 -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')) or {}).get('PORT',''))" "$cfg" 2>/dev/null)"
    info "HOST=$gs_host   PORT=$gs_port"
    case "$gs_host" in
      0.0.0.0|all|none|dual|"") ok "监听地址对外可达，局域网能开控制台" ;;
      *) bad "HOST=$gs_host 只绑本机，局域网打不开控制台 → 执行 ./botctl.sh gscore-host" ;;
    esac
    if [ -n "$gs_port" ] && [ "$gs_port" != "$GSCORE_PORT" ]; then
      warn "配置里 PORT=$gs_port 与 config.conf 的 GSCORE_PORT=$GSCORE_PORT 不一致（启动参数会以 config.conf 为准）"
    fi
    grep -qE '"ENABLE_HTTP"\s*:\s*true' "$cfg" 2>/dev/null \
      && note "ENABLE_HTTP=true（只影响 POST /api/send_msg，与网页控制台无关）"
  else
    note "GsCore 还没生成 config.json（首次启动后创建）"
  fi

  note "--- 开机自启 ---"
  if systemd_ok; then
    for s in $ALL_SERVICES; do
      if [ -f "$(unit_path "$s")" ] && systemctl is-enabled "bot-$s.service" >/dev/null 2>&1; then
        ok "$s 已启用开机自启"
      else
        note "$s 未启用（./botctl.sh enable $s）"
      fi
    done
  else
    note "本机没有 systemd"
  fi

  echo
  if [ "$fail" -eq 0 ]; then
    printf '  %s全部检查通过%s\n\n' "$GRN" "$RST"
  else
    printf '  %s有 %s 项异常%s，按上面的提示逐个处理即可\n\n' "$RED" "$fail" "$RST"
  fi
}

# =============================================================================
#  命令：更新 / 卸载 / 安装
# =============================================================================
cmd_update() {
  log "更新 GsCore 源码"
  if [ -d "$GSCORE_DIR/.git" ]; then
    timeout "${GIT_TIMEOUT:-300}" git -C "$GSCORE_DIR" \
      -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
      pull --ff-only --progress \
      || warn "GsCore 更新失败/超时，继续用现有代码"
  else
    warn "GsCore 不是 git 仓库（可能是手动解压的），跳过更新"
  fi

  if [ -x "$GSCORE_VENV/bin/python" ] && [ -f "$GSCORE_DIR/requirements.txt" ]; then
    log "更新 GsCore 依赖"
    "$GSCORE_VENV/bin/python" -m pip install -r "$GSCORE_DIR/requirements.txt" \
      --index-url "$PYPI_INDEX" --trusted-host "$(printf '%s' "$PYPI_INDEX" | awk -F/ '{print $3}')" \
      --disable-pip-version-check || warn "GsCore 依赖更新失败"
  fi

  if [ -x "$NONEBOT_VENV/bin/python" ]; then
    log "更新 NoneBot2 相关包"
    "$NONEBOT_VENV/bin/python" -m pip install --upgrade \
      "nonebot2[fastapi]" nonebot-adapter-onebot nonebot-plugin-genshinuid \
      --index-url "$PYPI_INDEX" --trusted-host "$(printf '%s' "$PYPI_INDEX" | awk -F/ '{print $3}')" \
      --disable-pip-version-check || warn "NoneBot2 更新失败"
  fi

  rm -f "$GSCORE_VENV/.botapp-deps-ok" "$NONEBOT_VENV/.botapp-deps-ok"
  log "更新完成，重启服务： ./botctl.sh restart all"
}

cmd_uninstall() {
  warn "即将停止服务并删除 systemd 单元（源码、虚拟环境与数据都会保留）"
  ask_yes "  确认？[y/N] " N || { info "已取消"; return 0; }

  for s in $ALL_SERVICES; do
    using_systemd "$s" && { systemctl disable --now "bot-$s.service" >/dev/null 2>&1 || true; }
    nohup_stop "$s" >/dev/null 2>&1 || true
  done
  if systemd_ok; then
    rm -f "$(unit_path napcat)" "$(unit_path gscore)" "$(unit_path nonebot)"
    systemctl daemon-reload
  fi
  log "服务已移除。要彻底清空数据请手动执行： rm -rf $BASE_DIR"
}

cmd_install() { exec bash "$BASE_DIR/install.sh" "$@"; }

# 无参数运行 botctl 时的菜单：优先引导到 Web 后台

cmd_plugin_install() {
  log "安装 / 修复 GsCore 桥接插件"
  if ! bash "$BASE_DIR/install.sh" --only-plugin; then
    die "插件安装失败，按上面的提示处理"
  fi
  info "重启 NoneBot2 生效： ./botctl.sh restart nonebot"
  info "然后验证： ./botctl.sh gscore-check"
}

# 修复第三段链路（NoneBot2 -> GsCore）。
# 最常见的故障：GsCore 启动要加载插件（约 15~30 秒）才会监听端口，而桥接插件
# 只在 NoneBot 启动那一刻连接一次，连不上就放弃、不会自动重试 —— 于是进程都
# “运行中”，但控制台里看不到已连接的 Bot。systemd 的 After=bot-gscore.service
# 只保证 gscore 进程已启动，不保证它已经就绪，所以每次重启都可能撞上这个空档。
# 修复动作：先确保 gscore 已监听 -> 再重启 nonebot 重新连接 -> 在 gscore 日志里
# 确认出现了“新的” WebSocket 连接记录。
cmd_relink() {
  local i now logf="$LOG_DIR/gscore.log" before=0 ok=0
  printf '\n  %s修复 NoneBot2 -> GsCore 连接%s\n\n' "$BLD" "$RST"

  # 1) gscore 必须在跑
  if [ "$(svc_state gscore)" != "active" ]; then
    warn "GsCore 没在运行，先把它启动"
    svc_start gscore || return 1
  fi

  # 2) 等 gscore 真正开始监听端口（它启动时要加载一堆插件）
  info "等待 GsCore 监听端口 $GSCORE_PORT（最多 90 秒，加载插件较慢是正常的）…"
  for i in $(seq 1 90); do
    port_listening "$GSCORE_PORT" && break
    sleep 1
  done
  if ! port_listening "$GSCORE_PORT"; then
    err "GsCore 的 $GSCORE_PORT 端口 90 秒内仍不可用 → ./botctl.sh log gscore 80"
    err "  （注意：若日志提示 status=209/STDOUT，是 logs 目录缺失，先 mkdir -p $LOG_DIR）"
    return 1
  fi
  log "GsCore 已就绪（$GSCORE_PORT 监听中）"

  # 3) 记下日志当前行数：只有“新增”的连接记录才算本次修复成功，避免误读历史
  if [ -f "$logf" ]; then
    before="$(wc -l < "$logf" 2>/dev/null | tr -d ' ')"
  fi
  case "${before:-0}" in ''|*[!0-9]*) before=0 ;; esac

  # 4) 重启 nonebot，让它重新发起连接
  info "重启 NoneBot2，让它重新连接 GsCore…"
  svc_restart nonebot

  # 5) 等 WS 建立：在 gscore 日志里找新增的 WebSocket 访问记录
  info "等待连接建立（最多 45 秒）…"
  for i in $(seq 1 45); do
    sleep 1
    [ -f "$logf" ] || continue
    now="$(wc -l < "$logf" 2>/dev/null | tr -d ' ')"
    case "${now:-0}" in ''|*[!0-9]*) now=0 ;; esac
    if [ "$now" -gt "$before" ] \
       && tail -n "+$((before + 1))" "$logf" 2>/dev/null | grep -qE '"WebSocket /ws/[^"?]+'; then
      ok=1
      break
    fi
  done

  echo
  if [ "$ok" = "1" ]; then
    log "第三段链路已恢复：GsCore 已接受 NoneBot2 的连接"
    info "细节： ./botctl.sh gscore-check （看 [3] Bot 实例 与 [4] 这一段）"
    return 0
  fi

  warn "没在 GsCore 日志里看到新的 WebSocket 连接记录"
  warn "继续排查："
  info "  1) 看 NoneBot2 日志： ./botctl.sh log nonebot 60"
  info "     若仍报「Core服务器连接失败」，多半是两端 WS_TOKEN 不一致"
  info "  2) 对齐令牌： ./botctl.sh gscore-token <令牌>   然后重跑本命令"
  info "  3) 全文诊断： ./botctl.sh gscore-check"
  return 1
}

# =============================================================================
#  插件依赖检测与安装
#  有些 GsCore 插件（特别是新装的）引用了 venv 里没有的 Python 包，
#  启动时会报 ModuleNotFoundError。这里扫插件源码里的 import 和 requirements.txt，
#  与 venv 里 importlib.metadata 已装的发行包做对比，一键补齐缺失依赖。
# =============================================================================
# 取所有候选插件目录（新旧两种布局都覆盖）。
# 路径之间用单独一行分隔，配合 while read 安全处理包含空格/中文的情况。
pydep_plugin_dirs() {
  local d
  for d in "$GSCORE_DIR/gsuid_core/plugins" "$GSCORE_DIR/plugins" \
           "$NONEBOT_DIR/plugins" "$NONEBOT_DIR/nonebot_plugin_gscore" \
           "$NONEBOT_DIR/nonebot_plugin_genshinuid"; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

# 调用目标 venv 的 Python 扫描插件依赖，输出 JSON 报告。
# 用一对独一无二的哨兵标签包住 JSON，panel 端能从 stdout 里抓出来。
cmd_pydep_scan() {
  local target="${1:-gscore}" py venv target_label="" plugin_dirs=""
  case "$target" in
    gscore|"")
      venv="$GSCORE_VENV"; target_label="GsCore" ;;
    nonebot)
      venv="$NONEBOT_VENV"; target_label="NoneBot2" ;;
    *)
      die "未知的 pydep target：$1（gscore | nonebot）"
      ;;
  esac

  printf '\n  %s[%s] 插件依赖扫描%s\n\n' "$BLD" "$target_label" "$RST"

  py="$venv/bin/python"
  if [ ! -x "$py" ]; then
    err "虚拟环境不存在：$venv（先执行： bash install.sh）"
    return 1
  fi

  while IFS= read -r d; do
    [ -n "$d" ] && { info "扫描目录：$d"; plugin_dirs="$plugin_dirs$(printf '\n%s' "$d")"; }
  done <<< "$(pydep_plugin_dirs)"

  if [ -z "$plugin_dirs" ]; then
    warn "没找到任何插件目录（GsCore/NoneBot 都没装插件？）"
  fi

  # 把插件目录逐个转成 NUL 分隔的 argv，避免被 shell 二次拆分丢掉带空格的路径
  local py_args=()
  while IFS= read -r d; do
    [ -n "$d" ] && py_args+=( "$(printf '%s' "$d" | tr '\n' ' ')" )
  done <<< "$plugin_dirs"

  # Python helper 写到临时文件（避免 `python - <<EOF | tee | grep` 的 heredoc 归属歧义）
  local helper
  helper="$(mktemp /tmp/.botapp-pydep-helper-XXXXXX.py)"
  cat > "$helper" <<'PY_HELPER'
import json, sys, os, re, ast, traceback
from pathlib import Path
import importlib.metadata as md

# 兜底：任何未处理异常（含 import 失败）都写到 @@pydep_err@@ 标签，方便 panel 诊断
# 注意：一定要放在 import 段之后、其它业务代码之前
def _pydep_excepthook(et, ev, tb):
    try:
        msg = ''.join(traceback.format_exception(et, ev, tb))
        sys.stdout.write("@@pydep_err@@" + msg.replace("\n", "\\n") + "@@\n")
        sys.stdout.flush()
    except Exception:
        pass
    sys.exit(2)
sys.excepthook = _pydep_excepthook

venv = Path(sys.argv[1])
raw_dirs = sys.argv[2:]
plugin_dirs = []
for blob in raw_dirs:
    for d in blob.split():
        if d.strip():
            plugin_dirs.append(d)

# 把插件目录的父目录塞进 sys.path。
# 理由：GsCore 运行时会把 `gsuid_core/` 目录加到 sys.path，所以插件里能写
# `import gscore_mail`（其实文件是 gsuid_core/gscore_mail.py）。我们做同样的操作，
# 之后就能用 importlib.util.find_spec 判断某个模块名到底能不能 import 到 ——
# 能 import 到的（无论是第三方包还是 GsCore 自带模块）都不算缺失。
for d_str in plugin_dirs:
    try:
        parent = Path(d_str).resolve().parent
        if parent.exists():
            p = str(parent)
            if p not in sys.path:
                sys.path.insert(0, p)
    except OSError:
        pass

import importlib.util as _ilu

# 模块名在当前 venv 里能不能找到（只查找 spec，不真正执行模块，安全）
_FIND_SPEC_CACHE = {}
def is_importable(modname: str) -> bool:
    if not modname or not modname.isidentifier():
        return False
    if modname in _FIND_SPEC_CACHE:
        return _FIND_SPEC_CACHE[modname]
    try:
        ok = _ilu.find_spec(modname) is not None
    except Exception:
        ok = False
    _FIND_SPEC_CACHE[modname] = ok
    return ok

# Python 3.10+ 直接有；老版本用内置名 + 常见 stdlib 兜底
try:
    STDLIB = sys.stdlib_module_names
except AttributeError:
    STDLIB = set(sys.builtin_module_names) | {
        "os","sys","json","re","time","pathlib","typing","functools","itertools",
        "collections","io","string","math","random","statistics","enum","dataclasses",
        "logging","traceback","warnings","copy","pickle","hashlib","secrets","uuid",
        "datetime","calendar","zoneinfo","threading","multiprocessing","subprocess",
        "socket","select","signal","email","html","http","urllib","urllib.parse",
        "xml","csv","configparser","struct","array","queue","heapq","bisect",
        "weakref","types","abc","numbers","decimal","fractions","contextlib","asyncio",
        "concurrent","inspect","dis","zipimport","pkgutil","importlib","platform",
        "tempfile","shutil","glob","fnmatch","linecache","pdb","profile","pstats",
        "timeit","trace","cProfile","__future__","builtins","typing_extensions",
        "annotated_types","packaging","tomllib",
    }

# 已装的发行包名集合（小写、已规范化）
INSTALLED_DIST = set()
INSTALLED_MOD = {}     # top-level module -> distribution name（已装）
for d in md.distributions():
    n = (d.metadata["Name"] or "").strip()
    if not n:
        continue
    n_low = n.lower().replace("_", "-")
    INSTALLED_DIST.add(n_low)
    try:
        for m in (d.files or []):
            top = m.parts[0]
            if top.endswith(".py") or top.endswith(".so") or ".dist-info" in top:
                continue
            if top.endswith(".dist-info"):
                continue
            INSTALLED_MOD.setdefault(top, n)
    except Exception:
        pass

# packages_distributions 更权威（top -> [dist]）
try:
    for mod, dists in md.packages_distributions().items():
        for di in dists:
            if di and di.lower().replace("_", "-") in INSTALLED_DIST:
                INSTALLED_MOD[mod.split(".")[0]] = di
                break
except Exception:
    pass

# module -> dist 名字（字符串）。返回值语义：
#   - 命中 INSTALLED_MOD：返回该模块对应的真 distribution 名（已装）
#   - heuristic 命中（小写连字符化后正好在 INSTALLED_DIST 中）：返回 modname（已装）
#   - 其它情况：返回 modname 作为【猜测的 dist 名字】（模块未装，但 dist 名大概率就是 modname）
# 永远不返回 None —— 调用方不用考虑空值。猜错的代价是显示一个需要装的包名让用户判断。
def dist_for_mod(modname: str) -> str:
    if modname in INSTALLED_MOD:
        return INSTALLED_MOD[modname]
    cand = modname.lower().replace("_", "-")
    if cand in INSTALLED_DIST:
        return modname
    return modname

# 不要让用户装/误报的基础包（这些一定是 GsCore / NoneBot2 体系里自带的）
INTERNAL_DIST = {
    "gsuid-core", "gsuid_core", "nonebot2", "nonebot", "nonebot-adapter-onebot",
    "fastapi", "uvicorn", "starlette", "pydantic", "pydantic-core",
    "httpx", "aiohttp", "websockets", "websockets-legacy", "jinja2", "tomli",
    "tomli-w", "click", "loguru",
}

# 测试/开发专用包：插件源码里常常 import，但运行时根本不需要，不列入缺失
TEST_DIST = {
    "pytest", "pytest-asyncio", "pytest-cov", "pytest-mock", "pytest-xdist",
    "pytest-aiohttp", "pytest-env", "pytest-timeout", "pytest-html",
    "nose", "nose2", "tox", "mock", "coverage", "hypothesis", "parameterized",
    "black", "isort", "flake8", "pylint", "mypy", "ruff",
}

# 防御 None / 非字符串输入，避免对 None 调用 .strip() 崩溃
def norm(name) -> str:
    if not name:
        return ""
    try:
        return str(name).strip().lower().replace("_", "-")
    except Exception:
        return ""

def req_pkg_name(line: str):
    """从 requirements.txt 一行解析出包名（去掉版本范围、extras、注释）。"""
    line = line.strip()
    if not line or line.startswith("#") or line.startswith("-"):
        return None
    # 形如 package[extra]==1.0; python_version<... -> 取 'package[extra]==1.0' 的首段
    head = line.split(";", 1)[0].strip()
    m = re.match(r"^([A-Za-z0-9]([A-Za-z0-9_.\-]*[A-Za-z0-9])?)", head)
    if not m:
        return None
    return m.group(1)

def is_plugin_dir(d: Path) -> bool:
    # 排除条件：跳过 site-packages / dist-info 这种明显不是源码插件的目录
    s = str(d)
    if "site-packages" in s or ".dist-info" in s:
        return False
    if (d / "__init__.py").exists():
        return True
    if (d / "setup.py").exists() or (d / "pyproject.toml").exists():
        return True
    return False

def extract_imports(p: Path) -> set:
    out = set()
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(text)
    except Exception:
        return out
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for n in node.names:
                top = (n.name or "").split(".")[0]
                if top:
                    out.add(top)
        elif isinstance(node, ast.ImportFrom):
            if node.level and node.level > 0:
                continue
            if node.module:
                top = node.module.split(".")[0]
                if top:
                    out.add(top)
    return out

plugins = []
skipped = []
for d_str in plugin_dirs:
    pdir = Path(d_str)
    if not pdir.exists():
        continue
    for entry in sorted(pdir.iterdir()):
        if not entry.is_dir() or entry.name.startswith(".") or entry.name.startswith("__"):
            continue
        if not is_plugin_dir(entry):
            # 不是标准插件形态，但仍然可能有 .py 文件；极简跳过
            continue

        # 收集「插件自有模块」名字集合 —— 插件常常 import 自己的包（如 GenshinUID
        # 内部 import GenshinUID.char_score / gscore_mail），这些绝不能当第三方依赖报，
        # 否则会把插件自己的目录名、子目录名都误报成缺失包。
        own_modules = {entry.name}
        try:
            for sub in entry.rglob("*"):
                if sub.name.startswith(".") or sub.name == "__pycache__":
                    continue
                if sub.is_dir():
                    own_modules.add(sub.name)
                elif sub.is_file() and sub.suffix == ".py":
                    stem = sub.stem
                    if stem and stem != "__init__":
                        own_modules.add(stem)
        except OSError:
            pass
        # 同时保存规范化形式（char_score -> char-score），匹配时不用反复转换
        own_norm = {norm(x) for x in own_modules if x}
        own_lower = {x.lower() for x in own_modules if x}

        pinfo = {
            "name": entry.name,
            "path": str(entry),
            "has_requirements": False,
            "requirements": [],
            "third_party": [],     # 候选第三方包（按 import 推断）
            "missing": [],         # 已声明但未装的包
        }
        # ---- 1) requirements.txt ----
        reqf = entry / "requirements.txt"
        if reqf.exists():
            pinfo["has_requirements"] = True
            try:
                for ln in reqf.read_text(encoding="utf-8", errors="replace").splitlines():
                    pkg = req_pkg_name(ln)
                    if pkg:
                        pinfo["requirements"].append(ln.split(";")[0].strip())
            except Exception:
                pass
        # ---- 2) 扫源码里的 import，提候选包 ----
        imp_set = set()
        for py in entry.rglob("*.py"):
            imp_set |= extract_imports(py)
        candidates = []
        for m in sorted(imp_set):
            ml = m.lower()
            if ml in STDLIB or ml == "gsuid_core":
                continue
            # 插件自有模块（自引用）：GenshinUID / char_score / gscore_mail …
            if ml in own_lower or norm(m) in own_norm:
                continue
            # 测试/开发框架：pytest / mock / coverage …，运行时不需要
            if norm(m) in TEST_DIST:
                continue
            # 在 venv 里能 import 到就跳过 —— 能覆盖 GsCore 自带的顶层模块
            # （gsuid_core/ 已被塞进 sys.path，所以 gscore_mail 这类模块能命中）
            if is_importable(m):
                continue
            dist = dist_for_mod(m)
            if not dist:
                continue
            dn = norm(dist)
            if dn in INSTALLED_DIST:
                # 已装，跳过
                continue
            if dn in INTERNAL_DIST:
                # 内部包（fastapi/uvicorn/...），跳过
                continue
            candidates.append(dist)
        pinfo["third_party"] = sorted(set(candidates))
        # ---- 3) 综合 requirements 文件 + import 推断，找出缺失 ----
        miss = []
        for req in pinfo["requirements"]:
            p_name = req_pkg_name(req)
            if not p_name:
                continue
            if norm(p_name) not in INSTALLED_DIST:
                miss.append(p_name)
        for c in pinfo["third_party"]:
            if norm(c) not in INSTALLED_DIST and norm(c) not in [norm(x) for x in miss]:
                miss.append(c)
        pinfo["missing"] = sorted({norm(m) for m in miss if m})  # 用规范化名去重
        plugins.append(pinfo)

# 计算全局汇总
all_missing = sorted({m for p in plugins for m in p["missing"]})

result = {
    "venv": str(venv),
    "summary": {
        "plugin_count": len(plugins),
        "with_missing": sum(1 for p in plugins if p["missing"]),
        "missing_pkgs": all_missing,
    },
    "plugins": plugins,
}
sys.stdout.write("@@pydep_json@@" + json.dumps(result, ensure_ascii=False) + "@@pydep_json_end@@\n")
# 给 shell 端的简版信息，方便它打印一键安装的命令
sys.stdout.write("@@pydep_info@@missing=%d%s@@\n" % (
    len(all_missing),
    (" " + ",".join(all_missing)) if all_missing else "",
))
sys.stdout.flush()
PY_HELPER

  # 跑 helper。2>&1 让 stderr 也进 pipeline（被 tee 写到 file，便于 panel 诊断）。
  # 不在这里 unlink /tmp/.botapp-pydep.out —— panel 端读完后自己清，避免时序 bug。
  "$py" "$helper" "$venv" "${py_args[@]}" 2>&1 | tee /tmp/.botapp-pydep.out | grep -E '^@@pydep_'
  local py_rc=${PIPESTATUS[0]}
  rm -f "$helper"

  # 从 /tmp/.botapp-pydep.out 解码两个标签
  result_info=""
  result_missing_count=0
  result_missing_pkgs=""
  if [ -s /tmp/.botapp-pydep.out ]; then
    raw_info="$(grep -oE '@@pydep_info@@missing=[0-9]+( [A-Za-z0-9_,.\-]+)?@@' /tmp/.botapp-pydep.out | head -1)"
    result_missing_count="$(printf '%s' "$raw_info" | sed -nE 's/.*missing=([0-9]+).*/\1/p')"
    result_missing_count="${result_missing_count:-0}"
    result_missing_pkgs="$(printf '%s' "$raw_info" | sed -nE 's/.*missing=[0-9]+ (.*)@@/\1/p' | tr ',' ' ')"
    # 不在这里 rm /tmp/.botapp-pydep.out —— panel 端会在自己读完后清理。
    # 之前在这里 rm 会和 panel 抢文件，导致 panel 永远读到空。
  fi
  # Python helper 报错的话，traceback 被 excepthook 写到了 @@pydep_err@@ 标签里
  if [ -s /tmp/.botapp-pydep.out ] && grep -q '@@pydep_err@@' /tmp/.botapp-pydep.out; then
    err_msg="$(grep -oE '@@pydep_err@@.*@@' /tmp/.botapp-pydep.out | head -1 | sed -E 's/@@pydep_err@@//;s/@@$//' | tr '\\n' '\n' | head -n 40)"
    err "Python helper 报错："
    printf '%s\n' "$err_msg" | sed 's/^/      /'
    return 1
  fi
  # stderr 部分会出现在 /tmp/.botapp-pydep.out 里（2>&1 之后），但 grep 只显示标签行。
  # 这里把非标签、非 JSON 块的剩余行也提示一下，方便 shell 用户。
  # 排除掉插件源码自带的 SyntaxWarning / DeprecationWarning 这类噪声。
  if [ -s /tmp/.botapp-pydep.out ]; then
    other="$(grep -vE '^@@pydep_' /tmp/.botapp-pydep.out \
      | grep -vE 'SyntaxWarning|DeprecationWarning|BytesWarning|ImportWarning|^<unknown>|^<frozen|^\s*$' \
      | head -n 20)"
    if [ -n "$other" ]; then
      warn "扫描过程有非标签输出："
      printf '%s\n' "$other" | sed 's/^/      /'
    fi
  fi

  if [ "$result_missing_count" -gt 0 ] && [ -n "$result_missing_pkgs" ]; then
    result_info="缺失 $result_missing_count 个包：$result_missing_pkgs"
    # 把缺失包名缓存到文件，给 pydep-install 自动填充参数用
    printf '%s\n' $result_missing_pkgs > /tmp/.botapp-pydep-missing.txt
  else
    result_info="全部依赖齐全"
    : > /tmp/.botapp-pydep-missing.txt
  fi
  info "$result_info"
  echo
  if [ "$result_missing_count" -gt 0 ]; then
    warn "$result_missing_count 个包被插件引用但未安装"
    echo
    info "全自动（重新扫描 + 直接装，一条命令）："
    printf '\n      %s./botctl.sh pydep-install%s\n' "$BLD" "$RST"
    info "只装这几个包（复制即用）："
    printf '\n      %s./botctl.sh pydep-install %s%s\n\n' "$BLD" "$result_missing_pkgs" "$RST"
    info "或在 Web 后台 GsCore →「插件依赖检测与修复」点「一键安装」"
  else
    log "全部依赖齐全，无需安装"
  fi
}

# 内部：用多源轮询把一组包装进指定 venv。成功返回 0。
# $1 = venv 的 python 路径；$2 = verbose（yes/no）；$3... = 包名。
_pydep_pip_batch() {
  local py="$1" verbose="${2:-yes}"
  shift 2
  local idx host out rc=1
  for idx in $PYPI_INDEX $PYPI_INDEX_FALLBACK; do
    [ -z "$idx" ] && continue
    host="$(printf '%s' "$idx" | awk -F/ '{print $3}' | awk '{print $1}')"
    [ "$verbose" = yes ] && info "pip 源：$idx"
    out="$(mktemp)"
    if "$py" -m pip install "$@" \
        --index-url "$idx" --trusted-host "$host" \
        --timeout 120 --retries 5 --disable-pip-version-check 2>&1 | tee "$out"; then
      rm -f "$out"
      rc=0
      break
    fi
    # 这几类是包名/依赖清单本身的问题，换源毫无意义，立刻返回失败
    # （"No matching distribution found for xxx" = PyPI 上没这个包名，多半是扫描误报）
    if grep -qE 'does not appear to be a Python project|Invalid requirement|No matching distribution found for' "$out"; then
      rm -f "$out"
      return 1
    fi
    rm -f "$out"
    [ "$verbose" = yes ] && warn "该源失败，切下一个源…"
  done
  return $rc
}

# 装一组指定的包到目标 venv（沿用 install.sh 同款国内源策略，失败自动换 fallback）。
# 用法： cmd_pydep_install gscore pycryptodome [Pillow ...]
cmd_pydep_install() {
  local target="${1:-gscore}"
  shift || true
  local venv py
  case "$target" in
    gscore) venv="$GSCORE_VENV" ;;
    nonebot) venv="$NONEBOT_VENV" ;;
    *) die "未知的 pydep target：$target" ;;
  esac

  if [ $# -lt 1 ]; then
    # 没传包名 → 现场重新扫描一次拿最新结果，避免用到过期缓存（比如上次扫描的
    # 误报包名会让 pip 因「No matching distribution」整批失败）
    info "未指定包名 → 先扫描一遍拿到最新缺失列表…"
    echo
    cmd_pydep_scan "$target" || true
    echo
    if [ -s /tmp/.botapp-pydep-missing.txt ]; then
      set -- $(cat /tmp/.botapp-pydep-missing.txt)
      info "扫描到 $# 个缺失包，开始安装：$*"
    else
      die "没扫到缺失包（或扫描失败）。若要手动指定，用法：
    ./botctl.sh pydep-install openpyxl fonttools socksio"
    fi
  fi

  py="$venv/bin/python"
  if [ ! -x "$py" ]; then
    die "虚拟环境不存在：$venv（先执行： bash install.sh）"
  fi

  log "安装 ${#} 个包到 $venv"
  for p in "$@"; do
    info "  - $p"
  done

  if ! "$py" -m pip --version >/dev/null 2>&1; then
    "$py" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  "$py" -m pip install --upgrade pip setuptools wheel \
    --index-url "$PYPI_INDEX" --disable-pip-version-check -q >/dev/null 2>&1 || true

  # 先整批装（一次解析依赖最快）。注意 pip 是「全有或全无」：
  # 这批里只要有 1 个包名在 PyPI 上不存在（比如扫描误报），整批都会失败、一个都装不上。
  if _pydep_pip_batch "$py" yes "$@"; then
    log "安装完成"
    echo
    info "让新依赖生效需要重启 GsCore（复制执行）："
    printf '\n      %s./botctl.sh restart gscore%s\n\n' "$BLD" "$RST"
    return 0
  fi

  # 整批失败 → 逐个重试，自动跳过装不上的，保证好包能装上
  if [ $# -gt 1 ]; then
    warn "整批安装失败，改为逐个重试（自动跳过装不上的包）…"
    echo
    local p_pkg log_f ok_str="" fail_str="" pkg
    for p_pkg in "$@"; do
      info "单独安装：$p_pkg"
      log_f="$(mktemp)"
      if _pydep_pip_batch "$py" no "$p_pkg" >"$log_f" 2>&1; then
        ok_str="$ok_str $p_pkg"
        info "  成功"
      else
        fail_str="$fail_str $p_pkg"
        warn "  失败：$(grep -iE 'no matching distribution|ERROR:|error:' "$log_f" | tail -n 2 | tr '\n' ' ')"
      fi
      rm -f "$log_f"
    done
    echo
    [ -n "$ok_str" ] && log "装好了：$ok_str"
    [ -n "$fail_str" ] && {
      warn "装不上：$fail_str"
      info "  ↑ 这类多半是扫描误报（PyPI 上没这个包名），忽略即可。"
    }
    [ -z "$ok_str" ] && { err "没有任何包装成功。"; return 1; }
    echo
    info "让新依赖生效需要重启 GsCore（复制执行）："
    printf '\n      %s./botctl.sh restart gscore%s\n\n' "$BLD" "$RST"
    return 0
  fi

  err "安装失败。建议在 config.conf 里填 HTTP_PROXY_URL 后重试。"
  return 1
}

cmd_pydep() {
  case "${1:-scan}" in
    scan)     cmd_pydep_scan "${2:-gscore}" ;;
    install)  cmd_pydep_install "${2:-gscore}" "${@:3}" ;;
    *)        printf '用法： pydep scan [gscore|nonebot] | pydep install <target> <pkg...>\n'; return 2 ;;
  esac
}

cmd_fetch_gscore() {
  local src="${1:-}"
  [ -n "$src" ] && log "使用指定源：$src"
  if bash "$BASE_DIR/scripts/gscore-fetch.sh" "$GSCORE_DIR" "$src"; then
    log "获取完成，接下来执行： ./botctl.sh install --skip-apt  （或 ./botctl.sh update 装依赖）"
  else
    die "GsCore 源码获取失败，按上面的提示手动放入 $GSCORE_DIR 即可"
  fi
}

# =============================================================================
#  入口
# =============================================================================
usage() {
  printf '\n  %sbot-app 控制台%s  v%s\n' "$BLD" "$RST" "$VERSION"
  printf '  安装目录：%s\n\n' "$BASE_DIR"
  cat <<'USAGE'
  【日常】
    status                  查看总览（状态 / 端口 / 监听 / 自启）
    start   [服务|all]      启动
    stop    [服务|all]      停止
    restart [服务|all]      重启
    log <服务> [行数|-f]    查看日志（-f 实时跟踪）

  【QQ 登录】
    qr                      显示 NapCat 登录二维码
    napcat-token            查看 NapCat 的 WebUI token 与反向 WS token
    napcat-ws <QQ号>        写入反向 WS 配置并自动填 token

  【配置与运维】
    gscore-host [地址]      设置 GsCore 监听地址（默认 0.0.0.0，局域网才能开控制台）
    gscore-config           查看 GsCore 配置路径与关键项
    gscore-code [新注册码]  打印控制台注册码（带参数则改成新值）
    gscore-check            控制台诊断：页面能开但接口全挂时用
    gscore-rebuild          用正确的 Python 版本重建 GsCore 虚拟环境（控制台全 404 时用）
    gscore-plugin <git地址> 手动给 GsCore 装插件（走加速前缀，绕开它的 Git 下载失败）

  【公网访问】（群里其他人要打开登录页时用）
    expose install          安装 cloudflared（apt 官方源 -> 加速前缀 -> 直连）
    expose named <域名>     命名隧道：地址固定，注册为系统服务（需域名托管在 CF）
    expose start            起临时隧道并打印公网地址
    expose url              再打印一次当前公网地址
    expose stop             停止隧道
    expose status           查看隧道状态与地址
    expose log [行数]       查看隧道日志
    gscore-token <令牌>     同时设置 GsCore 与 NoneBot2 的 WS_TOKEN（两端对齐）
    fetch-gscore [源URL]    重新获取 GsCore 源码（多源自动探测）
    plugin-install          安装/修复 GsCore 桥接插件（NoneBot2 侧）
    relink                  修复 NoneBot2 -> GsCore 连接（等 gscore 就绪后重连 nonebot）
    pydep                   扫描插件 import 与 requirements.txt，列出缺失依赖
    pydep-install           全自动：重新扫描，把缺的包一次装齐（推荐）
    pydep-install <pkg...>  只装指定的包（如 pydep-install openpyxl socksio）
    update                  更新代码与依赖
    doctor                  一键自检（venv / 端口 / 令牌 / 连通性）

  【Web 后台】装完就不用再 SSH 了
    panel install           安装并启动 Web 后台（推荐先做这个）
    panel status            查看后台状态、地址、密码
    panel install           安装 Web 后台为系统服务（首次安装，开机自启）
    panel start|stop|restart 启停面板（没装过会自动补装）
    panel enable|disable    面板开机自启开关
    panel url               只看后台地址
    panel port [新端口]      查看或修改后台端口（自动改配置并重启）
    panel password [新密码]  查看或修改后台密码
    panel restart|stop      重启 / 停止后台
    panel log [行数]        后台日志

  【部署】
    ports                   端口一览：谁在用、是否冲突、怎么改
    units                   重新生成 systemd 单元
    enable  [服务|all]      配置开机自启（并立即启动）
    disable [服务|all]      取消开机自启
    install [参数]          执行安装脚本
    uninstall               卸载（保留数据）

  服务名：napcat | gscore | nonebot | all

  例子：  botctl start all        botctl napcat-ws 123456789
          botctl log nonebot -f  botctl doctor
USAGE
  echo
}

# 无参数运行 botctl 时：先列清单，有终端再给编号快捷选择
cmd_menu() {
  usage

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    return 0
  fi

  printf '  %s输入序号直接执行，直接回车退出%s\n\n' "$CYA" "$RST"
  cat <<'MENU'
    1) status          2) start all       3) stop all        4) restart all
    5) qr              6) napcat-token    7) doctor          8) enable all
    9) disable all    10) 查看日志       11) 写入反向WS     12) gscore-host
   13) update         14) fetch-gscore   15) install        16) gscore-token
   17) gscore-code    18) gscore-check   19) gscore-rebuild  20) plugin-install
   21) gscore-plugin  22) 公网隧道        23) Web 后台        24) 修复连接
    0) 退出
MENU
  echo

  local choice="" s="" qq=""
  printf '  选择> '
  read -r choice || return 0
  [ -n "$choice" ] || return 0

  case "$choice" in
    1)  main status ;;
    2)  main start all ;;
    3)  main stop all ;;
    4)  main restart all ;;
    5)  main qr ;;
    6)  main napcat-token ;;
    7)  main doctor ;;
    8)  main enable all ;;
    9)  main disable all ;;
    10) printf '  服务名（napcat / gscore / nonebot，默认 nonebot）: '
        read -r s
        main log "${s:-nonebot}" 80 ;;
    11) printf '  你的 QQ 号: '
        read -r qq
        if [ -n "$qq" ]; then main napcat-ws "$qq"; else warn "没输入 QQ 号，已取消"; fi ;;
    12) main gscore-host ;;
    13) main update ;;
    14) main fetch-gscore ;;
    15) main install ;;
    16) printf '  令牌（留空则用 config.conf 里的 GSUID_CORE_WS_TOKEN）: '
        read -r s
        main gscore-token "$s" ;;
    17) main gscore-code ;;
    18) main gscore-check ;;
    19) main gscore-rebuild ;;
    20) main plugin-install ;;
    21) printf '  Git 仓库地址（例 https://github.com/tyql688/NTEUID.git）: '
        read -r s
        [ -n "$s" ] && main gscore-plugin "$s" || warn "没输入地址，已取消" ;;
    22) printf '  公网隧道： 1) 安装 cloudflared  2) 临时隧道  3) 命名隧道(固定地址)  4) 查看  5) 停止  [1]: '
        read -r s
        case "${s:-1}" in
          1) main expose install ;;
          2) main expose start ;;
          3) printf '  完整域名（例 nte.487510.xyz）: '
             read -r d
             [ -n "$d" ] && main expose named "$d" || warn "没输入域名，已取消" ;;
          4) main expose status ;;
          5) main expose stop ;;
          *) warn "无效选择" ;;
        esac ;;
    23) printf '  Web 后台： 1) 安装并启动  2) 查看状态  3) 修改密码  4) 重启  [1]: '
        read -r s
        case "${s:-1}" in
          1) main panel install ;;
          2) main panel status ;;
          3) printf '  新密码: '
             read -r p
             [ -n "$p" ] && main panel password "$p" || warn "没输入，已取消" ;;
          4) main panel restart ;;
          *) warn "无效选择" ;;
        esac ;;
    24) main relink ;;
    0|q|Q|exit) return 0 ;;
    *)  err "无效选择：$choice"; usage ;;
  esac
}

main() {
  local cmd="${1:-menu}"
  shift || true

  case "$cmd" in
    menu|"")   cmd_menu ;;
    json)      cmd_json_overview ;;
    panel)     cmd_panel "${1:-status}" "${2:-}" ;;
    ports)     cmd_ports ;;
    install)   cmd_install "$@" ;;
    fetch-gscore|fetch) cmd_fetch_gscore "${1:-}" ;;
    plugin-install|plugin) cmd_plugin_install ;;
    relink|fix-link) cmd_relink ;;
    start)
      for s in $(expand_targets "${1:-all}"); do svc_start "$s"; done ;;
    stop)
      for s in $(echo "$(expand_targets "${1:-all}")" | tr ' ' '\n' | tac | tr '\n' ' '); do svc_stop "$s"; done ;;
    restart)
      local t; t="$(expand_targets "${1:-all}")"
      for s in $(echo "$t" | tr ' ' '\n' | tac | tr '\n' ' '); do svc_stop "$s"; done
      for s in $t; do svc_start "$s"; done ;;
    status)    cmd_status ;;
    log|logs)  cmd_log "${1:-}" "${2:-60}" ;;
    units)     write_units ;;
    enable)    cmd_enable "${1:-all}" ;;
    disable)   cmd_disable "${1:-all}" ;;
    qr|qrcode) cmd_qr ;;
    napcat-token|token) cmd_napcat_token ;;
    napcat-ws) cmd_napcat_ws "${1:-}" ;;
    gscore-config) cmd_gscore_config ;;
    gscore-code|gscore-register) cmd_gscore_code "${1:-}" ;;
    gscore-check) cmd_gscore_check ;;
    gscore-rebuild) cmd_gscore_rebuild ;;
    gscore-plugin) cmd_gscore_plugin "${1:-}" ;;
    pydep|pydep-scan|pydep-check)
      cmd_pydep scan gscore ;;
    pydep-install)
      # main() 已经把命令名 shift 掉了，这里不能再 shift —— 否则会吃掉第一个包名
      cmd_pydep install gscore "$@" ;;
    pydep-fix|pydep-auto)
      # 全自动：不带包名 → cmd_pydep_install 会先扫描再装
      cmd_pydep install gscore ;;
    expose)  cmd_expose "${1:-status}" "${2:-}" ;;
    gscore-token)  cmd_gscore_token "${1:-}" ;;
    gscore-host)   cmd_gscore_host "${1:-}" ;;
    doctor)    cmd_doctor ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    version|-v) echo "botctl $VERSION" ;;
    help|-h|--help) usage ;;
    *) usage; die "未知命令：$cmd" ;;
  esac
}

main "$@"

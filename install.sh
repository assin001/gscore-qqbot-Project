#!/usr/bin/env bash
# =============================================================================
#  bot-app 一键安装脚本
#  环境：fnOS / Debian / Ubuntu（x86_64 或 arm64），全程不使用 Docker
#  安装内容：1) Python 虚拟环境  2) GsCore  3) NoneBot2 项目  4) NapCat(QQ 协议端)
#
#  用法： bash install.sh [选项]
#    --only-napcat      只装 NapCat
#    --skip-napcat      不装 NapCat
#    --skip-gscore      不装 GsCore
#    --skip-nonebot     不装 NoneBot2
#    --skip-apt         不执行 apt 安装系统依赖
#    --force            强制重装依赖 / 覆盖已有的 .env
#    --autostart        装完立刻配置 systemd 开机自启并启动
#    -y, --yes          全部确认，不交互
# =============================================================================
set -uo pipefail

# ------------------------------ 解析脚本真实路径 -------------------------------
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd -P "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
_self="$(cd -P "$(dirname "$_self")" && pwd)/$(basename "$_self")"

# ------------------------------ CRLF 自愈（Windows 上编辑过的文件常带 \r\n） -----
if [ -z "${_BOTAPP_CRLF:-}" ] && grep -q $'\r' "$_self" 2>/dev/null; then
  export _BOTAPP_CRLF=1
  sed -i 's/\r$//' "$_self" 2>/dev/null
  exec bash "$_self" "$@"
fi

SCRIPT_DIR="$(dirname "$_self")"
BASE_DIR="$SCRIPT_DIR"
CONF_FILE="$BASE_DIR/config.conf"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s[·]%s %s\n' "$CYA" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'USAGE'
用法： bash install.sh [选项]

  --only-napcat            只装 NapCat
  --skip-napcat            不装 NapCat
  --skip-gscore            不装 GsCore
  --skip-nonebot           不装 NoneBot2
  --skip-apt               不执行 apt 安装系统依赖
  --gscore-source <URL>    指定 GsCore 源码地址（git 仓库 或 tar.gz 直链）
  --force                  强制重装依赖 / 覆盖已有的 .env
  --autostart              装完立刻配置 systemd 开机自启并启动
  -y, --yes                全部确认，不交互
  -h, --help               显示本帮助
USAGE
}

# ------------------------------ 参数解析 --------------------------------------
SKIP_APT=0; SKIP_NAPCAT=0; SKIP_GSCORE=0; SKIP_NONEBOT=0
AUTOSTART=0; ASSUME_YES=0; FORCE=0; ONLY_PLUGIN=0; SKIP_PANEL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --only-napcat)  SKIP_GSCORE=1; SKIP_NONEBOT=1 ;;
    --skip-napcat)  SKIP_NAPCAT=1 ;;
    --skip-gscore)  SKIP_GSCORE=1 ;;
    --skip-nonebot) SKIP_NONEBOT=1 ;;
    --skip-apt)     SKIP_APT=1 ;;
    --only-plugin)  ONLY_PLUGIN=1; SKIP_GSCORE=1; SKIP_NAPCAT=1; SKIP_APT=1 ;;
    --skip-panel)   SKIP_PANEL=1 ;;
    --gscore-source) GSCORE_SOURCE_OVERRIDE="${2:-}"; shift ;;
    --force)        FORCE=1 ;;
    --autostart)    AUTOSTART=1 ;;
    -y|--yes)       ASSUME_YES=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "未知参数：$1（用 -h 查看帮助）" ;;
  esac
  shift
done

# ------------------------------ 读取配置 --------------------------------------
if [ ! -f "$CONF_FILE" ]; then
  err "找不到 config.conf"
  err "  脚本真实路径  : $_self"
  err "  推断的安装目录: $BASE_DIR"
  err "  期望的配置文件: $CONF_FILE"
  exit 1
fi
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

NAPCAT_PROXY_OPT="${NAPCAT_PROXY_OPT:-1}"
NAPCAT_INSTALL_CLI="${NAPCAT_INSTALL_CLI:-yes}"
GH_PROXY_LIST="${GH_PROXY_LIST:-}"

# =============================================================================
#  工具函数
# =============================================================================
gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'a-f0-9' < /dev/urandom | head -c 32
  fi
}

lan_ip() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-127.0.0.1}"
}

# 下载文件：先直连，再依次尝试 GitHub 加速前缀（显示进度，带超时）
download_file() {
  local raw="$1" out="$2" p
  if curl -fL --connect-timeout 15 --max-time 300 --progress-bar -o "$out" "$raw"; then return 0; fi
  for p in $GH_PROXY_LIST; do
    [ -z "$p" ] && continue
    info "直连失败，尝试加速：$p"
    if curl -fL --connect-timeout 15 --max-time 300 --progress-bar -o "$out" "$p/$raw"; then return 0; fi
  done
  return 1
}

# 如果配置了本地代理（clash/v2ray 等），让 git/curl/pip/apt 都走它
apply_http_proxy() {
  [ -n "${HTTP_PROXY_URL:-}" ] || return 0
  export http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" all_proxy="$HTTP_PROXY_URL"
  export HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" ALL_PROXY="$HTTP_PROXY_URL"
  export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="localhost,127.0.0.1,::1"
  info "已启用本地代理：$HTTP_PROXY_URL"
}

# =============================================================================
#  依赖管理：venv / uv / pip
# =============================================================================
UV_BIN=""

init_uv() {
  [ "$USE_UV" = "no" ] && return 1
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    info "使用系统 uv：$UV_BIN"
    return 0
  fi
  local uvvenv="$ENV_DIR/uv-venv"
  if [ ! -x "$uvvenv/bin/uv" ]; then
    info "安装 uv（放进独立 venv，不污染系统 Python）"
    "$PYTHON_BIN" -m venv "$uvvenv" || return 1
    "$uvvenv/bin/python" -m pip install --upgrade pip \
      --index-url "$PYPI_INDEX" --disable-pip-version-check -q >/dev/null 2>&1 || true
    info "下载 uv 本体（约 15MB，会显示进度）"
    if ! "$uvvenv/bin/python" -m pip install uv \
         --index-url "$PYPI_INDEX" --disable-pip-version-check; then
      warn "uv 安装失败，后面用系统 Python + pip（不影响使用）"
      return 1
    fi
  fi
  UV_BIN="$uvvenv/bin/uv"
  info "使用本地 uv：$UV_BIN"
  return 0
}

uv_env() {
  export UV_INDEX_URL="$PYPI_INDEX"
  export UV_DEFAULT_INDEX="$PYPI_INDEX"
  # uv 下载解释器走 GitHub Release，PyPI 镜像管不到这块，必须单独指定镜像
  [ -n "${UV_PYTHON_INSTALL_MIRROR:-}" ] && export UV_PYTHON_INSTALL_MIRROR
  [ -n "${UV_ASTRAL_MIRROR_URL:-}" ] && export UV_ASTRAL_MIRROR_URL
  export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-180}"
}

pip_install() {
  local vdir="$1"; shift
  local py="$vdir/bin/python" idx host out
  [ -x "$py" ] || { err "虚拟环境不存在：$vdir"; return 1; }
  if ! "$py" -m pip --version >/dev/null 2>&1; then
    "$py" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  "$py" -m pip install --upgrade pip setuptools wheel \
    --index-url "$PYPI_INDEX" --disable-pip-version-check -q >/dev/null 2>&1 || true

  for idx in $PYPI_INDEX $PYPI_INDEX_FALLBACK; do
    host="$(printf '%s' "$idx" | awk -F/ '{print $3}')"
    info "pip 源：$idx"
    out="$(mktemp)"
    if "$py" -m pip install "$@" \
        --index-url "$idx" --trusted-host "$host" \
        --timeout 120 --retries 5 --disable-pip-version-check 2>&1 | tee "$out"; then
      rm -f "$out"
      return 0
    fi
    # 这几类是依赖清单/环境本身的问题，换源毫无意义，别浪费时间来回切
    if grep -qE 'cannot be installed when requiring hashes|does not appear to be a Python project|Invalid requirement|No matching distribution found for the given hash' "$out"; then
      err "这是依赖清单本身的问题（不是网络或镜像源的问题），已停止换源重试。"
      rm -f "$out"
      return 1
    fi
    rm -f "$out"
    warn "该源安装失败，切换下一个源…"
  done
  return 1
}

# 版本比较： $1 >= $2 返回 0
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# 创建 venv。
# 系统 Python 满足 minver 就直接用它（省掉解释器下载），否则用 uv 下载 pyver。
# 已存在但版本过低的 venv 会自动重建 —— 低版本 Python 会让 GsCore 控制台整体不可用。
ensure_venv() {
  local vdir="$1" pyver="${2:-}" minver="${3:-3.11}" sysver sysok=0 curver

  if [ -x "$vdir/bin/python" ]; then
    curver="$("$vdir/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
    if ver_ge "${curver:-0.0}" "$minver"; then
      info "虚拟环境已存在：$vdir（$("$vdir/bin/python" -V 2>&1)）"
      return 0
    fi
    warn "已存在的虚拟环境是 Python ${curver:-未知}，低于要求的 $minver，重建中…"
    warn "  （GsCore 在 Python < 3.12 上网页控制台会整体 404，必须 >= 3.12）"
    rm -rf "$vdir"
  fi

  sysver="$("$PYTHON_BIN" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
  if [ -n "$sysver" ] && ver_ge "$sysver" "$minver"; then sysok=1; fi

  if [ "$sysok" = "1" ] && [ "${PREFER_SYSTEM_PYTHON:-yes}" = "yes" ]; then
    log "用系统 Python $sysver 创建虚拟环境（满足 >= $minver，免下载解释器）"
    "$PYTHON_BIN" -m venv "$vdir" || die "创建虚拟环境失败：$vdir（确认已装 python3-venv）"
    return 0
  fi

  if [ -n "$UV_BIN" ] && [ -n "$pyver" ]; then
    uv_env
    log "系统 Python ${sysver:-未知} 不满足 >= $minver，用 uv 准备 Python $pyver"
    info "镜像：${UV_PYTHON_INSTALL_MIRROR:-GitHub 官方源（会很慢）}"
    warn "首次要从网络拉一份约 25MB 的解释器，慢的话请耐心等"
    if "$UV_BIN" venv --python "$pyver" "$vdir"; then
      log "已用 uv 创建虚拟环境（Python $pyver）：$vdir"
      return 0
    fi
    warn "uv 准备 Python $pyver 失败"
  fi

  [ "$sysok" = "1" ] || die "系统 Python ${sysver:-未知} 低于必需的 $minver，且 uv 没能备好 Python $pyver。
    可以：在 config.conf 里填 HTTP_PROXY_URL 后重跑，或手动装一个 >= $minver 的 Python。"
  log "退回系统 Python $sysver 创建虚拟环境"
  "$PYTHON_BIN" -m venv "$vdir" || die "创建虚拟环境失败：$vdir"
}

# =============================================================================
#  环境检查
# =============================================================================
preflight() {
  log "环境检查"

  case "$BASE_DIR" in
    *" "*) die "安装路径不能包含空格：$BASE_DIR" ;;
  esac

  if [ "$(id -u)" != "0" ]; then
    warn "当前不是 root。systemd 服务与 NapCat 安装需要 root，建议用 sudo 运行本脚本。"
  fi

  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "系统：${PRETTY_NAME:-unknown}"
    case "${ID:-} ${ID_LIKE:-}" in
      *debian*|*ubuntu*) : ;;
      *) warn "非 Debian 系系统（${ID:-unknown}），apt 步骤可能不可用" ;;
    esac
  fi
  info "架构：$(uname -m)"

  local avail
  avail="$(df -Pk "$BASE_DIR" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')"
  if [ -n "$avail" ]; then
    info "安装位置：$BASE_DIR（可用 ${avail}GB）"
    # GsCore 依赖里有 onnxruntime / playwright / scikit-learn，加上 NapCat 自带的 QQ 本体，
    # 整体占用量在 3~5GB，留 8GB 才算宽裕。
    if [ "$avail" -lt 3 ]; then
      die "可用空间不足 3GB，装不下（GsCore 依赖 + QQ 本体约需 3~5GB）"
    elif [ "$avail" -lt 8 ]; then
      warn "可用空间只有 ${avail}GB，比较紧张，建议留 8GB 以上"
    fi
  fi

  local pyver
  pyver="$("$PYTHON_BIN" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
  if [ -z "$pyver" ]; then
    die "找不到 $PYTHON_BIN，请先 apt-get install -y python3 python3-venv python3-pip"
  fi
  info "系统 Python：$pyver"
  if ! ver_ge "$pyver" "${GSCORE_PYTHON_MIN:-3.12}"; then
    warn "系统 Python $pyver 低于 GsCore 要求的 ${GSCORE_PYTHON_MIN:-3.12}"
    warn "  → 会用 uv 下载 Python $GSCORE_PYTHON_VERSION 建环境（约 25MB）"
    warn "  → 如果下载太慢，在 config.conf 里填 HTTP_PROXY_URL 会快很多"
  fi
}

# 基础工具 + QQ(NT) 运行库 + 无头显示。这份清单对齐官方 NapCat 安装脚本，
# QQ 在 Linux 上跑不起来十有八九是缺 libnss3/libgbm1/libasound2 这一批。
install_apt_deps() {
  [ "$SKIP_APT" = "1" ] && { warn "已跳过系统依赖安装"; return 0; }
  command -v apt-get >/dev/null 2>&1 || { warn "非 apt 系统，跳过系统依赖安装"; return 0; }

  local base_pkgs="git curl unzip zip jq ca-certificates xvfb screen xauth procps fontconfig python3 python3-venv python3-pip libnss3 libgbm1 cpio rpm2cpio"
  # 这几个在 Ubuntu 24.04+ 有 t64 变体，装错版本 QQ 起不来
  local qt_pkgs="libglib2.0-0 libatk1.0-0 libatspi2.0-0 libgtk-3-0 libasound2"

  local missing=() p
  for p in $base_pkgs $qt_pkgs; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    info "系统依赖已齐备"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update 失败，继续尝试安装"

  # 缓存刷新后再做 t64 探测（apt-cache 需要已有索引）
  local want=() t64
  for p in $base_pkgs; do want+=("$p"); done
  for p in $qt_pkgs; do
    t64="${p}t64"
    if apt-cache show "$t64" >/dev/null 2>&1; then want+=("$t64"); else want+=("$p"); fi
  done

  missing=()
  for p in "${want[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    info "系统依赖已齐备"
    return 0
  fi

  log "安装系统依赖（${#missing[@]} 个）"
  if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    warn "系统依赖安装失败，请手动执行："
    warn "  apt-get install -y ${missing[*]}"
  fi
}

# =============================================================================
#  GsCore
# =============================================================================
# GsCore 的 requirements.txt 是 `uv export --frozen` 自动生成的锁定文件，有两个坑：
#   1) 里面有一行 `-e .`（项目自身），相对路径按【当前工作目录】解析，
#      如果不在 GsCore 目录里执行，`.` 会指到 bot-app 根目录 → 报
#      "does not appear to be a Python project" / "no single file to hash"
#   2) 每个包都带 --hash，会让 pip 自动进入 hash 校验模式，
#      而该模式不允许安装本地可编辑包 → `-e .` 必然失败
# 所以：必须在 GsCore 目录下执行，优先走官方推荐的 uv sync，pip 兜底时剔除 `-e .`。
install_gscore_deps() {
  local py="$GSCORE_VENV/bin/python"

  # ---------- 首选：uv sync（读 pyproject.toml + uv.lock，官方推荐方式）----------
  if [ -n "$UV_BIN" ] && [ -f "$GSCORE_DIR/pyproject.toml" ]; then
    uv_env
    export UV_PROJECT_ENVIRONMENT="$GSCORE_VENV"
    log "使用 uv sync 安装依赖（官方推荐，读 pyproject.toml + uv.lock）"
    if ( cd "$GSCORE_DIR" && "$UV_BIN" sync --no-dev --python "$GSCORE_VENV/bin/python" ); then
      unset UV_PROJECT_ENVIRONMENT
      return 0
    fi
    unset UV_PROJECT_ENVIRONMENT
    warn "uv sync 失败，退回 pip"
  fi

  # ---------- 兜底：pip，必须在 GsCore 目录下跑，并把 `-e .` 剔掉 ----------
  [ -f "$GSCORE_DIR/requirements.txt" ] || { err "GsCore 目录缺少 requirements.txt"; return 1; }
  local clean="$GSCORE_DIR/.requirements.noeditable.txt"
  grep -vE '^[[:space:]]*(-e[[:space:]]+)?\.[[:space:]]*$' \
    "$GSCORE_DIR/requirements.txt" > "$clean" || true
  info "pip 兜底：已生成 $clean（剔除「-e .」行）"

  if ! ( cd "$GSCORE_DIR" && pip_install "$GSCORE_VENV" -r "$clean" ); then
    return 1
  fi

  # 再把 gsuid-core 本体装上；装不上也不影响 `python -m gsuid_core.core` 运行
  if ( cd "$GSCORE_DIR" && "$py" -m pip install -e . --no-deps \
         --index-url "$PYPI_INDEX" --disable-pip-version-check >/dev/null 2>&1 ); then
    log "gsuid-core 本体已可编辑安装"
  else
    warn "gsuid-core 本体可编辑安装失败（不影响启动，可忽略）"
  fi
  return 0
}

setup_gscore() {
  log "安装 GsCore（业务核心，端口 $GSCORE_PORT）"
  mkdir -p "$GSCORE_DIR"

  if [ -f "$GSCORE_DIR/requirements.txt" ] && [ "$FORCE" != "1" ]; then
    if [ -d "$GSCORE_DIR/.git" ]; then
      info "GsCore 源码已存在，尝试 git pull 更新"
      timeout "${GIT_TIMEOUT:-300}" git -C "$GSCORE_DIR" \
        -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
        pull --ff-only --progress \
        || warn "git pull 失败/超时，继续使用现有代码（不影响启动）"
    else
      info "检测到已有 GsCore 源码（非 git 仓库），跳过拉取，直接装依赖"
    fi
  else
    log "获取 GsCore 源码（多源自动尝试，会显示进度）"
    if ! bash "$BASE_DIR/scripts/gscore-fetch.sh" "$GSCORE_DIR" "${GSCORE_SOURCE_OVERRIDE:-}"; then
      die "GsCore 源码获取失败。按上面的提示手动放进 $GSCORE_DIR 后重跑本脚本即可"
    fi
  fi

  [ -f "$GSCORE_DIR/requirements.txt" ] || die "GsCore 目录缺少 requirements.txt，源码可能不完整"

  local marker="$GSCORE_VENV/.botapp-deps-ok"
  ensure_venv "$GSCORE_VENV" "$GSCORE_PYTHON_VERSION" "${GSCORE_PYTHON_MIN:-3.12}"

  if [ -f "$marker" ] && [ "$FORCE" != "1" ]; then
    info "GsCore 依赖已安装过，跳过（加 --force 可重装）"
  else
    info "安装 GsCore 依赖（含 playwright/onnxruntime 等，总量几百 MB，慢是正常的）"
    install_gscore_deps || {
      err "GsCore 依赖安装失败。"
      err "  若报编译错误： apt-get install -y build-essential python3-dev"
      err "  若报 hash / pyproject 相关错误：见 README「依赖安装报错」一节"
      die "安装中断"
    }
    touch "$marker"
  fi

  mkdir -p "$GSCORE_DIR/data"
  log "GsCore 就绪：$GSCORE_DIR"
}

# =============================================================================
#  NoneBot2
# =============================================================================
# 反查桥接插件的真实模块名。
# 坑：发行包名和导入模块名不一样 —— nonebot-plugin-genshinuid 的模块叫 GenshinUID。
bridge_module() {
  local venv="$1"
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

# 安装 GsCore 桥接插件。这是链路的必需件，装不上第三段就永远断。
# PyPI 上没有的包（nonebot-plugin-gscore 实测 404）必须走 GitHub 源码安装。
install_bridge_plugin() {
  local venv="$NONEBOT_VENV" ok="" mod=""
  if mod="$(bridge_module "$venv")"; then
    info "桥接插件已就位（模块名：$mod）"
    return 0
  fi

  log "安装 GsCore 桥接插件（nonebot-plugin-genshinuid）"

  # 1) PyPI（走国内源）
  if [ -n "$UV_BIN" ]; then
    uv_env
    if ( cd "$NONEBOT_DIR" && "$UV_BIN" pip install --python "$venv/bin/python" nonebot-plugin-genshinuid ); then
      ok=1
    fi
  fi
  if [ -z "$ok" ]; then
    if pip_install "$venv" nonebot-plugin-genshinuid; then ok=1; fi
  fi

  # 2) GitHub 源码兜底
  if [ -z "$ok" ]; then
    warn "PyPI 安装失败，改从 GitHub 源码安装"
    local p url
    local repo="https://github.com/Genshin-bots/nonebot-plugin-genshinuid.git"
    for p in $GH_PROXY_LIST; do
      [ -n "$p" ] || continue
      url="git+https://$p/$repo"
      info "尝试：$url"
      if [ -n "$UV_BIN" ] && uv_env \
         && ( cd "$NONEBOT_DIR" && "$UV_BIN" pip install --python "$venv/bin/python" "$url" ); then
        ok=1; break
      fi
      if pip_install "$venv" "$url"; then ok=1; break; fi
    done
    if [ -z "$ok" ]; then
      url="git+https://github.com/Genshin-bots/nonebot-plugin-genshinuid.git"
      if ( cd "$NONEBOT_DIR" && "$venv/bin/python" -m pip install "$url" \
             --index-url "$PYPI_INDEX" --disable-pip-version-check ); then ok=1; fi
    fi
  fi

  # 3) 装完必须能反查到模块，否则算失败（不能只看 pip 返回码）
  if mod="$(bridge_module "$venv")"; then
    log "桥接插件安装成功，模块名：$mod"
    return 0
  fi

  err "桥接插件仍未就位。手动安装："
  err "  $(printf '%s' "$venv")/bin/python -m pip install nonebot-plugin-genshinuid -i $PYPI_INDEX"
  return 1
}
setup_nonebot() {
  log "安装 NoneBot2（端口 $NONEBOT_PORT）"
  mkdir -p "$NONEBOT_DIR/plugins"
  touch "$NONEBOT_DIR/plugins/.gitkeep"

  local marker="$NONEBOT_VENV/.botapp-deps-ok"
  ensure_venv "$NONEBOT_VENV" "$GSCORE_PYTHON_VERSION" "3.10"

  if [ -f "$marker" ] && [ "$FORCE" != "1" ]; then
    info "NoneBot2 依赖已安装过，跳过（加 --force 可重装）"
    # 但桥接插件是链路的必需件，而且历史版本会误写 marker 把它一起跳过，
    # 所以即使依赖跳过也要每次都确认一遍。
    install_bridge_plugin || warn "桥接插件没装上 → 执行： botctl plugin-install"
  else
    info "安装 NoneBot2 + OneBot V11 适配器 + GsCore 连接插件"
    local ok=0 pkgs=("nonebot2[fastapi]" "nonebot-adapter-onebot")
    if [ -n "$UV_BIN" ]; then
      uv_env
      if ( cd "$NONEBOT_DIR" && "$UV_BIN" pip install --python "$NONEBOT_VENV/bin/python" "${pkgs[@]}" ); then ok=1; fi
    fi
    [ "$ok" = "1" ] || pip_install "$NONEBOT_VENV" "${pkgs[@]}" || die "NoneBot2 安装失败"

    # GsCore 桥接插件是必需件，单独处理
    install_bridge_plugin

    # 只有桥接插件确实就位才写标记，否则下次会被误判成「已安装过」而跳过
    if bridge_module "$NONEBOT_VENV" >/dev/null 2>&1; then
      touch "$marker"
    else
      warn "桥接插件未就位，不写安装标记（下次跑 install.sh 会自动重试）"
    fi
  fi

  write_nonebot_env
  log "NoneBot2 就绪：$NONEBOT_DIR"
}

write_nonebot_env() {
  local envfile="$NONEBOT_DIR/.env"
  if [ -f "$envfile" ] && [ "$FORCE" != "1" ]; then
    info ".env 已存在，保留：$envfile"
    return 0
  fi
  [ -f "$envfile" ] && cp -a "$envfile" "$envfile.bak.$(date +%Y%m%d%H%M%S)"

  cat > "$envfile" <<EOF
# 由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# ------------------------------------------------------------------ 基础
DRIVER=~fastapi
HOST=0.0.0.0
PORT=$NONEBOT_PORT
LOG_LEVEL=INFO
SUPERUSERS=["123456789"]
NICKNAME=["早柚"]
COMMAND_START=["/", ""]

# ------------------------------------------------------------------ NapCat -> NoneBot2（反向 WS）
# 把下面这个 token 原样填到 NapCat WebUI 的「WebSocket 客户端」里；两处不一致会一直 403。
ONEBOT_ACCESS_TOKEN=$ONEBOT_ACCESS_TOKEN

# ------------------------------------------------------------------ NoneBot2 -> GsCore
# 同时写两套大小写，兼容官方插件（gsuid_core_*）与轻量插件（GSUID_CORE_*）。
gsuid_core_host=127.0.0.1
gsuid_core_port=$GSCORE_PORT
gsuid_core_botid=NoneBot2
gsuid_core_ws_token=$GSUID_CORE_WS_TOKEN
GSUID_CORE_HOST=127.0.0.1
GSUID_CORE_PORT=$GSCORE_PORT
GSUID_CORE_BOTID=NoneBot2
GSUID_CORE_WS_TOKEN=$GSUID_CORE_WS_TOKEN
EOF
  chmod 600 "$envfile"
  log "已生成 NoneBot2 配置：$envfile"
}

# =============================================================================
#  NapCat
# =============================================================================
# NapCat 的判据：存在可执行的 <目录>/opt/QQ/qq。
# 官方 rootless 安装把 LinuxQQ 解包到 $HOME/Napcat/opt/QQ，直接跑那个 qq；
# 千万不要用 `command -v napcat` 判断 —— 那是独立的 TUI 交互菜单，不是启动器。
napcat_qq_bin() {
  local d
  for d in "${NAPCAT_DIR:-}" "$HOME/Napcat" /root/Napcat /opt/Napcat; do
    [ -n "$d" ] || continue
    [ -x "$d/opt/QQ/qq" ] && { printf '%s' "$d/opt/QQ/qq"; return 0; }
  done
  return 1
}

install_napcat() {
  log "安装 NapCat（QQ 协议端，无 Docker / rootless 模式）"

  local qq=""
  if qq="$(napcat_qq_bin)" && [ "$FORCE" != "1" ]; then
    info "已检测到 NapCat：$qq"
    info "要强制重装加 --force（会重新下载 LinuxQQ 与 NapCat）"
  else
    if [ "$ASSUME_YES" != "1" ]; then
      cat <<EOF

  接下来会下载并执行 NapCat 官方安装脚本：
      $NAPCAT_INSTALLER_RAW

  它以 rootless 方式把 LinuxQQ + NapCat 装到 $HOME/Napcat（约 150MB），全程不用 Docker。

EOF
      read -r -p "  是否继续？[Y/n] " ans
      case "${ans:-Y}" in n|N) warn "已跳过 NapCat"; return 0 ;; esac
    fi

    # 必须在独立空目录里跑：安装脚本会往 CWD 下载 NapCat.Shell.zip 并解压出 ./NapCat，
    # 而且它发现有非空的 ./NapCat 就直接报错退出。
    local workdir="/tmp/napcat-install"
    rm -rf "$workdir"
    mkdir -p "$workdir"

    local installer="$workdir/napcat.sh"
    info "下载 NapCat 安装脚本"
    download_file "$NAPCAT_INSTALLER_RAW" "$installer" \
      || die "NapCat 安装脚本下载失败，检查网络或调整 config.conf 里的 GH_PROXY_LIST"

    local cli_flag="n"
    [ "$NAPCAT_INSTALL_CLI" = "yes" ] && cli_flag="y"

    local args=(--docker n --cli "$cli_flag" --proxy "$NAPCAT_PROXY_OPT")
    [ "$FORCE" = "1" ] && args+=(--force)

    log "执行： bash napcat.sh ${args[*]}   （工作目录 $workdir）"
    if ! ( cd "$workdir" && bash "$installer" "${args[@]}" ); then
      warn "安装脚本返回非 0，下面做一次结果校验"
    fi
  fi

  # ---------------- 校验安装结果，别只看返回码 ----------------
  if qq="$(napcat_qq_bin)"; then
    log "NapCat 就绪：$qq"
    info "配置目录：$(dirname "$qq")/resources/app/app_launcher/napcat/config"
    return 0
  fi

  warn "没有找到 $HOME/Napcat/opt/QQ/qq —— NapCat 没装上。"
  cat >&2 <<EOF

手动重装（整段复制执行）：
    rm -rf /tmp/napcat-install && mkdir -p /tmp/napcat-install && cd /tmp/napcat-install
    curl -fL --progress-bar -o napcat.sh \$NAPCAT_INSTALLER_RAW
    bash napcat.sh --docker n --cli n --proxy $NAPCAT_PROXY_OPT

装完确认这一行有输出：
    ls -la $HOME/Napcat/opt/QQ/qq
EOF
  return 1
}

# =============================================================================
#  主流程
# =============================================================================
main() {
  preflight
  apply_http_proxy

  log "准备目录：$BASE_DIR"
  mkdir -p "$ENV_DIR" "$APP_DIR" "$LOG_DIR" "$RUN_DIR"

  init_uv || warn "未启用 uv，将使用系统 Python + pip"

  # 只装/修 GsCore 桥接插件
  if [ "$ONLY_PLUGIN" = "1" ]; then
    ensure_venv "$NONEBOT_VENV" "$GSCORE_PYTHON_VERSION" "3.10"
    if install_bridge_plugin; then
      log "完成。重启 NoneBot2： ./botctl.sh restart nonebot"
      return 0
    fi
    die "桥接插件安装失败，按上面的提示处理"
  fi

  if [ "$ONEBOT_ACCESS_TOKEN" = "" ] || [ "$GSUID_CORE_WS_TOKEN" = "" ]; then
    info "生成随机令牌（可在 config.conf 中固定）"
    [ "$ONEBOT_ACCESS_TOKEN" = "" ] && ONEBOT_ACCESS_TOKEN="$(gen_token)"
    [ "$GSUID_CORE_WS_TOKEN" = "" ] && GSUID_CORE_WS_TOKEN="$(gen_token)"
  fi

  if [ "$SKIP_GSCORE" = "1" ] && [ "$SKIP_NONEBOT" = "1" ] && [ "$SKIP_NAPCAT" = "1" ]; then
    warn "所有组件都被 --skip-* 跳过了，不做任何安装"
  else
    install_apt_deps
  fi

  [ "$SKIP_GSCORE" = "1" ]  || setup_gscore
  [ "$SKIP_NONEBOT" = "1" ] || setup_nonebot
  if [ "$SKIP_NAPCAT" != "1" ]; then
    install_napcat || warn "NapCat 未就绪，一会儿 botctl start napcat 会失败，按上面的提示处理即可"
  fi

  # 渲染 systemd 单元
  if [ -f "$BASE_DIR/botctl.sh" ]; then
    bash "$BASE_DIR/botctl.sh" units >/dev/null 2>&1 || warn "systemd 单元生成失败，可稍后执行： botctl units"
  fi

  if [ "$AUTOSTART" = "1" ]; then
    bash "$BASE_DIR/botctl.sh" enable all || warn "配置开机自启失败，可稍后执行： botctl enable all"
  fi

  chmod +x "$BASE_DIR/botctl.sh" "$BASE_DIR/scripts/"*.sh 2>/dev/null

  # 生成 /usr/local/bin/botctl 命令。
  # 这里用「启动器脚本」而不是软链：从 Windows 传上来的 .sh 经常丢可执行位，
  # 软链一旦指向不可执行的目标就直接 Permission denied；启动器里用 bash 显式调用，
  # 目标有没有 x 位都能跑，也不受 sed -i 破坏软链之类的问题影响。
  if [ "$(id -u)" = "0" ] && [ -d /usr/local/bin ]; then
    # 先删掉可能存在的旧软链：否则下面的重定向会顺着软链把 botctl.sh 本身覆盖掉
    rm -f /usr/local/bin/botctl
    if cat > /usr/local/bin/botctl <<EOF
#!/usr/bin/env bash
exec bash "$BASE_DIR/botctl.sh" "\$@"
EOF
    then
      chmod +x /usr/local/bin/botctl
      log "已安装命令：/usr/local/bin/botctl"
    else
      warn "命令安装失败，可直接用 bash $BASE_DIR/botctl.sh"
    fi
  else
    info "非 root 环境，跳过命令安装；直接用 bash $BASE_DIR/botctl.sh"
  fi

  # 安装 Web 后台（纯标准库，装完就不用再 SSH 了）
  if [ "$SKIP_PANEL" != "1" ] && [ -f "$BASE_DIR/panel/panel.py" ]; then
    log "安装 Web 后台"
    bash "$BASE_DIR/botctl.sh" panel install \
      || warn "后台安装失败，可稍后执行： botctl panel install"
  fi

  # .env 可能是上一次安装留下的（write_nonebot_env 会保留旧文件），
  # 所以必须回读文件里的真实值，否则汇总会打印一个对不上的新 token，照着配必然 403。
  local _env_token
  _env_token="$(grep -E '^ONEBOT_ACCESS_TOKEN=' "$NONEBOT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$_env_token" ]; then
    ONEBOT_ACCESS_TOKEN="$_env_token"
  fi

  # Web 后台地址与密码（面板首次启动时自动生成）
  local panel_port panel_pwd panel_url
  panel_port="${PANEL_PORT:-10236}"
  panel_pwd=""
  if [ -f "$BASE_DIR/panel/panel.conf" ]; then
    panel_pwd="$(grep -E '^PANEL_PASSWORD=' "$BASE_DIR/panel/panel.conf" 2>/dev/null \
      | head -1 | cut -d= -f2- | tr -d '"')"
  fi

  local ip; ip="$(lan_ip)"
  panel_url="http://$ip:$panel_port"
  cat <<EOF

$(printf '%s' "$GRN")=================== 安装完成 ===================$(printf '%s' "$RST")

  ╔══════════════════════════════════════════════════════════════╗
  ║  Web 后台（以后所有操作都在这上面做，不用再 SSH）            ║
  ╚══════════════════════════════════════════════════════════════╝

     地址 : $panel_url
     密码 : $panel_pwd

  浏览器打开上面地址即可：查看/启停三个服务、看日志、拿 NapCat 令牌、
  GsCore 注册码、一键自检、公网隧道……全在网页上。

  忘记密码： botctl panel password          （改密码加参数）

  ───────────────────────────────────────────────────────────────
  安装目录     : $BASE_DIR
  GsCore       : $GSCORE_DIR
  NoneBot2     : $NONEBOT_DIR
  虚拟环境     : $ENV_DIR
  日志         : $LOG_DIR

  ── 三段连接关系 ───────────────────────────────────
  QQ  <->  NapCat($NAPCAT_WEBUI_PORT WebUI)  <->  NoneBot2($NONEBOT_PORT)  <->  GsCore($GSCORE_PORT)

  反向 WS 地址（填到 NapCat WebUI → 网络配置 → 新建 → WebSocket客户端）:
      ws://127.0.0.1:$NONEBOT_PORT/onebot/v11/ws
  对应 Token:
      $ONEBOT_ACCESS_TOKEN

  ── 下一步 ─────────────────────────────────────────
  1) 启动全部服务        : botctl start all
  2) 扫码登录 QQ         : botctl qr
  3) 写入 NapCat 网络配置（扫码登录后知道 QQ 号了再执行，把 123456789 换成你的 QQ 号）:
        botctl napcat-ws 123456789
     或直接打开 NapCat WebUI 手动填：
        http://$ip:$NAPCAT_WEBUI_PORT
  4) GsCore 网页控制台   : http://$ip:$GSCORE_PORT/app
  5) 配置开机自启        : botctl enable all
  6) 出问题时自检        : botctl doctor

  说明：如果提示 botctl: command not found，用完整路径调用即可：
        bash $BASE_DIR/botctl.sh status

EOF
}

main

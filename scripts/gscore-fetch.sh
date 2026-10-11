#!/usr/bin/env bash
# =============================================================================
#  GsCore 源码获取器
#  多源自动探测 + 超时保护 + 进度显示 + 压缩包兜底
#
#  用法：
#     bash scripts/gscore-fetch.sh <目标目录> [自定义源URL]
#
#  自定义源可以是：
#     * git 仓库地址（以 .git 结尾，或 git@ 开头）
#     * tar.gz 压缩包直链
#
#  相关配置在 config.conf：
#     GSCORE_REPO_CN / GSCORE_REPO / GSCORE_BRANCH
#     GSCORE_SOURCE_OVERRIDE / GH_PROXY_LIST / HTTP_PROXY_URL / GIT_TIMEOUT
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
_SELF_BASE="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE_DIR="$_SELF_BASE"
CONF_FILE="$BASE_DIR/config.conf"
if [ -f "$CONF_FILE" ]; then
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$CONF_FILE")
  BASE_DIR="${BASE_DIR:-$_SELF_BASE}"
fi

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s[·]%s %s\n' "$CYA" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; }

DEST="${1:-}"
EXTRA_SOURCE="${2:-}"
if [ -z "$DEST" ]; then
  err "用法： bash scripts/gscore-fetch.sh <目标目录> [自定义源URL]"
  exit 2
fi

# 脚本会 rm -rf 目标目录，这里先做一层安全校验
case "$DEST" in
  "/"|"/root"|"/home"|"/opt"|"/usr"|"/var"|"/etc"|"/boot"|"/vol1"|"/mnt"|"/tmp")
    err "拒绝操作危险路径：$DEST"
    exit 3
    ;;
esac
case "$DEST" in
  *gscore*|*/app/*) : ;;
  *) warn "目标目录里既没有 gscore 也不在 app/ 下，确认无误再继续：$DEST" ;;
esac
if [ "$(printf '%s' "$DEST" | tr -cd '/' | wc -c)" -lt 2 ]; then
  err "目标目录层级太浅（$DEST），为安全起见拒绝执行"
  exit 3
fi

GSCORE_REPO_CN="${GSCORE_REPO_CN:-https://cnb.cool/gscore-mirror/gsuid_core.git}"
GSCORE_REPO="${GSCORE_REPO:-https://github.com/Genshin-bots/gsuid_core.git}"
GSCORE_BRANCH="${GSCORE_BRANCH:-master}"
GSCORE_SOURCE_OVERRIDE="${GSCORE_SOURCE_OVERRIDE:-}"
GH_PROXY_LIST="${GH_PROXY_LIST:-}"
GIT_TIMEOUT="${GIT_TIMEOUT:-300}"
HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"

WORKING_PROXIES=()

apply_http_proxy() {
  [ -n "$HTTP_PROXY_URL" ] || return 0
  export http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" all_proxy="$HTTP_PROXY_URL"
  export HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" ALL_PROXY="$HTTP_PROXY_URL"
  export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="localhost,127.0.0.1,::1"
  info "已启用代理：$HTTP_PROXY_URL"
}

# ------------------------------------------------------------------ 两种拉取方式
git_attempt() {
  local url="$1"
  info "git clone（${GIT_TIMEOUT}s 超时，速度低于 1KB/s 持续 30s 会自动放弃）"
  info "  $url"
  rm -rf "$DEST"
  if timeout "$GIT_TIMEOUT" git \
        -c http.lowSpeedLimit=1000 \
        -c http.lowSpeedTime=30 \
        -c http.postBuffer=524288000 \
        clone --depth=1 --single-branch --progress "$url" "$DEST"; then
    if [ -f "$DEST/requirements.txt" ]; then
      log "源码就位：$DEST"
      return 0
    fi
    warn "clone 完成但没找到 requirements.txt，可能不是 GsCore 仓库"
  fi
  rm -rf "$DEST"
  return 1
}

tarball_attempt() {
  local url="$1" tmp
  info "下载压缩包（比 git clone 更抗丢包，且不受 .git 历史拖累）"
  info "  $url"
  tmp="$(mktemp -d)" || return 1
  if curl -fL --connect-timeout 15 --retry 2 --retry-delay 2 --progress-bar \
        -o "$tmp/src.tar.gz" "$url"; then
    :
  else
    warn "下载失败"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$DEST"
  if tar -xzf "$tmp/src.tar.gz" -C "$DEST" --strip-components=1 2>/dev/null \
     && [ -f "$DEST/requirements.txt" ]; then
    rm -rf "$tmp"
    log "源码就位：$DEST"
    return 0
  fi
  warn "解压后没找到 requirements.txt，换个源重试"
  rm -rf "$tmp"
  rm -rf "$DEST"
  return 1
}

# 统一入口：按 URL 形态自动选择拉取方式
fetch_from() {
  local url="$1"
  [ -n "$url" ] || return 1
  case "$url" in
    *.git|git@*) git_attempt "$url" ;;
    *)           tarball_attempt "$url" ;;
  esac
}

# ------------------------------------------------------------------ 探测可用加速节点
probe_proxies() {
  WORKING_PROXIES=()
  local tmpd p i=0 pids=() pid f
  tmpd="$(mktemp -d)" || return 0
  local probe_path="https://raw.githubusercontent.com/Genshin-bots/gsuid_core/master/pyproject.toml"

  for p in $GH_PROXY_LIST; do
    [ -n "$p" ] || continue
    i=$((i + 1))
    (
      if curl -fsS -m 8 -o /dev/null "$p/$probe_path" 2>/dev/null; then
        printf '%s' "$p" > "$tmpd/$i"
      fi
    ) &
    pids+=("$!")
  done

  for pid in ${pids[@]+"${pids[@]}"}; do
    wait "$pid" 2>/dev/null
  done

  for f in "$tmpd"/*; do
    [ -f "$f" ] && WORKING_PROXIES+=("$(cat "$f")")
  done
  rm -rf "$tmpd"
}

# ------------------------------------------------------------------ 主流程
main() {
  apply_http_proxy

  if [ -f "$DEST/requirements.txt" ]; then
    log "目标目录已有 GsCore 源码，跳过获取：$DEST"
    return 0
  fi
  mkdir -p "$(dirname "$DEST")"

  local src p tarball
  tarball="https://github.com/Genshin-bots/gsuid_core/archive/refs/heads/$GSCORE_BRANCH.tar.gz"

  # ---------- 0) 显式指定的源最优先 ----------
  for src in "$EXTRA_SOURCE" "$GSCORE_SOURCE_OVERRIDE"; do
    [ -n "$src" ] || continue
    log "尝试指定源：$src"
    fetch_from "$src" && return 0
    warn "指定源不可用：$src"
  done

  # ---------- 1) 国内镜像 ----------
  if [ -n "$GSCORE_REPO_CN" ]; then
    log "尝试国内镜像：$GSCORE_REPO_CN"
    git_attempt "$GSCORE_REPO_CN" && return 0
  fi

  # ---------- 2) GitHub 直连（配了 HTTP_PROXY_URL 的话这一步就够） ----------
  log "尝试 GitHub 直连"
  git_attempt "$GSCORE_REPO" && return 0

  # ---------- 3) 探测并逐个尝试加速节点 ----------
  log "逐个探测 GitHub 加速节点（最多 8 秒一个）"
  probe_proxies
  if [ "${#WORKING_PROXIES[@]}" -gt 0 ]; then
    info "探测通过：${WORKING_PROXIES[*]}"
  else
    warn "没有节点通过探测，仍会逐个硬试一遍"
  fi

  for p in ${WORKING_PROXIES[@]+"${WORKING_PROXIES[@]}"}; do
    fetch_from "$p/$GSCORE_REPO" && return 0
    fetch_from "$p/$tarball" && return 0
  done

  # ---------- 4) 其他兜底 ----------
  log "尝试 gitclone.com 与直连压缩包"
  git_attempt "https://gitclone.com/github.com/Genshin-bots/gsuid_core.git" && return 0
  tarball_attempt "$tarball" && return 0

  # ---------- 5) 把没探到的前缀再抡一遍压缩包 ----------
  for p in $GH_PROXY_LIST; do
    [ -n "$p" ] || continue
    tarball_attempt "$p/$tarball" && return 0
  done

  # ---------- 全挂了 ----------
  err "所有源都失败了。"
  cat >&2 <<EOF

手动任选一种，把源码放到：$DEST

  A) 你有代理：
       export HTTPS_PROXY=http://127.0.0.1:7890
       git clone --depth=1 $GSCORE_REPO "$DEST"

  B) 国内镜像（该仓库确认存在，81MB，慢但能用）：
       git clone --depth=1 $GSCORE_REPO_CN "$DEST"

  C) 用浏览器/下载器拿到压缩包再传上来：
       $tarball
       mkdir -p "$DEST" && tar -xzf gsuid_core-$GSCORE_BRANCH.tar.gz -C "$DEST" --strip-components=1

  D) 找到能用的加速前缀后直接指定：
       bash scripts/gscore-fetch.sh "$DEST" "https://能用的前缀/$tarball"

  放好后重跑 bash install.sh 即可（检测到源码会自动跳过拉取、直接装依赖）。
  也可以在 config.conf 里长期固定： GSCORE_SOURCE_OVERRIDE="..."
EOF
  return 1
}

main "$@"

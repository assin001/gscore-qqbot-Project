#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bot-app Web 后台。

设计目标：SSH 只用来安装，之后所有查看与管理都在网页上完成。

特点：
  * 纯 Python 标准库，不依赖任何第三方包，也不需要 venv（用系统 python3 跑）
  * 与 napcat / gscore / nonebot 三个 venv 完全解耦，它们的依赖怎么变都不影响后台
  * 前端单文件、无 CDN，内网离线可用

安全模型：
  * 所有 /api/* 必须登录，密码首次运行随机生成（存 panel/panel.conf，权限 600）
  * 只能触发【白名单里固定的命令】，不接受任意 shell，参数逐个校验
  * 登录失败 5 次封禁 15 分钟
  * 会话是签名令牌（无状态，重启不掉线）：局域网来源 30 天免登录，其余 12 小时
"""

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE_DIR = HERE.parent
BOTCTL = BASE_DIR / "botctl.sh"
CONFIG_CONF = BASE_DIR / "config.conf"
PANEL_CONF = HERE / "panel.conf"
INDEX_HTML = HERE / "index.html"
LOG_DIR = BASE_DIR / "logs"

VERSION = "1.0.0"

_CONF_RE = re.compile(
    r"""^\s*([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|'([^']*)'|([^\s#]*))"""
)


def read_conf(path: Path) -> dict:
    """解析 bash 风格的 KEY="value" 配置（忽略注释和行尾注释）。"""
    data: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return data
    for line in text.replace("\r\n", "\n").split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _CONF_RE.match(line)
        if not m:
            continue
        val = m.group(2)
        if val is None:
            val = m.group(3)
        if val is None:
            val = m.group(4)
        data[m.group(1)] = val or ""
    return data


CONF = read_conf(CONFIG_CONF)
PANEL_HOST = CONF.get("PANEL_HOST") or "0.0.0.0"
try:
    PANEL_PORT = int(CONF.get("PANEL_PORT") or "10236")
except ValueError:
    PANEL_PORT = 10236
GSCORE_PORT = CONF.get("GSCORE_PORT") or "8765"
NAPCAT_WEBUI_PORT = CONF.get("NAPCAT_WEBUI_PORT") or "6099"
NONEBOT_PORT = CONF.get("NONEBOT_PORT") or "8080"


def load_panel_conf() -> dict:
    return read_conf(PANEL_CONF)


def ensure_panel_conf() -> dict:
    """首次运行生成随机密码与会话密钥。"""
    conf = load_panel_conf()
    if conf.get("PANEL_PASSWORD") and conf.get("PANEL_SECRET"):
        return conf
    pwd = secrets.token_urlsafe(12)
    secret = secrets.token_hex(32)
    PANEL_CONF.parent.mkdir(parents=True, exist_ok=True)
    PANEL_CONF.write_text(
        "# bot-app Web 后台自身配置（首次运行自动生成）\n"
        "# 登录密码，改完执行 botctl panel restart 生效\n"
        f'PANEL_PASSWORD="{pwd}"\n'
        "# 会话签名密钥，别泄露\n"
        f'PANEL_SECRET="{secret}"\n',
        encoding="utf-8",
    )
    try:
        os.chmod(PANEL_CONF, 0o600)
    except OSError:
        pass
    return {"PANEL_PASSWORD": pwd, "PANEL_SECRET": secret}


PANEL = ensure_panel_conf()
PASSWORD = PANEL["PANEL_PASSWORD"]
SECRET = PANEL["PANEL_SECRET"]


def lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "127.0.0.1"


LAN_IP = lan_ip()

# --------------------------------------------------------------------------
#  NapCat WebUI 免密直达链接
#
#  NapCat 启动时会在 webui.json 里生成一个 token，URL 带上它就能免登录。
#  这里复刻 botctl napcat-token 的探测逻辑：先按 NAPCAT_DIR / 常见路径找
#  「可执行的 <目录>/opt/QQ/qq」，再读它旁边的 webui.json；读不到就退一步，
#  去启动日志里抓 /webui?token=xxx（NapCat 启动时会把它打进日志）。
#  结果缓存 30 秒，避免每次刷新总览都去扫盘。
# --------------------------------------------------------------------------
WEBUI_TOKEN_TTL = 30
_WEBUI_TOKEN_RE = re.compile(r"https?://[^\s]*/webui\?token=([^\s&\"']+)")
_webui_cache: dict = {"at": 0.0, "token": ""}


def napcat_home() -> Path | None:
    cands: list[Path] = []
    conf_dir = (CONF.get("NAPCAT_DIR") or "").strip()
    if conf_dir:
        cands.append(Path(conf_dir))
    cands.append(Path(os.path.expanduser("~")) / "Napcat")
    cands += [Path("/root/Napcat"), Path("/opt/Napcat")]
    if Path("/home").is_dir():
        cands += sorted(Path("/home").glob("*/Napcat"))
    for d in cands:
        qq = d / "opt/QQ/qq"
        # 从 Windows 传上来常丢可执行位，所以只要求文件存在
        if qq.is_file():
            return d
    return None


def _read_webui_token() -> str:
    home = napcat_home()
    if home is not None:
        cfg = home / "opt/QQ/resources/app/app_launcher/napcat/config/webui.json"
        try:
            data = json.loads(cfg.read_text(encoding="utf-8", errors="replace")) or {}
            tok = str(data.get("token") or "").strip()
            if tok:
                return tok
        except (OSError, ValueError):
            pass
    # 兜底：启动日志里的 .../webui?token=xxxxx
    for line in reversed(tail_file(LOG_DIR / "napcat.log", 200).split("\n")):
        m = _WEBUI_TOKEN_RE.search(line)
        if m:
            return m.group(1)
    return ""


def napcat_webui_token() -> str:
    now = time.time()
    if now - float(_webui_cache["at"]) < WEBUI_TOKEN_TTL:
        return str(_webui_cache["token"])
    try:
        tok = _read_webui_token()
    except Exception:  # noqa: BLE001
        tok = ""
    _webui_cache.update(at=now, token=tok)
    return tok


def napcat_webui_url() -> str:
    """带 token 的免密直达地址；读不到 token 就退回普通登录页地址。"""
    base = f"http://{LAN_IP}:{NAPCAT_WEBUI_PORT}"
    tok = napcat_webui_token()
    if not tok:
        return base
    return f"{base}/webui?token={urllib.parse.quote(tok, safe='')}"


# --------------------------------------------------------------------------
#  会话与登录限流
#
#  会话令牌是【无状态签名串】： "<过期时间戳>.<HMAC-SHA256>",
#  密钥即 panel.conf 里的 PANEL_SECRET。好处是面板/机器重启后老令牌依然有效，
#  局域网里的手机/电脑可以长期免登录（旧实现把会话放内存里，一重启就全部掉线）。
#
#  有效期：局域网来源 30 天，其余 12 小时。cookie 同步带上 Max-Age，
#  这样关掉浏览器再打开也还在。
# --------------------------------------------------------------------------
SESSION_TTL = 12 * 3600            # 普通（非局域网）会话有效期：12 小时
LAN_SESSION_TTL = 30 * 24 * 3600   # 局域网会话有效期：30 天免登录

_sess_lock = threading.Lock()
_revoked: dict[str, float] = {}    # 已登出的令牌 -> 原始过期时间（到期自动清理）

_LAN_NETS = tuple(ipaddress.ip_network(n) for n in (
    "127.0.0.0/8",       # 本机回环
    "10.0.0.0/8",        # 私有网段
    "172.16.0.0/12",     # 私有网段
    "192.168.0.0/16",    # 私有网段，例如 192.168.1.1 / 192.168.1.20
    "169.254.0.0/16",    # 链路本地
    "::1/128",           # IPv6 回环
    "fc00::/7",          # IPv6 唯一本地地址
    "fe80::/10",         # IPv6 链路本地
))

_fail: dict[str, list] = {}
_fail_lock = threading.Lock()
MAX_FAIL = 5
BAN_SECONDS = 900


def _parse_ip(ip: str):
    host = (ip or "").strip()
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if "%" in host:                      # 去掉 IPv6 的 scope id，如 fe80::1%eth0
        host = host.split("%", 1)[0]
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        return None


def is_lan_ip(ip: str) -> bool:
    """来源 IP 是否属于局域网/本机（兼容 ::ffff:192.168.1.20 这类映射地址）。"""
    addr = _parse_ip(ip)
    if addr is None:
        return False
    mapped = getattr(addr, "ipv4_mapped", None)  # ::ffff:a.b.c.d
    if mapped is not None:
        addr = mapped
    return any(addr in net for net in _LAN_NETS)


def is_loopback_ip(ip: str) -> bool:
    addr = _parse_ip(ip)
    if addr is None:
        return False
    mapped = getattr(addr, "ipv4_mapped", None)
    if mapped is not None:
        addr = mapped
    return addr.is_loopback


def session_ttl_for(ip: str) -> int:
    """局域网给 30 天，其它来源给 12 小时。"""
    return LAN_SESSION_TTL if is_lan_ip(ip) else SESSION_TTL


def _sess_sign(exp: int) -> str:
    return hmac.new(SECRET.encode("utf-8"),
                    str(exp).encode("utf-8"), hashlib.sha256).hexdigest()


def new_session(ttl: int = SESSION_TTL) -> str:
    exp = int(time.time()) + max(60, int(ttl))
    return f"{exp}.{_sess_sign(exp)}"


def session_ok(tok: str | None) -> bool:
    if not tok:
        return False
    exp_s, _, sig = tok.partition(".")
    if not exp_s.isdigit() or not sig:
        return False
    exp = int(exp_s)
    if exp < time.time():
        return False
    if not hmac.compare_digest(sig, _sess_sign(exp)):
        return False
    with _sess_lock:
        return tok not in _revoked


def drop_session(tok: str | None) -> None:
    if not tok:
        return
    exp_s, _, sig = tok.partition(".")
    if not exp_s.isdigit() or not sig:
        return
    now = time.time()
    exp = int(exp_s)
    with _sess_lock:
        if exp > now:
            _revoked[tok] = exp
        # 顺手清理已经自然过期的登出记录，避免无限增长
        for key in [k for k, v in _revoked.items() if v < now]:
            _revoked.pop(key, None)


def login_blocked(ip: str) -> int:
    with _fail_lock:
        cnt, until = _fail.get(ip, [0, 0.0])
        if until > time.time():
            return int(until - time.time()) + 1
    return 0


def login_fail(ip: str) -> None:
    with _fail_lock:
        cnt, _ = _fail.get(ip, [0, 0.0])
        cnt += 1
        if cnt >= MAX_FAIL:
            _fail[ip] = [0, time.time() + BAN_SECONDS]
        else:
            _fail[ip] = [cnt, 0.0]


def login_ok(ip: str) -> None:
    with _fail_lock:
        _fail.pop(ip, None)


# --------------------------------------------------------------------------
#  命令白名单：Web 端只能触发这些，参数逐个校验，不给任意 shell
# --------------------------------------------------------------------------
SERVICES = ("napcat", "gscore", "nonebot", "all")
EXPOSE_SUBS = ("status", "start", "stop", "url", "install", "named", "log")
HOSTNAME_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?"
                         r"(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9._\-]{6,128}$")
# PyPI 包名规则：字母数字开头，可含 _ . -，且不能以分隔符结尾
PYDEP_PKG_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_.\-]{0,99}[A-Za-z0-9])?$")


def v_svc(args: list[str]) -> list[str]:
    a = (args[0] if args else "all").strip().lower()
    if a not in SERVICES:
        raise ValueError("服务名必须是 napcat / gscore / nonebot / all")
    return [a]


def v_log(args: list[str]) -> list[str]:
    svc = (args[0] if args else "nonebot").strip().lower()
    if svc not in SERVICES[:3]:
        raise ValueError("日志只支持 napcat / gscore / nonebot")
    n = (args[1] if len(args) > 1 else "200").strip()
    if not n.isdigit() or not (1 <= int(n) <= 5000):
        n = "200"
    return [svc, n]


def v_qq(args: list[str]) -> list[str]:
    qq = (args[0] if args else "").strip()
    if not qq.isdigit() or not (5 <= len(qq) <= 12):
        raise ValueError("QQ 号必须是 5~12 位数字")
    return [qq]


def v_token(args: list[str]) -> list[str]:
    t = (args[0] if args else "").strip()
    if not TOKEN_RE.match(t):
        raise ValueError("令牌只能是 6~128 位的字母数字和 . _ -")
    return [t]


def v_pydep_pkgs(args: list[str]) -> list[str]:
    """校验一批 PyPI 包名，去重保持原顺序。"""
    if not args:
        raise ValueError("至少给一个包名")
    seen: set[str] = set()
    out: list[str] = []
    for raw in args:
        s = str(raw).strip()
        # 把常见的 "foo>=1.0" 之类的版本说明剥掉，web 端只允许传纯包名
        for sep in (">=", "<=", "==", "!=", "~=", ">", "<"):
            if sep in s:
                s = s.split(sep, 1)[0].strip()
        if "[" in s:
            s = s.split("[", 1)[0].strip()
        if not PYDEP_PKG_RE.match(s):
            raise ValueError(f"非法的包名：{s!r}")
        key = s.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(s)
    return out


def v_expose(args: list[str]) -> list[str]:
    sub = (args[0] if args else "status").strip().lower()
    if sub not in EXPOSE_SUBS:
        raise ValueError("expose 子命令无效")
    out = [sub]
    if sub == "named":
        host = (args[1] if len(args) > 1 else "").strip().lower()
        host = host.replace("https://", "").replace("http://", "").strip("/")
        if not HOSTNAME_RE.match(host):
            raise ValueError("域名格式不对，例：nte.example.com")
        out.append(host)
    elif sub == "log":
        n = (args[1] if len(args) > 1 else "50").strip()
        out.append(n if n.isdigit() else "50")
    return out


# name -> (botctl 子命令, 参数校验器)
ACTIONS: dict[str, tuple[list[str], object]] = {
    "status":         (["status"], None),
    "doctor":         (["doctor"], None),
    "gscore-check":   (["gscore-check"], None),
    "gscore-config":  (["gscore-config"], None),
    "gscore-code":    (["gscore-code"], None),
    "gscore-host":    (["gscore-host"], None),
    "plugin-install": (["plugin-install"], None),
    "relink":         (["relink"], None),
    "fetch-gscore":   (["fetch-gscore"], None),
    "units":          (["units"], None),
    "ports":          (["ports"], None),
    "update":         (["update"], None),
    "qr":             (["qr"], None),
    "napcat-token":   (["napcat-token"], None),
    "start":          (["start"], v_svc),
    "stop":           (["stop"], v_svc),
    "restart":        (["restart"], v_svc),
    "enable":         (["enable"], v_svc),
    "disable":        (["disable"], v_svc),
    "log":            (["log"], v_log),
    "napcat-ws":      (["napcat-ws"], v_qq),
    "gscore-token":   (["gscore-token"], v_token),
    "expose":         (["expose"], v_expose),
    "gscore-rebuild": (["gscore-rebuild"], None),
    "pydep-check":    (["pydep"], None),
    "pydep-install":  (["pydep", "install", "gscore"], v_pydep_pkgs),
}


class Task:
    """一次 botctl 调用的输出缓冲，前端轮询增量读取。"""

    def __init__(self, action: str, argv: list[str]) -> None:
        self.id = secrets.token_hex(8)
        self.action = action
        self.argv = argv
        self.lines: list[str] = []
        self.done = False
        self.code: int | None = None
        self.started = time.time()
        self.lock = threading.Lock()

    def append(self, text: str) -> None:
        with self.lock:
            self.lines.append(text)
            # 防止长时间任务把内存吃满
            if len(self.lines) > 20000:
                del self.lines[:5000]

    def snapshot(self, after: int) -> dict:
        with self.lock:
            return {
                "id": self.id,
                "action": self.action,
                "done": self.done,
                "code": self.code,
                "total": len(self.lines),
                "lines": self.lines[after:],
            }


_tasks: dict[str, Task] = {}
_tasks_lock = threading.Lock()


def run_task(task: Task) -> None:
    env = dict(os.environ)
    env["BOTAPP_YES"] = "1"          # 让 botctl 里的交互确认自动通过
    env["TERM"] = env.get("TERM") or "xterm"
    env["LANG"] = env.get("LANG") or "C.UTF-8"
    env["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    try:
        proc = subprocess.Popen(  # noqa: S603
            ["bash", str(BOTCTL), *task.argv],
            cwd=str(BASE_DIR),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
    except Exception as exc:  # noqa: BLE001
        task.append(f"[panel] 启动失败：{exc}")
        with task.lock:
            task.done = True
            task.code = -1
        return

    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            task.append(line.rstrip("\n"))
    finally:
        proc.wait()
        with task.lock:
            task.done = True
            task.code = proc.returncode


def start_task(action: str, args: list[str]) -> Task:
    spec = ACTIONS.get(action)
    if spec is None:
        raise ValueError(f"不允许的操作：{action}")
    base, validator = spec
    extra = validator(args) if validator else []  # type: ignore[operator]
    argv = [*base, *extra]
    task = Task(action, argv)
    with _tasks_lock:
        _tasks[task.id] = task
        if len(_tasks) > 50:
            for key in sorted(_tasks, key=lambda k: _tasks[k].started)[:20]:
                if _tasks[key].done:
                    _tasks.pop(key, None)
    threading.Thread(target=run_task, args=(task,), daemon=True).start()
    return task


def tail_file(path: Path, lines: int) -> str:
    if not path.exists():
        return f"（日志文件还不存在：{path}）"
    try:
        with path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            block = min(size, 512 * 1024)
            fh.seek(size - block)
            data = fh.read()
        text = data.decode("utf-8", errors="replace")
        return "\n".join(text.split("\n")[-lines:])
    except OSError as exc:
        return f"（读取日志失败：{exc}）"


def botctl_json() -> dict:
    """取服务总览（复用 botctl 的判断逻辑，保证与命令行一致）。"""
    try:
        out = subprocess.run(  # noqa: S603
            ["bash", str(BOTCTL), "json"],
            cwd=str(BASE_DIR),
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "BOTAPP_YES": "1"},
        )
        return json.loads(out.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


# 抓 botctl pydep scan 输出的 @@pydep_json@@...@@pydep_json_end@@ 块
_PYDEP_JSON_RE = re.compile(r"@@pydep_json@@(.*?)@@pydep_json_end@@", re.S)
# 抓 @@pydep_err@@...@@ 块（botctl 端 excepthook 兜底写的 Python traceback）
_PYDEP_ERR_RE = re.compile(r"@@pydep_err@@(.*?)@@", re.S)


def botctl_pydep_scan(target: str = "gscore") -> dict:
    """调用 botctl pydep scan，从 botctl 写出的临时文件里解析结构化报告。

    botctl 命令自己会把 stdout+stderr tee 到 /tmp/.botapp-pydep.out
    （用一对哨兵标签包住 JSON）。panel 端先 unlink 这个 file（清掉旧数据），
    再启动 botctl 跑 scan —— botctl 内部 tee 会重建并写内容，**不在** 内部 rm，
    否则 panel 永远读到空。

    返回值是已经反序列化好的 dict，失败时是 {"error": ..., "stdout_tail": ..., "stderr_tail": ..., "pydep_err": ...}。
    """
    out_path = Path("/tmp/.botapp-pydep.out")
    err_path = Path("/tmp/.botapp-pydep.err")
    # 启动前先清掉两个临时文件，避免读到上次残留（注意 botctl 端不会再 rm，
    # 所以如果这里不 unlink，下次也会读到上次的尾巴）
    for p in (out_path, err_path):
        try:
            p.unlink()
        except OSError:
            pass

    try:
        proc = subprocess.run(  # noqa: S603
            ["bash", str(BOTCTL), "pydep", "scan", target],
            cwd=str(BASE_DIR),
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, "BOTAPP_YES": "1"},
        )
    except subprocess.TimeoutExpired:
        return {"error": "扫描超时（120 秒），插件目录可能很大或 I/O 慢"}
    except Exception as exc:  # noqa: BLE001
        return {"error": f"调用失败：{exc}"}

    # botctl 内部 tee 把 stdout+stderr 都写到了 out_path，优先从这里解析
    raw = ""
    if out_path.exists():
        try:
            raw = out_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            raw = ""
    if not raw:
        # 兜底：直接从 subprocess 捕获的 stdout 找（pipeline 末端 grep 过滤后只剩标签行）
        raw = proc.stdout or ""

    m = _PYDEP_JSON_RE.search(raw)
    if not m:
        # 没有 JSON 块：可能是 Python helper 出错（excepthook 写到了 @@pydep_err@@），
        # 把 traceback 解出来方便前端展示
        em = _PYDEP_ERR_RE.search(raw)
        pydep_err = ""
        if em:
            pydep_err = em.group(1).replace("\\n", "\n")[:3000]
        return {
            "error": "未拿到扫描报告（botctl 没输出 @@pydep_json@@ 块）",
            "stdout_tail": raw[-800:],
            "stderr_tail": (proc.stderr or "")[-600:],
            "pydep_err": pydep_err,
            "botctl_exit": proc.returncode,
        }
    try:
        data = json.loads(m.group(1))
    except (ValueError, UnicodeDecodeError) as exc:
        return {"error": f"扫描结果 JSON 解析失败：{exc}",
                "stdout_tail": raw[-800:],
                "botctl_exit": proc.returncode}
    # 拿到结果后才清理临时文件，保留到下次启动时再 unlink
    try:
        out_path.unlink()
    except OSError:
        pass
    return data


# --------------------------------------------------------------------------
#  HTTP
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "botapp-panel/" + VERSION
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        try:
            with (LOG_DIR / "panel.log").open("a", encoding="utf-8") as fh:
                fh.write("%s %s %s\n" % (time.strftime("%m-%d %H:%M:%S"), self.address_string(), fmt % args))
        except OSError:
            pass

    # ---------- 工具 ----------
    def _send(self, body: bytes, ctype: str, code: int = 200, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, val in (extra or {}).items():
            self.send_header(key, val)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code: int = 200, extra: dict | None = None) -> None:
        self._send(json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8", code, extra)

    def _auth(self) -> str | None:
        raw = self.headers.get("Cookie") or ""
        for part in raw.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "botapp_sid":
                return v
        return None

    def _client_ip(self) -> str:
        """判断「真实来源 IP」，用来决定会话有效期。

        直连时 socket 地址就是真实来源，一律不看请求头（防止伪造）。
        只有连接本身来自本机（127.0.0.1）时，才认为是 cloudflared 之类的反向代理，
        取它带来的来源地址 —— 否则公网隧道进来的请求会被误判成本机而拿到 30 天会话。
        """
        raw = self.client_address[0]
        if not is_loopback_ip(raw):
            return raw
        for header in ("CF-Connecting-IP", "X-Real-IP", "X-Forwarded-For"):
            val = self.headers.get(header)
            if val:
                return val.split(",")[0].strip()
        return raw

    def _require_login(self) -> bool:
        if session_ok(self._auth()):
            return True
        self._json({"error": "未登录"}, 401)
        return False

    def _body_json(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0 or length > 1024 * 1024:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8")) or {}
        except (ValueError, UnicodeDecodeError):
            return {}

    def _query(self) -> dict:
        _, _, qs = self.path.partition("?")
        return {k: v[0] for k, v in urllib.parse.parse_qs(qs).items()}

    # ---------- 路由 ----------
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]

        if path in ("/", "/index.html"):
            return self._page()

        if path == "/api/ping":
            return self._json({"ok": True, "version": VERSION, "authed": session_ok(self._auth())})

        if path == "/api/login-page":
            return self._page()

        if not self._require_login():
            return

        if path == "/api/overview":
            data = botctl_json()
            data["panel"] = {
                "url": f"http://{LAN_IP}:{PANEL_PORT}",
                "lan_ip": LAN_IP,
                # 带 token 的免密直达地址；没有 token 时退回普通地址
                "napcat_webui": napcat_webui_url(),
                "napcat_webui_base": f"http://{LAN_IP}:{NAPCAT_WEBUI_PORT}",
                "napcat_autologin": bool(napcat_webui_token()),
                "gscore_console": f"http://{LAN_IP}:{GSCORE_PORT}/app",
            }
            return self._json(data)

        if path == "/api/task":
            q = self._query()
            with _tasks_lock:
                task = _tasks.get(q.get("id", ""))
            if task is None:
                return self._json({"error": "任务不存在或已过期"}, 404)
            try:
                after = max(0, int(q.get("after", "0")))
            except ValueError:
                after = 0
            return self._json(task.snapshot(after))

        if path == "/api/log":
            q = self._query()
            svc = q.get("svc", "nonebot")
            if svc not in ("napcat", "gscore", "nonebot", "panel", "cloudflared"):
                return self._json({"error": "服务名无效"}, 400)
            try:
                n = min(max(int(q.get("lines", "200")), 1), 5000)
            except ValueError:
                n = 200
            return self._json({"text": tail_file(LOG_DIR / f"{svc}.log", n)})

        if path == "/api/pydeps":
            q = self._query()
            target = q.get("target", "gscore")
            if target not in ("gscore", "nonebot"):
                target = "gscore"
            return self._json(botctl_pydep_scan(target))

        return self._json({"error": "接口不存在"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        ip = self.client_address[0]

        if path == "/api/login":
            wait = login_blocked(ip)
            if wait:
                return self._json({"error": f"尝试过多，请 {wait} 秒后再试"}, 429)
            pwd = str(self._body_json().get("password") or "")
            if hmac.compare_digest(pwd, PASSWORD):
                login_ok(ip)
                src = self._client_ip()
                lan = is_lan_ip(src)
                ttl = session_ttl_for(src)
                tok = new_session(ttl)
                return self._json(
                    {"ok": True, "lan": lan, "ttl": ttl},
                    extra={"Set-Cookie":
                           f"botapp_sid={tok}; Path=/; HttpOnly; SameSite=Lax; Max-Age={ttl}"},
                )
            login_fail(ip)
            return self._json({"error": "密码错误"}, 401)

        if path == "/api/logout":
            drop_session(self._auth())
            return self._json({"ok": True},
                              extra={"Set-Cookie": "botapp_sid=; Path=/; Max-Age=0"})

        if not self._require_login():
            return

        if path == "/api/run":
            body = self._body_json()
            action = str(body.get("action") or "")
            args = body.get("args") or []
            if not isinstance(args, list):
                args = []
            try:
                task = start_task(action, [str(a) for a in args])
            except ValueError as exc:
                return self._json({"error": str(exc)}, 400)
            return self._json({"task": task.id, "argv": task.argv})

        return self._json({"error": "接口不存在"}, 404)

    def _page(self) -> None:
        try:
            html = INDEX_HTML.read_bytes()
        except OSError:
            html = b"<h1>index.html not found</h1>"
        self._send(html, "text/html; charset=utf-8")


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    httpd = ThreadingHTTPServer((PANEL_HOST, PANEL_PORT), Handler)
    httpd.daemon_threads = True
    print(f"bot-app 后台已启动")
    print(f"  地址   : http://{LAN_IP}:{PANEL_PORT}")
    print(f"  密码   : {PASSWORD}")
    print(f"  监听   : {PANEL_HOST}:{PANEL_PORT}")
    print(f"  配置文件: {PANEL_CONF}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

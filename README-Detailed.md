# bot-app —— fnOS 上的 QQ 机器人全套（NapCat + GsCore + NoneBot2，不用 Docker）

一套在飞牛 fnOS（Debian 系 + systemd）上**全进程方式**跑起来的 QQ 机器人环境：
虚拟环境隔离、依赖走国内源、带一个统一管理脚本（启停 / 状态 / 日志 / 开机自启 / 自检）。

```
QQ  ◄──►  NapCat (协议端, OneBot v11)  ◄──►  NoneBot2 (机器人框架)  ◄──►  GsCore (业务核心)
            WebUI :6099                      :8080 反向WS               :8765 + /app 控制台
                        └── ws://127.0.0.1:8080/onebot/v11/ws ──┘   └── ws://127.0.0.1:8765 ──┘
```

## 0. Web 后台：装完就不用再 SSH 了

`install.sh` 跑完会把**后台地址和密码**打印在最显眼的位置：

```
  ╔══════════════════════════════════════════════════════════════╗
  ║  Web 后台（以后所有操作都在这上面做，不用再 SSH）            ║
  ╚══════════════════════════════════════════════════════════════╝

     地址 : http://192.168.1.100:10236
     密码 : xxxxxxxxxxxx
```

浏览器打开就能做这些事，全程不用敲命令。**左侧边栏切换模块**：

| 模块 | 能干什么 |
|---|---|
| **总览** | 三服务状态 / PID / 端口监听情况，可单点启停；访问入口磁贴 |
| **服务管理** | 单个或批量启停重启、开关机自启、重新生成 systemd 单元、端口占用检查 |
| **NapCat** | 查看登录令牌、显示扫码二维码、填 QQ 号一键写入反向 WS 并重启 |
| **GsCore** | 取注册码、开放控制台到局域网、查看配置路径、控制台诊断、**一键修复 NoneBot 连接**、修复桥接插件、重新获取源码、重建依赖、**插件依赖检测与一键安装** |
| **会话令牌** | 一键对齐 GsCore 与 NoneBot2 的 WS_TOKEN；也解释 NapCat 侧两个 token 的区别 |
| **公网访问** | 安装 cloudflared、起临时隧道、建命名隧道、查看/停止 |
| **日志** | 选服务看最近若干行，可开 3 秒自动刷新（开关样式） |
| **运行输出** | 常用操作按钮（令牌 / 二维码 / 注册码 / 自检 / 端口检查 / 更新…）+ 命令实时回显；有任务在跑时侧边栏会有小圆点提示 |
| **维护** | 一键自检、服务总览、系统信息、更新、重新生成服务单元 |

右上角可切换**浅色 / 深色**主题，选择记在浏览器里。窄屏（手机 / 平板）下侧边栏会自动变成顶部横向标签。

**技术实现**（为什么这么设计）：

- **纯 Python 标准库**，不装任何第三方包，也不需要 venv —— 用系统 `python3` 直接跑
- **与三个服务的 venv 完全解耦**，它们依赖怎么变都影响不到后台
- 前端单文件、**零 CDN**（图标是内联 SVG），内网离线可用
- systemd 单元**刻意不依赖另外三个服务** —— 服务全挂了也能进后台操作
- 密码首次启动随机生成，存 `panel/panel.conf`（权限 600）；登录失败 5 次封 15 分钟
- 只能触发**白名单里固定的命令**，参数逐个校验（QQ 号必须数字、域名要过正则、令牌限字符集），不接受任意 shell

管理命令（万一后台起不来时用）：

```bash
botctl panel install            # 安装并启动（开机自启）
botctl panel status             # 状态 + 地址 + 密码
botctl panel password           # 查看密码；带参数则改密码并重启
botctl panel restart
botctl panel log 100
```

> 端口在 `config.conf` 的 `PANEL_PORT`（默认 **10236**，刻意避开 8888/8080 这类常用端口）。
> 改端口用 `botctl panel port 新端口`，会自动重启面板；也可以直接改 `config.conf` 后 `botctl panel restart`。
> 想只允许 NAS 本机访问就把 `PANEL_HOST` 改成 `"127.0.0.1"`。

## 1. 为什么之前 Docker 打不通

Docker 里 `127.0.0.1` 指的是**容器自己**，不是宿主机：
- NapCat 容器里的 `ws://127.0.0.1:8080/...` 会连到 NapCat 容器自身的 8080，自然连不上 NoneBot2；
- 要改用容器名（`ws://nonebot:8080/onebot/v11/ws`）并保证两个容器在同一个自定义网络里；
- NoneBot2 连 GsCore 同理，`gsuid_core_host` 不能写 `127.0.0.1`，得写容器名。

现在改成**全部本机进程**，三段连接都走 `127.0.0.1`，网络问题直接消失。

> 注意：GsCore 官方文档也提过——如果 GsCore 和 Bot 端**都在 Docker 里**，即使同机也必须配 token。走本机进程就不需要这套额外校验。

## 2. 目录结构

```
bot-app/
├── install.sh                  # 一键安装
├── botctl.sh                   # 统一管理脚本（重点）
├── config.conf                 # 全局配置：端口 / 令牌 / 国内源
├── panel/                      # Web 后台（纯标准库，零依赖）
│   ├── panel.py                # 后端
│   ├── index.html              # 前端（单文件、无 CDN）
│   └── panel.conf              # 自动生成的登录密码与会话密钥（权限 600）
├── app/
│   ├── gscore/                 # GsCore 源码（install.sh 自动 clone）
│   └── nonebot/                # NoneBot2 项目
│       ├── bot.py              # 入口，已注册 OneBot V11 + GsCore 桥接插件
│       ├── .env                # 安装时生成（带随机 token）
│       ├── .env.example        # 配置模板/备忘
│       └── plugins/            # 你自己的 NoneBot2 插件放这
├── env/
│   ├── gscore-venv/            # GsCore 虚拟环境
│   ├── nonebot-venv/           # NoneBot2 虚拟环境
│   └── uv-venv/                # 可选的 uv（只用来加速装依赖）
├── logs/                       # 三个服务的日志
├── run/                        # PID 文件（无 systemd 时使用）
└── scripts/napcat-wrapper.sh   # NapCat 无头启动包装（自动探测路径 + Xvfb）
```

## 3. fnOS 上的前置准备

1. 开启 SSH，用 root 登录（`sudo -i`）。
2. **把整个 `bot-app` 文件夹放到存储池**，不要放系统盘 —— venv 加起来好几 GB：
   ```bash
   mkdir -p /vol2/1000 && cd /vol2/1000
   # 用 WinSCP / SMB / scp 把 bot-app 传上来（下面统一以 /vol2/1000/QQbot 为例）
   cd /vol2/1000/QQbot && ls
   ```
3. 确认系统 Python 版本：
   ```bash
   python3 -V     # Debian 12 = 3.11，Debian 13 = 3.13
   ```
   GsCore 官方示例用 3.13。低于 3.11 的话不用担心，脚本会优先用 `uv` 自动下载 Python 3.13。

## 4. 安装

```bash
cd /vol2/1000/QQbot
chmod +x install.sh botctl.sh scripts/*.sh
bash install.sh
```

装完脚本会**自动**在 `/usr/local/bin/botctl` 生成一个启动器，之后可以直接敲 `botctl`。
万一没成功（比如不是 root），手动补一条：

```bash
printf '%s\n' '#!/usr/bin/env bash' 'exec bash /vol2/1000/QQbot/botctl.sh "$@"' > /usr/local/bin/botctl
chmod +x /usr/local/bin/botctl
```

> **为什么是启动器而不是软链**：从 Windows 传上来的 `.sh` 经常丢可执行位，软链一旦指向不可执行的文件就直接 `Permission denied`；启动器里是 `bash <路径>` 显式调用，目标有没有 x 位都能跑。
>
> 也不想装启动器的话，把所有命令里的 `botctl` 换成 `bash /vol2/1000/QQbot/botctl.sh` 即可。
>
> ⚠️ **每次从 Windows 重新传脚本后**，记得补一次可执行位（`botctl` 自己启动时也会自动补）：
> ```bash
> chmod +x /vol2/1000/QQbot/*.sh /vol2/1000/QQbot/scripts/*.sh
> ```

想一次性装完就开机自启：

```bash
bash install.sh --autostart
```

常用参数：`--skip-napcat` / `--skip-gscore` / `--skip-nonebot` / `--only-napcat` / `--force` / `-y`

> 脚本会下载并执行 NapCat 官方安装器（`--docker n`，装 LinuxQQ 无头版 + NapCat）。这是官方推荐的非 Docker 方式，会以 root 身份改系统。执行前你可以先看一眼：
> `curl -o /tmp/napcat.sh https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh`

## 5. 启动并打通三段链路

```bash
botctl start all          # 按 napcat -> gscore -> nonebot 顺序启动
botctl status             # 看总览
```

### ① 登录 QQ（NapCat）

```bash
botctl qr                 # 打印日志里的二维码链接/图片路径
```

最省事的做法是开 WebUI：`http://192.168.1.100:6099`（192.168.1.100 换成你 fnOS 的 IP），用 token 登录后在页面上直接扫码。

登录 token 一条命令就能拿到，它会顺带给你拼好带 token 的直达链接：

```bash
botctl napcat-token
#   [1] WebUI 登录 token   token = 3f2a...
#       免手填直达：http://192.168.1.100:6099/webui?token=3f2a...
```

> NapCat 有**两个** token，别搞混：
>
> | | ① WebUI 登录 token | ② 反向 WS token |
> |---|---|---|
> | 用途 | 登录 `:6099` 控制台 | NapCat 上报给 NoneBot2 |
> | 从哪来 | NapCat 自动生成 | `install.sh` 随机生成 |
> | 存放 | `NapCat/config/webui.json`（启动日志里也有一份） | `app/nonebot/.env` 的 `ONEBOT_ACCESS_TOKEN` |
>
> ① 打不开控制台时直接看配置文件：`cat 你的NapCat目录/config/webui.json`。
> ② 不需要去日志里找，用 `botctl napcat-token` 或 `grep ONEBOT_ACCESS_TOKEN app/nonebot/.env` 就有。
也可以在 NAS 上找到二维码图片拉下来扫：

```bash
botctl qr                 # 会给出 find 命令，直接复制执行
```

### ② 让 NapCat 把消息转给 NoneBot2

登录后知道 QQ 号了，一条命令搞定：

```bash
botctl napcat-ws 你的QQ号
botctl restart napcat
```

它会写入 `NapCat/config/onebot11_你的QQ号.json`，内容是：

```json
{
  "network": {
    "websocketClients": [
      {
        "name": "NoneBot2",
        "enable": true,
        "url": "ws://127.0.0.1:8080/onebot/v11/ws",
        "token": "改成与 .env 里 ONEBOT_ACCESS_TOKEN 完全相同的值",
        "messagePostFormat": "array",
        "heartInterval": 30000,
        "reconnectInterval": 3000
      }
    ]
  }
}
```

不想用命令就手动来：NapCat WebUI → **网络配置** → 新建 → **WebSocket 客户端** → URL 填 `ws://127.0.0.1:8080/onebot/v11/ws`，Token 从 `app/nonebot/.env` 里复制。
**两边 token 不一致就是经典的 403 连不上。**

### ③ 让 NoneBot2 连上 GsCore

`app/nonebot/.env` 里已经写好了：

```
gsuid_core_host=127.0.0.1
gsuid_core_port=8765
gsuid_core_botid=NoneBot2
gsuid_core_ws_token=            # 留空即可（同机直连不校验）；要开鉴权就填与 GsCore 的 WS_TOKEN 相同的值
```

默认 `GSUID_CORE_WS_TOKEN` 是**空的**，两边都空、同机直连即可通（这也是官方文档说的场景）。想加鉴权就：

```bash
# 在 config.conf 里给 GSUID_CORE_WS_TOKEN 填一个值，然后：
botctl gscore-host        # 自动写进 GsCore 的 data/config.json
botctl restart gscore
```

顺手把控制台开给局域网：

```bash
botctl gscore-host        # 把监听地址改成 0.0.0.0
botctl restart gscore
# 然后访问 http://192.168.1.100:8765/app（换成你 fnOS 的 IP）
```

> **GsCore 的配置字段全是大写**，而且 `HOST` 默认值是 `localhost` —— 意味着**只允许 NAS 本机访问**，局域网浏览器必然打不开控制台。这是最容易踩的一个坑。
>
> | 字段 | 说明 |
> |---|---|
> | `HOST` | **大写**。默认 `"localhost"`，改 `"0.0.0.0"` 才能局域网访问。填 `all` / `none` / `dual` / 空字符串等效于监听全部 |
> | `PORT` | **大写，且是字符串**（如 `"8765"`），不是整数 |
> | `ENABLE_HTTP` | **和网页控制台无关**。它只控制 `POST /api/send_msg` 这个 HTTP 发消息接口，默认 `false` 不用管 |
> | `WS_TOKEN` | ws 连接令牌；配合 `TRUSTED_IPS` 使用 |
> | `TRUSTED_IPS` | 默认只有 `localhost / ::1 / 127.0.0.1`。同机连接够用 |
> | `REGISTER_CODE` | 控制台注册码 |
>
> 另外 GsCore 的 `--host` / `--port` **命令行参数优先级高于配置文件**，本项目就是在启动命令里带上它们，所以 `config.conf` 里的 `GSCORE_HOST` / `GSCORE_PORT` 才是最终生效的值。

控制台首次使用需要**注册码**，一条命令打印（含控制台地址）：

```bash
botctl gscore-code
#   GsCore 控制台
#     控制台地址 : http://192.168.1.100:8765/app
#     注册码     : f225bed0e99765181e297b8b6c7f881b
#     配置文件   : /vol2/1000/QQbot/app/gscore/data/config.json

botctl gscore-code 我的新注册码     # 想换一个就带参数
```

想给 ws 连接加鉴权（两端必须一致，脚本会自动同步两边）：

```bash
botctl gscore-token 你的令牌
botctl restart gscore && botctl restart nonebot
```

### ④ 业务插件（原神/星铁/鸣潮查询等）

GsCore 的插件装在它自己那边：

```bash
cd app/gscore && source ../../env/gscore-venv/bin/activate
cd plugins 2>/dev/null || mkdir -p plugins
git clone -b v4 https://github.com/KimigaiiWuyi/GenshinUID.git --depth=1 --single-branch
deactivate
botctl restart gscore
```

或者直接在 GsCore 的网页控制台里装。

### ⑤ 配好主人 QQ

`app/nonebot/.env` 里的 `SUPERUSERS=["123456789"]` 改成你自己的 QQ 号，然后 `botctl restart nonebot`。
GsCore 控制台里也要设置一次「主人 QQ」（权限体系用）。

## 6. 管理脚本速查

直接敲 `botctl`（不带任何参数）会打印完整命令清单；在交互终端里还会附一个编号菜单，输入序号即可执行，回车退出。

```bash
botctl                        # 命令清单 + 编号菜单
botctl status                 # 总览：状态/PID/端口/监听/自启
botctl start|stop|restart all
botctl start|stop|restart nonebot     # 单服务：napcat / gscore / nonebot
botctl log nonebot 100        # 看最后 100 行
botctl log napcat -f          # 实时跟踪
botctl enable all             # 开机自启（systemd，崩溃自动重启）
botctl disable all
botctl units                  # 重新生成 systemd 单元（改了 config.conf 之后）
botctl doctor                 # 一键自检：venv/依赖/端口/令牌一致性/连通性
botctl qr                     # NapCat 二维码
botctl napcat-token           # 打印 NapCat 的两个 token（WebUI 登录 / 反向 WS）
botctl napcat-ws 123456789    # 写入反向 WS 配置（123456789 换成你的 QQ 号）
botctl gscore-host            # GsCore 监听 0.0.0.0
botctl gscore-config          # 打印 GsCore 配置路径与关键项
botctl gscore-code            # 打印控制台注册码（带参数则改成新值）
botctl gscore-token 你的令牌   # 同时对齐 GsCore 与 NoneBot2 的 WS_TOKEN
botctl relink                 # 修复 NoneBot2 -> GsCore 连接（控制台看不到 Bot 时用）
botctl fetch-gscore           # 只重新拉 GsCore 源码（多源自动探测，带进度条）
botctl pydep                  # 扫描插件 import 与 requirements.txt，列出缺失依赖
botctl pydep-install          # 全自动：重新扫描 -> 把缺的包一次装齐 -> 提示重启
botctl pydep-install pycryptodome Pillow   # 只装指定的几个包（自动走国内源 + 备用源）
botctl update                 # 更新 GsCore 源码 + NoneBot2 依赖
botctl uninstall              # 移除服务（保留源码和数据）
```

服务定位：`systemd` 可用就生成 `bot-napcat.service` / `bot-gscore.service` / `bot-nonebot.service`，日志同时写 `logs/*.log`；
没有 systemd（比如容器里的 fnOS）会自动退回 `nohup` + PID 文件，自启用 `cron @reboot`。

## 7. 配置文件要点（`config.conf`）

| 项 | 说明 |
|---|---|
| `BASE_DIR` | 留空 = 脚本所在目录。换盘请挪整个文件夹，别改这里 |
| `RUN_USER` | 服务运行用户，默认 root；降权要先 `chown -R` 整个目录 |
| `NONEBOT_PORT` / `GSCORE_PORT` / `NAPCAT_WEBUI_PORT` | 8080 / 8765 / 6099 |
| `GSCORE_HOST` | GsCore 监听地址，默认 `0.0.0.0`（局域网可开控制台）；改 `127.0.0.1` 则只限本机 |
| `ONEBOT_ACCESS_TOKEN` | NapCat ↔ NoneBot2；空则安装时随机生成 |
| `GSUID_CORE_WS_TOKEN` | NoneBot2 ↔ GsCore；默认空（同机直连不需要） |
| `PYPI_INDEX` / `PYPI_INDEX_FALLBACK` | 清华源 + 阿里/腾讯备用源 |
| `GH_PROXY_LIST` | GitHub 加速前缀，脚本会先并发探测哪些活着再优先用 |
| `HTTP_PROXY_URL` | **推荐填**：NAS 上本地代理（如 `http://127.0.0.1:7890`），比任何公共加速都稳 |
| `GIT_TIMEOUT` | 单次 git clone 超时秒数，超时/低速自动换下一个源 |
| `GSCORE_SOURCE_OVERRIDE` | 固定用某个 GsCore 源（git 地址或 tar.gz 直链） |
| `GSCORE_BRANCH` | GsCore 分支，默认 `master` |
| `GSCORE_PYTHON_MIN` | GsCore 要求的 Python 下限，默认 `3.12`（**3.11 会让控制台全 404**） |
| `PREFER_SYSTEM_PYTHON` | `yes`：系统 Python 满足下限就直接建 venv（免下解释器）；不满足则用 uv 下载 |
| `UV_PYTHON_INSTALL_MIRROR` | uv 下载 Python 的镜像，默认腾讯 cnb.cool 同步源 |
| `UV_ASTRAL_MIRROR_URL` | Astral 工具索引镜像，用不到可留空 |
| `USE_UV` | `auto` 优先用 uv（能自动下 Python 3.13），失败退回 pip |
| `GSCORE_PYTHON_VERSION` | uv 模式下要用的 Python 版本 |
| `NAPCAT_MODE` | `auto` 自动探测；找不到就用 `custom` + `NAPCAT_CUSTOM_CMD` |

改完 `config.conf` 后执行 `botctl units && botctl restart all`。

## 8. 常见问题

**拉 GsCore 卡住 / 一直没反应 / 报 timeout**

`bash install.sh` 拉源码时会依次尝试：指定源 → `cnb.cool` 国内镜像 → GitHub 直连 → 逐个探测可用的加速节点（git clone 或压缩包）→ 兜底源。每一步都会打印进度和超时信息。

```bash
# 只重拉源码，不动别的
botctl fetch-gscore

# 已经能上 GitHub（或本机有代理）的话，直接在 config.conf 里填代理，最省事
#   HTTP_PROXY_URL="http://127.0.0.1:7890"
```

全都失败时手动任选一种，把源码放进 `app/gscore`，再 `bash install.sh`（检测到源码会跳过拉取直接装依赖）：

```bash
rm -rf app/gscore

# A) 有代理
git clone --depth=1 https://github.com/Genshin-bots/gsuid_core.git app/gscore

# B) cnb 国内镜像（确认存在，仓库 80MB+，慢但能用）
git clone --depth=1 https://cnb.cool/gscore-mirror/gsuid_core.git app/gscore

# C) 压缩包（最抗丢包）—— 浏览器/下载器拿下来再传上去也行
curl -fL --progress-bar -o /tmp/gs.tar.gz \
  https://gh-proxy.com/https://github.com/Genshin-bots/gsuid_core/archive/refs/heads/master.tar.gz
mkdir -p app/gscore && tar -xzf /tmp/gs.tar.gz -C app/gscore --strip-components=1

# D) 找到能用的前缀后直接指定
bash scripts/gscore-fetch.sh app/gscore "https://能用的前缀/https://github.com/Genshin-bots/gsuid_core/archive/refs/heads/master.tar.gz"
```

> `app/gscore` 里只要能看到 `requirements.txt`、`pyproject.toml`、`gsuid_core/` 就算放对了。手动解压的没有 `.git`，`botctl update` 会跳过源码更新，这是正常的。

**卡在「准备 Python 3.13」不动了 / 拉完源码后就没输出了**

这是 **uv 在下载 Python 解释器**，走的是 GitHub Release（约 25MB），PyPI 镜像管不到这块，所以国内经常只有 100KB/s 左右。

```bash
# 看是不是卡在 uv 下载
ps aux | grep -E 'uv|python-build-standalone'

# 立刻绕开：换 cnb.cool 同步镜像（国内带宽很足）
export UV_PYTHON_INSTALL_MIRROR="https://cnb.cool/astral-sh/python-build-standalone/-/releases/download"

# 或者干脆不下解释器，用系统自带的
python3 -V                    # 确认 >= 3.11
rm -rf env/gscore-venv
python3 -m venv env/gscore-venv
bash install.sh               # venv 已存在，会直接跳过这步
```

config.conf 里默认 `PREFER_SYSTEM_PYTHON="yes"`，只要系统 Python ≥3.11 就不会再去下解释器。

> 顺带提醒：GsCore 的 Python 依赖本身有几百 MB（含 playwright、pillow 等），装依赖阶段比拉源码慢得多，属正常。pip / uv 会显示进度条，看到进度条在动就别慌。

**依赖安装报错：`cannot be installed when requiring hashes` / `does not appear to be a Python project`**

这是 GsCore 的 `requirements.txt` 的性质导致的，**不是网络问题，也不是镜像源问题，换源没用**。

那个文件是 `uv export --frozen` 自动生成的锁定清单，有两个特点：
1. 里面有一行 `-e .`（把 GsCore 自己作为可编辑包安装），`.` 是**按当前工作目录**解析的；
2. 每个包都带 `--hash=sha256:...`，会让 pip 自动进入 hash 校验模式，而该模式**不允许安装本地可编辑包**。

所以只要不在 `app/gscore` 目录里执行、或者用 pip 直接装整份清单，都会失败。

脚本现在这样处理：在 `app/gscore` 目录下执行，首选官方推荐的 `uv sync --no-dev`（读 `pyproject.toml` + `uv.lock`，不受上面两个问题影响）；万一 uv 不可用，退回 pip 并自动生成一份剔除了 `-e .` 的清单 `.requirements.noeditable.txt`，装完再把本体单独 `pip install -e . --no-deps` 补上。

手动救急（uv 方式，官方推荐）：

```bash
cd /vol2/1000/QQbot/app/gscore
UV_PROJECT_ENVIRONMENT=/vol2/1000/QQbot/env/gscore-venv \
UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
  /vol2/1000/QQbot/env/uv-venv/bin/uv sync --no-dev
```

手动救急（纯 pip 方式）：

```bash
cd /vol2/1000/QQbot/app/gscore
PIP=/vol2/1000/QQbot/env/gscore-venv/bin/python
grep -vE '^[[:space:]]*(-e[[:space:]]+)?\.[[:space:]]*$' requirements.txt > /tmp/req.txt
$PIP -m pip install -r /tmp/req.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
$PIP -m pip install -e . --no-deps -i https://pypi.tuna.tsinghua.edu.cn/simple
```

> 补充：GsCore 的 `pyproject.toml` 写的是 `requires-python = ">=3.11,<4.0"`，所以**系统 Python 3.11 就够了**，没必要非下 3.13。默认配置里 `PREFER_SYSTEM_PYTHON="yes"` 就是基于这一点。
>
> 另外这套依赖很重（含 onnxruntime / playwright / scikit-learn / qdrant-client），装完大约 1.5~2GB，整个 bot-app 目录最终 3~5GB，装在系统盘会写满，务必放存储池。

**`botctl status` 里 nonebot 一直起不来**
`botctl log nonebot 120`。最常见是 `.env` 语法问题（比如 `SUPERUSERS` 没写成 JSON 数组）。

**控制台提示"当前没有已连接的 Bot 实例"**

这是第三段链路（NoneBot2 → GsCore）没通。若两边进程都在跑、端口也都对，却始终看不到 Bot，**最常见的元凶是「启动时序」**：GsCore 启动要加载插件（约 15~30 秒）才会监听 8765，而桥接插件只在 NoneBot2 启动那一刻连一次，连不上就放弃、**不会自动重试**；systemd 的 `After=bot-gscore.service` 只保证 gscore 进程已启动、不保证它已就绪，所以每次重启都可能撞上这个空档。

一条命令就能修（也可以直接在 Web 后台 **GsCore → 诊断与修复 → 修复 NoneBot 连接**）：

```bash
botctl relink        # 等 gscore 就绪 -> 重启 nonebot 重新连接 -> 在日志里校验
```

如果 `relink` 之后仍连不上，再看 NoneBot2 日志：

```bash
botctl log nonebot 100
```

如果看到：

```
[ERROR] nonebot | Failed to import "nonebot_plugin_genshinuid"
ModuleNotFoundError: No module named 'nonebot_plugin_genshinuid'
```

**这是个包名陷阱，不是没装好。**

| | 名字 |
|---|---|
| 发行包名（pip / PyPI） | `nonebot-plugin-genshinuid` |
| **真实导入模块名** | **`GenshinUID`** |

源码在 `src/GenshinUID`，而 NoneBot 的 `load_plugin()` **只认模块名、不认发行包名**，所以写 `nonebot_plugin_genshinuid` 永远报 ModuleNotFoundError —— 即便包已经装好了。

另外 `nonebot-plugin-gscore`（我原先写的兜底）**在 PyPI 上是 404，压根没发布**，只能从 GitHub 源码装。

修复：

```bash
botctl plugin-install        # 等价于 bash install.sh --only-plugin
botctl restart nonebot
botctl gscore-check          # 看 [4] 那一段
```

本项目现在处理方式：
- `app/nonebot/bot.py` 用 `importlib.metadata.packages_distributions()` **反查真实模块名**再去加载，不再写死；
- `install.sh` 的桥接插件安装是「PyPI → GitHub 源码」双路径，装完**必须能反查到模块**才算成功；
- 只有插件确实就位才写 `.botapp-deps-ok` 标记 —— 以前会在插件安装失败时照样写标记，导致下次运行被"已安装过"跳过（这正是本项目踩过的坑）。

手动装（PyPI 没有时用源码）：

```bash
P=/vol2/1000/QQbot/env/nonebot-venv/bin/python
$P -m pip install nonebot-plugin-genshinuid -i https://pypi.tuna.tsinghua.edu.cn/simple
# 报 No matching distribution 就换：
$P -m pip install "git+https://github.com/Genshin-bots/nonebot-plugin-genshinuid.git"
```

**GsCore 装插件失败：`git clone ... GnuTLS recv error (-110)`**

GsCore 自己用 git 去 GitHub 拉插件（在控制台的插件市场里操作时），国内经常失败。两种修法：

```bash
# 方式一：给你 NAS 上的代理配上，然后重建单元让 GsCore 也走代理
#   config.conf 里填： HTTP_PROXY_URL="http://127.0.0.1:7890"
botctl units && botctl restart gscore

# 方式二：手动装（走加速前缀，自动重试）
botctl gscore-plugin https://github.com/tyql688/NTEUID.git
botctl restart gscore
```

插件目录在 `app/gscore/gsuid_core/plugins/`（注意它在源码包里面，不在仓库根目录）。

**GsCore 插件报 `No module named 'Crypto'` 之类**

插件自己的依赖没装上。GsCore 有自动装依赖的机制，但依赖源失败时不会重试。手动补：

```bash
/vol2/1000/QQbot/env/gscore-venv/bin/python -m pip install pycryptodome \
  -i https://pypi.tuna.tsinghua.edu.cn/simple
botctl restart gscore
```

（`Crypto` 模块由 `pycryptodome` 提供。其它 `No module named 'X'` 同理，装对应的包即可。）

如果搞不清每个插件各自缺什么，干脆用 Web 后台 **GsCore → 插件依赖检测与修复** 一键扫：

1. 点「开始扫描」→ 会读 `app/gscore/*/plugins/` 与 `app/nonebot/plugins/` 下所有插件的 `.py` 源码（提 `import`）和 `requirements.txt`；
2. 结果列表里会展示每个插件的「缺失依赖」「源码 import 推断」「requirements.txt 内容」；
3. 点「一键安装」按国内源 + 备用源装到 `env/gscore-venv`，逐行回显在「运行输出」里；
4. 装完点 `botctl restart gscore`（或先在面板里点「停 GsCore 后再装」）加载新依赖。

**扫描怎么判断"缺"**（避免误报的几层过滤）：

| 过滤 | 作用 |
|---|---|
| `sys.stdlib_module_names` | 标准库不算依赖 |
| 插件自有模块 | 插件 `import` 自己的包名/子模块（如 `GenshinUID`、`char_score`）不算缺 |
| `TEST_DIST` 黑名单 | `pytest` / `mock` / `coverage` 等测试框架不算缺 |
| `importlib.util.find_spec` **实测** | 把插件父目录加进 `sys.path` 后实测能否 import —— GsCore 自带的顶层模块（如 `gscore_mail`）能 import 到，就不算缺 |

命令行等价：

```bash
botctl pydep                                # 只扫描，列出缺失包（并打印可复制的安装命令）
botctl pydep-install                        # 全自动：重新扫描 → 一次装齐 → 提示重启
botctl pydep-install pycryptodome Pillow    # 只装指定的几个包
```

**安装是「整批 + 逐个兜底」**：先整批 `pip install` 一次解析依赖；如果这批里混了 PyPI 上不存在的包名（一般是扫描误报），整批会失败 —— 这时自动改为**逐个安装，跳过装不上的**，保证好包都装上，最后列出哪些装不上（可忽略）。

> 装之前建议**先停 GsCore**（面板里有「停 GsCore 后再装」），避免它在 pip install 期间启动时抓到半装好的状态、再去 import 失败。



**流量/接口 404 是正常的**

诊断里 `/api/system/version`、`/api/status`、`/openapi.json` 返回 404 属正常 —— 这些路径是我探测用的猜测值，GsCore 没有，`/docs`、`/openapi.json` 默认也是关闭的（要开得设环境变量 `GSUID_ENABLE_OPENAPI=1`）。

**能否直接用 `/api/version` 的状态码判断？**

- `401` → **路由已注册**，只是未登录（正常）
- `200` → 已注册且允许匿名访问
- `404` → **路由没注册**，这才是故障

**插件要一个"公网可访问的登录页"（例如 NTEUID 的登录）**

有些插件（如 NTEUID）的登录流程要在浏览器里打开一个由 Core 提供的页面。README 里的原话是"请确认 Core 的 Web 服务可以被浏览器访问"。判断按场景分：

| 谁要打开这个链接 | 需要什么 |
|---|---|
| 只有你自己，手机在家里 Wi-Fi | 填局域网地址即可：`http://192.168.1.100:8765` —— **不需要公网** |
| 只有你自己，人在外面 | Tailscale / ZeroTier（手机装客户端，最安全） |
| **群里其他人也要能打开** | **必须真公网**，私有网络方案全部排除 |

最后一种情况推荐 **Cloudflare Tunnel**：免费、自带 HTTPS、不需要公网 IP、不用在路由器上开端口。

```bash
botctl expose install      # 装 cloudflared（apt 官方源 -> 加速前缀 -> 直连，三层兜底）
botctl expose start        # 起隧道，直接打印公网地址
botctl expose status       # 再看一次地址
botctl expose stop
botctl expose log 50
```

拿到 `https://xxxx.trycloudflare.com` 之后，填到 **GsCore 控制台 → 插件 → NTEUID → 异环登录页面 URL**，然后 `botctl restart gscore`。

**Cloudflare Tunnel 的两种建法（都不需要 API Token）**

| | CLI 流程（`botctl expose named` 用这个） | 面板流程 |
|---|---|---|
| 认证 | `cloudflared tunnel login` 浏览器授权 → `~/.cloudflared/cert.pem` | Zero Trust 面板建隧道 → 得到一串 `TUNNEL_TOKEN` |
| 启动 | `config.yml` + `~/.cloudflared/<UUID>.json` | `cloudflared service install <TOKEN>` |
| 域名 | `cloudflared tunnel route dns` 命令 | 面板里配 Public Hostname |

`cert.pem` **只在你授权时选中的那个域名上有效**，用途仅限「创建隧道 / 加 DNS 记录」。隧道跑起来之后不再需要任何账号凭据 —— 运行时用的是 `<UUID>.json`，那是隧道自己的私钥，不是账号令牌。所以**授权一次，之后 cloudflared 运行多久都不会再碰你的 CF 账号**，改密码也不会断。

> ⚠️ `cloudflared tunnel --url` 是**临时隧道**，地址每次重启都会变，只适合验证。
> 长期使用要做**命名隧道**（需要把自己的域名托管到 Cloudflare）：
> ```bash
> cloudflared tunnel login
> cloudflared tunnel create nte
> cloudflared tunnel route dns nte nte.你的域名.com
> cloudflared service install      # 注册成系统服务，开机自启
> ```
> 没有域名就走 frp + 一台有公网 IP 的 VPS，把 8765 映射出去。

**⚠️ 安全提醒：隧道指向 8765 等于把整个 GsCore 控制台也暴露到公网了**

`/app` 里面有各游戏账号的登录凭证（CK/cookie）、用户绑定数据库、插件登录态。公网扫描器会找上门。至少要：

```bash
botctl gscore-token $(openssl rand -hex 16)   # ws 加鉴权
# 控制台账号设强密码；web_max_sessions 默认 1（单点登录）
```

更干净的做法是**本地加一层 nginx 只放行登录页路径**，隧道指向 nginx 而不是直接指向 8765。具体放行哪些路径，把机器人在群里发的登录链接的 URL 路径拿出来，照着写 location 规则即可。

**NapCat 连 NoneBot2 报 403**
token 不一致。执行 `botctl napcat-ws 123456789`（换成你的 QQ 号）对齐，再 `botctl restart napcat`。
也可以手动来：`botctl napcat-token` 会同时打印 WebUI 登录 token 和反向 WS token，把后者填进 NapCat WebUI 的网络配置里。

**打不开 NapCat WebUI / 不知道登录 token**
```bash
botctl napcat-token        # 推荐：直接给带 token 的直达链接

# 手动看（注意路径，不是 $HOME/Napcat/config/）
cat /root/Napcat/opt/QQ/resources/app/app_launcher/napcat/config/webui.json
grep -oE 'webui\?token=[^ ]+' /vol2/1000/QQbot/logs/napcat.log | tail -1
```
注意默认端口是 6099；被占用时 NapCat 会自动 +1，以 `webui.json` 里的 `port` 为准。

**GsCore 在运行，但网页控制台怎么都打不开**

99% 是 `HOST` 绑在了 `localhost`（GsCore 的默认值），只监听回环地址，局域网访问不到。

```bash
botctl gscore-config      # 查看 HOST / PORT / ENABLE_HTTP 当前值
botctl gscore-host        # 改成 0.0.0.0
botctl restart gscore
```

然后访问 `http://你的NAS的IP:8765/app`。

注意两个反直觉的点：
- 字段是**大写 `HOST`**，不是 `host`；
- `ENABLE_HTTP: false` **不影响**控制台，它只管 `POST /api/send_msg`，别去动它。

确认端口有没有真的监听上：

```bash
ss -ltnp | grep 8765        # 应该看到 0.0.0.0:8765
botctl log gscore 50
```

**控制台页面能打开，但所有内容都显示"加载失败"**

GsCore 的**前端 `dist` 和 API 路由是分开挂载的**：前端挂上了但 API 路由注册失败时，页面照样能显示，只是每个接口都报错。而 API 导入失败时 GsCore **只写日志、照常启动**，所以必须看日志。

**头号原因：GsCore 的虚拟环境用了 Python 3.11（必须 >= 3.12）**

GsCore 的控制台代码用 `typing.TypedDict` 做 FastAPI 的 `response_model`，而 pydantic 只在 **Python >= 3.12** 上支持 `typing.TypedDict`。在 3.11 上会抛：

```
PydanticUserError: Please use `typing_extensions.TypedDict` instead of
                   `typing.TypedDict` on Python < 3.12.
```

一个模块 import 失败 → `setup_frontend.py` 里 `from gsuid_core.webconsole import (...)` 整体失败 → **所有 `/api/*` 路由都没注册** → 页面能开、接口全 404。

> 注意：GsCore 的 `pyproject.toml` 写的是 `requires-python = ">=3.11,<4.0"`，但实际上 3.11 跑不了控制台。官方文档写 `uv python install 3.13` 是有原因的。

检查与修复：

```bash
# 看当前版本
/vol2/1000/QQbot/env/gscore-venv/bin/python -V

# 一键重建（会自动用 uv 下载 3.13 并重装依赖）
botctl gscore-rebuild
botctl restart gscore
botctl gscore-check
```

`config.conf` 里的 `GSCORE_PYTHON_MIN="3.12"` 控制这个下限；`install.sh` 检测到已存在的 venv 版本过低会**自动重建**。

**先跑诊断（一条命令把证据全抓出来）：**

```bash
botctl gscore-check
```

它会依次检查：

1. **`gsuid-core` 是否作为发行包装进了 venv** —— 这个最容易中招。如果当初依赖安装走了 pip 兜底路径（跳过项目本体），`importlib.metadata.version("gsuid-core")` 会抛 `PackageNotFoundError`，"加载版本信息失败"通常是它引起的
2. 端口有没有真的监听 `0.0.0.0:8765`
3. **从 NAS 本机 curl 各接口看真实状态码**（绕过浏览器）
4. 前端 `dist` 与 `version.json` 是否存在
5. 日志里的 `webconsole` / `dist_path` / `api_import` / `Traceback` 关键行

手动版等价命令：

```bash
curl -s -o /dev/null -w '/app -> %{http_code}\n' http://127.0.0.1:8765/app
for p in /api/version /api/system/version /api/status; do
  curl -s -o /dev/null -w "$p -> %{http_code}\n" "http://127.0.0.1:8765$p"
done
grep -inE 'webconsole|dist_path|api_import|Traceback' /vol2/1000/QQbot/logs/gscore.log | tail -30
```

判读：

| 现象 | 结论 |
|---|---|
| `/app` 返回 200，`/api/*` 全是 404 | API 路由没注册成功 → 看日志里的 traceback |
| 版本相关接口 500，其他正常 | `gsuid-core` 发行包没装 → 重跑 `uv sync` |
| `/app` 也不是 200 | 前端 `dist` 缺失或没挂载 → 看日志里 `dist_path` 那几行 |
| 全部 200，只有浏览器不行 | 浏览器缓存 / 前端版本错配 → 强刷（Ctrl+Shift+R）或清缓存 |

**GsCore 插件连不上，日志报 connection refused**
1. `botctl status` 看 gscore 是否运行、8765 是否在监听；
2. `botctl doctor` 会直接告诉你端口通不通；
3. 端口被占用：改 `config.conf` 里的 `GSCORE_PORT`，同步改 `.env` 的 `gsuid_core_port`。

**扫码页打不开 / 二维码看不到**
```bash
botctl qr                       # 会打印日志里的二维码链接和图片路径
find /root/Napcat -name '*qr*' -type f 2>/dev/null   # 路径按实际安装位置调整
```
或者直接开 WebUI `http://192.168.1.100:6099`（换成你 fnOS 的 IP）扫码（需要把 `NAPCAT_WEBUI_PORT` 在 fnOS 防火墙放通）。

**NapCat 启动就退出 / 日志里是 `TERM environment variable not set.` 然后 `已退出 NapcatShell`**

这说明它在跑 `/usr/local/bin/napcat`。**那不是启动器**，是独立的 **NapCat-TUI-CLI 交互式配置菜单**（另一个项目），需要终端；systemd 下没终端就秒退，然后被 `Restart=always` 反复拉起。

真正的启动方式（官方 rootless 安装）是直接跑 QQ：

```bash
xvfb-run -a /root/Napcat/opt/QQ/qq --no-sandbox
```

先确认安装是否完整：

```bash
ls -la /root/Napcat/opt/QQ/qq        # 这个文件存在才说明装好了
```

不存在就重装（`--cli n` 别装 TUI，用不上）：

```bash
apt-get install -y xvfb screen xauth jq unzip zip \
  libnss3 libgbm1 libasound2 libgtk-3-0 libatk1.0-0 libatspi2.0-0 libglib2.0-0 cpio rpm2cpio

rm -rf /tmp/napcat-install && mkdir -p /tmp/napcat-install && cd /tmp/napcat-install
curl -fL --progress-bar -o napcat.sh \
  https://gh-proxy.com/https://raw.githubusercontent.com/NapNeko/NapCat-Installer/main/script/install.sh
bash napcat.sh --docker n --cli n --proxy 1
```

QQ 起不来的常见原因就是缺运行库（`libnss3` / `libgbm1` / `libasound2` 这一批），`install.sh` 现在会自动装。

**NapCat 的目录结构（官方 rootless 安装，别按 Windows 版记）**

```
$HOME/Napcat/                                   ← 安装根目录（root 用户即 /root/Napcat）
├── opt/QQ/qq                                   ← 真正的可执行文件，启动跑这个
└── opt/QQ/resources/app/app_launcher/napcat/
    ├── config/webui.json                       ← WebUI 登录 token 在这
    ├── config/onebot11_<你的QQ号>.json          ← 反向 WS 配置在这
    └── napcat.mjs / ...
```

**没有 `napcat.sh`**，也没有 `$HOME/Napcat/config/`。如果你看到网上教程让你找 `napcat.sh`，那是 Windows 版或别的安装渠道。

卸载：`rm -rf $HOME/Napcat`，再删掉 `/usr/local/bin/*napcat*`（如果装了 TUI-CLI）。

**出图功能报错（缺浏览器内核）**
GsCore 渲染图片要 Playwright 的 Chromium：
```bash
cd app/gscore && source ../../env/gscore-venv/bin/activate
PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright playwright install chromium
deactivate && botctl restart gscore
```

**在 Windows 上编辑过脚本，传到 NAS 报 `\r: command not found`**
脚本自带 CRLF 自愈：第一次运行会自动 `sed -i 's/\r$//'` 自己并重新执行。手动处理也行：
```bash
sed -i 's/\r$//' *.sh scripts/*.sh config.conf
```

**磁盘写满**
把整个 `bot-app` 挪到存储池（见第 3 节），然后 `botctl units && botctl enable all`。

## 9. fnOS 特别注意

- fnOS 的系统盘通常不大，**一定要装在存储池**。
- 需要局域网访问的端口：`8080`（NoneBot2，可不开）、`8765`（GsCore 控制台）、`6099`（NapCat WebUI）。在 fnOS 的防火墙/端口设置里放通，否则手机扫码页打不开。
- 长时间无人值守建议 `botctl enable all`，三个服务都是 `Restart=always`，崩溃会自动拉起。
- QQ 客户端版本别乱升。NapCat 对 NTQQ 版本敏感，升级 QQ 前先备份 `NapCat` 目录。

## 10. 升级与卸载

```bash
botctl update                 # 更新 GsCore 源码和 NoneBot2 依赖
botctl restart all

botctl uninstall              # 停止服务 + 删除 systemd 单元（源码和数据都保留）
rm -rf /vol2/1000/QQbot       # 确认不要了再删
```

---

涉及第三方项目：NapCat(NapNeko/NapCatQQ)、GsCore(Genshin-bots/gsuid_core)、NoneBot2。
自动化登录 QQ 属于非官方客户端行为，存在账号风险，请自行评估。

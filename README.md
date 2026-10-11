# bot-app —— fnOS 上的 QQ 机器人一键部署（NapCat + GsCore + NoneBot2）

在飞牛 fnOS（Debian 系 + systemd）上**全进程方式**（不用 Docker）跑起一套完整的 QQ 机器人环境：
自动装好 NapCat / GsCore / NoneBot2，虚拟环境互相隔离、依赖走国内源，并附带一个零依赖的 Web 后台。

```
QQ ◄─► NapCat(OneBot v11) :6099 ◄─ws─► NoneBot2 :8080 ◄─ws─► GsCore :8765 + /app 控制台
```

## 快速开始

```bash
# 1. 把整个目录放到存储池（venv 加起来好几 GB，别放系统盘）
mkdir -p /vol2/1000 && cd /vol2/1000
# 用 WinSCP / SMB / scp 把 bot-app 传上来，然后：
cd /vol2/1000/QQbot
chmod +x install.sh botctl.sh scripts/*.sh

# 2. 一键安装（加 --autostart 则装完即开机自启）
bash install.sh

# 3. 启动
botctl start all
botctl status
```

装完终端会打印 **Web 后台地址 + 密码**（默认 `http://<NAS-IP>:10236`），之后所有操作都能在网页里完成。

## 装完这几步就通了

```bash
botctl qr                    # 显示二维码，登录 QQ
botctl napcat-ws 你的QQ号     # 把 NapCat 的消息转发到 NoneBot2（自动对齐 token）
botctl gscore-host           # 开放 GsCore 控制台到局域网
botctl gscore-code           # 打印控制台注册码
botctl relink                # 控制台看不到 Bot 时，一键修复连接
botctl doctor                # 一键自检：venv / 依赖 / 端口 / 令牌 / 连通性
```

再把 `app/nonebot/.env` 里的 `SUPERUSERS` 改成自己的 QQ 号，业务插件（GenshinUID 等）装在 GsCore 侧。

不带参数敲 `botctl` 会打印完整命令清单，交互终端里还附编号菜单。

## Web 后台

纯 Python 标准库实现，不装任何第三方包、不需要 venv，与三个服务的虚拟环境完全解耦；前端单文件、零 CDN（图标是内联 SVG），内网离线可用。

| 模块 | 能干什么 |
|---|---|
| 总览 / 服务管理 | 状态、PID、端口监听、启停重启、开机自启、端口占用检查 |
| NapCat | 登录令牌、扫码二维码、填 QQ 号一键写入反向 WS |
| GsCore | 注册码、开放控制台、连接诊断与一键修复、插件依赖扫描与一键安装 |
| 会话令牌 | 一键对齐 GsCore 与 NoneBot2 的 `ws_token` |
| 公网访问 | cloudflared 临时 / 命名隧道 |
| 日志 / 运行输出 / 维护 | 实时日志（可自动刷新）、命令回显、一键自检与更新 |

- 局域网内登录后 **30 天内免登录**（令牌为签名串，面板重启也不掉线）
- 密码首次启动随机生成，存 `panel/panel.conf`（权限 600），登录失败 5 次封禁 15 分钟
- 只能触发**白名单里固定的命令**，参数逐个校验，不接受任意 shell

## 目录结构

```
bot-app/
├── install.sh                  # 一键安装
├── botctl.sh                   # 统一管理脚本（启停 / 状态 / 日志 / 自检 / 更新）
├── config.conf                 # 全局配置：端口、令牌、国内源、Python 版本
├── panel/                      # Web 后台（panel.py + index.html）
├── app/                        # GsCore 源码 + NoneBot2 项目
│   └── nonebot/                # bot.py、.env.example、plugins/
├── env/                        # 各服务的虚拟环境（安装时生成）
├── logs/                       # 服务日志
└── scripts/                    # NapCat 无头启动包装、GsCore 源码多源拉取
```

## 环境要求

- 飞牛 fnOS，或其它 Debian 系 + systemd 的 Linux
- Python ≥ 3.11；**GsCore 网页控制台要求 Python ≥ 3.12**（低于此版本脚本会用 uv 自动下载 3.13）
- 装在存储池，整套约需 3~5 GB

## 文档

详细说明（设计原理、常见报错与排错、配置项逐条解释）见 **[README-Detailed.md](README-Detailed.md)**。

## 说明

涉及第三方项目：NapCat、GsCore（gsuid_core）、NoneBot2。
自动化登录 QQ 属于非官方客户端行为，存在账号风险，请自行评估。

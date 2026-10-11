"""NoneBot2 入口文件（bot-app 项目）。

整条链路：
    QQ  <->  NapCat(协议端, OneBot v11)  <->  NoneBot2(本进程)  <->  GsCore(业务核心)

启动顺序由 botctl 保证：napcat -> gscore -> nonebot
本文件可以随意修改，改完执行： botctl restart nonebot
"""

import importlib.metadata as md

import nonebot
from nonebot.adapters.onebot.v11 import Adapter as OneBotV11Adapter
from nonebot.log import logger

# 1) 初始化：会自动读取同目录下的 .env / .env.prod
nonebot.init()

# 2) 注册 OneBot V11 适配器（NapCat 走的就是这个协议）
driver = nonebot.get_driver()
driver.register_adapter(OneBotV11Adapter)

# =============================================================================
# 3) 加载 GsCore 桥接插件
#
# ⚠️ 这里有个大坑：**发行包名 ≠ 导入模块名**
#       pip / PyPI 名 : nonebot-plugin-genshinuid
#       真实模块名    : GenshinUID              ← 必须用这个
#   NoneBot 的 load_plugin() 只认「插件标识符」或「模块名」，不认发行包名，
#   写发行包名会一直报：ModuleNotFoundError: No module named 'nonebot_plugin_genshinuid'
#
#   所以这里用 importlib.metadata 反查真实模块名，而不是写死。
#   另外 nonebot-plugin-gscore 并没有发布到 PyPI（查过是 404），
#   它只在源码仓库里，脚本会用 git 方式安装。
# =============================================================================
_BRIDGE_DISTS = ("nonebot-plugin-genshinuid", "nonebot-plugin-gscore")


def _bridge_modules() -> list[str]:
    """按发行包名反查真实模块名。"""
    want = {d.lower().replace("_", "-") for d in _BRIDGE_DISTS}
    found: list[str] = []
    try:
        mapping = md.packages_distributions()
    except Exception as exc:  # noqa: BLE001
        logger.debug(f"packages_distributions 查询失败：{exc}")
        return found
    for module, dists in mapping.items():
        if any((d or "").lower().replace("_", "-") in want for d in dists):
            found.append(module)
    return found


# 顺序：反查到的真实模块名 -> 常见写死名
_candidates = _bridge_modules() + [
    "GenshinUID",
    "nonebot_plugin_genshinuid",
    "nonebot_plugin_gscore",
]

_loaded_name = ""
for _name in dict.fromkeys(_candidates):  # 去重且保持顺序
    try:
        nonebot.load_plugin(_name)
    except Exception as exc:  # noqa: BLE001
        logger.debug(f"load_plugin({_name}) 失败：{exc}")
        continue
    # load_plugin 失败时不会抛异常，只会返回 None 并打错误日志，所以必须回查
    if nonebot.get_plugin(_name):
        logger.success(f"已加载 GsCore 连接插件：{_name}")
        _loaded_name = _name
        break

if not _loaded_name:
    # 最后兜底：直接 import。至少让插件的 matcher 注册上，链路能通
    for _name in dict.fromkeys(_candidates):
        try:
            __import__(_name)
        except Exception:  # noqa: BLE001
            continue
        logger.warning(f"GsCore 桥接插件以「直接导入」方式加载：{_name}（未登记为 NoneBot 插件）")
        _loaded_name = _name
        break

if not _loaded_name:
    logger.error(
        "没有加载到任何 GsCore 连接插件，机器人只能响应本地插件。\n"
        "  排查： ./botctl.sh doctor\n"
        "  修复： ./botctl.sh plugin-install"
    )

# 4) 加载 plugins/ 目录下你自己的 NoneBot2 插件（可选，与 GsCore 无关）
try:
    nonebot.load_plugins("plugins")
except Exception as exc:  # noqa: BLE001
    logger.warning(f"加载本地 plugins/ 目录失败：{exc}")


if __name__ == "__main__":
    nonebot.run()

# 780EHM_PJ 功能宏（运行时请在 user/config.lua 同步修改）
#
# ========== RNDIS USB 网卡 ==========
# 1 = 开启：PC 经 USB 共享模组蜂窝上网（调试）
# 0 = 关闭：不启动 usb_rndis，可正常进低功耗 rest
RNDIS_ENABLE ?= 1
#
# config.lua 对应：
#   local RNDIS_ENABLE = 1
#   FEATURE_CFG.rndis = (RNDIS_ENABLE == 1)
#
# ========== FOTA ==========
# iot    = 合宙 IoT（需 main.lua PRODUCT_KEY）
# custom = 自建 OTA（需 FOTA_CFG.custom.url 或 MQTT 带 url）
FOTA_SERVER ?= iot
FOTA_CUSTOM_URL ?=
FOTA_CUSTOM_FULL_URL ?= 1
FOTA_CUSTOM_VERSION ?=

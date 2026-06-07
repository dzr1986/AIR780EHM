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

# ========== USB RNDIS 重枚举（T3x AT+USBRESET）==========
# 1 = 允许 T3x 发 AT+USBRESET 触发 usb_rndis.rebind
# 0 = 4G 回 +USBRESET:DISABLED
USB_REENUM_ENABLE ?= 1
#
# config.lua 对应：
#   local USB_REENUM_ENABLE = 1
#   FEATURE_CFG.usb_reenum = (USB_REENUM_ENABLE == 1)
#   HOST_USB_CFG.allow_t3x_usb_reset = ...

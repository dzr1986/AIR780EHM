# -*- coding: utf-8 -*-
# 注意：log 第一参勿用与 lib/*.lua 同名的字面量（如 "pir"），LuatTools 会误解析为 require 链
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def sub(path, pairs):
    p = ROOT / path
    s = p.read_text(encoding='utf-8')
    orig = s
    for a, b in pairs:
        s = s.replace(a, b)
    if s != orig:
        p.write_text(s, encoding='utf-8', newline='\n')
        print(f'updated {path} ({len(orig)-len(s)} bytes)')
    else:
        print(f'no change {path}')

p = ROOT / 'user/net_mqtt.lua'
s = p.read_text(encoding='utf-8')
if 'local L = "nm"' not in s:
    s = s.replace('local NC = "nc"\n', 'local NC = "nc"\nlocal L = "nm"\n')
s = s.replace('log.info("net_mqtt",', 'log.info(L,')
s = s.replace('log.warn("net_mqtt",', 'log.warn(L,')
s = s.replace('log.error("net_mqtt",', 'log.error(L,')
p.write_text(s, encoding='utf-8', newline='\n')
print('net_mqtt tag L')

sub('user/net_mqtt.lua', [
    ('"cellular bootstrap..."', '"cell"'),
    ('"wait IP_READY"', '"wIP"'),
    ('"wait net_ready / IP"', '"wnr"'),
    ('"+++++ imei=" .. tostring(id) .. " ++++++"', '"id", id'),
    ('"net_ready ok"', '"nrOK"'),
    ('"skip net_ready"', '"nrSk"'),
    ('"2001 wake"', '"d1"'),
    ('"2001 mid"', '"d1m"'),
    ('"2002 usb block rest"', '"d2u"'),
    ('"2002 enter rest"', '"d2in"'),
    ('"2002 exit rest"', '"d2out"'),
    ('"2002 bad"', '"d2?"'),
    ('"2003 interval ok"', '"d3ok"'),
    ('"2003 bad interval"', '"d3?"'),
    ('"2004 reboot"', '"d4rb"'),
    ('"2004 shutdown"', '"d4off"'),
    ('"2004 ota"', '"d4ota"'),
    ('"[2004] OTA bad ver"', '"d4ver"'),
    ('"2004 wled q"', '"d4wq"'),
    ('"2004 wled bad en"', '"d4we"'),
    ('"2004 wled"', '"d4w"'),
    ('"2004 bad act"', '"d4?"'),
    ('"2005 sim q"', '"d5"'),
    ('"2005 mid"', '"d5m"'),
    ('"host q in"', '"hq+"'),
    ('"host q out"', '"hq-"'),
    ('"2006 id q"', '"d6"'),
    ('"2006 mid"', '"d6m"'),
    ('"2007 tf disabled"', '"d7off"'),
    ('"2007 tf query timeout"', '"d7to"'),
    ('"2007 tf q"', '"d7"'),
    ('"2007 mid"', '"d7m"'),
    ('"2010 pir q"', '"d10q"'),
    ('"2010 no cfg"', '"d10?"'),
    ('"2011 stop mid"', '"d11m"'),
    ('"2011 cloud stop"', '"d11s"'),
    ('"json parse fail:"', '"jsonE"'),
    ('"unknown dataType"', '"dt?"'),
    ('"no dataType"', '"noDT"'),
    ('"cfg updated"', '"cfg"'),
    ('"cell not ready, try mqtt"', '"cell?"'),
    ('"conn timeout 90s, autoreconn"', '"to90"'),
    ('"no conn, raw fail"', '"ncR"'),
    ('"rest reconn -> 1002+1003"', '"rc23"'),
    ('"dup 1011"', '"11dup"'),
    ('"no adapter, may fail"', '"noadp"'),
    ('"conn ok"', '"ok"'),
    ('"mqtt start"', '"ms"'),
    ('"net start"', '"ns"'),
    ('"mqtt stop"', '"mstop"'),
    ('"restarting"', '"rst"'),
    ('log = "pub 1001"', 'log = "p1"'),
    ('log = "pub 1002"', 'log = "p2"'),
    ('log = "pub 1003"', 'log = "p3"'),
    ('log = "pub 1004"', 'log = "p4"'),
    ('log = "pub 1005"', 'log = "p5"'),
    ('log = "pub 1006"', 'log = "p6"'),
    ('log = "pub 1007"', 'log = "p7"'),
    ('log = "pub ota"', 'log = "po"'),
    ('log = "pub"', 'log = "p"'),
])

sub('user/host_uart.lua', [
    ('local LOG_TAG = "host_uart"', 'local LOG_TAG = "hu"'),
    ('"pending HOSTEVT"', '"pevt"'),
    ('"SERVCREATE disabled, wakeup_mode=mqtt"', '"scDis"'),
    ('"hostidle usb block"', '"hiUsb"'),
    ('"T3x RECORD active"', '"rec+"'),
    ('"T3x RECORD stop"', '"rec-"'),
    ('"T3x PERSONCNT"', '"pcnt"'),
    ('"T3x SNAPSHOT"', '"snap"'),
    ('"lowp usb block"', '"lpUsb"'),
    ('"wled no pwr"', '"wledNp"'),
    ('"USB recovery blocked: low_power_mode=1, T3x powered_off"', '"usbBlk"'),
    ('"1st AT"', '"1st"'),
    ('"host link reset"', '"lrst"'),
    ('"ipcst no rsp"', '"ipcn"'),
    ('"ipcoff busy"', '"ioB"'),
    ('"ipcoff no uart"', '"ioU"'),
    ('"ipcoff done"', '"ioD"'),
    ('"ipcoff timeout"', '"ioT"'),
    ('"ipcoff err"', '"ioE"'),
    ('"t3x powering off, wait ready"', '"pwOff"'),
    ('"t3x ready timeout"', '"rdyT"'),
    ('"rec q timeout"', '"rqT"'),
    ('"tf q timeout"', '"tfT"'),
    ('"PIR action=devinfo"', '"pirD"'),
    ('"notify_host skip"', '"nhSk"'),
    ('"pulse n/a"', '"pulN"'),
    ('"gb28181 timeout"', '"gbT"'),
    ('ok and "done" or "failed"', 'ok and "ok" or "ng"'),
    ('inserted and "block" or "allow"', 'inserted and "b" or "a"'),
    ('online and "on" or "off"', 'online and "1" or "0"'),
])

p = ROOT / 'user/app.lua'
s = p.read_text(encoding='utf-8')
if 'local L = "app"' not in s:
    s = s.replace('local E = APP_EVENTS\n', 'local L = "app"\nlocal E = APP_EVENTS\n')
s = s.replace('log.info("app",', 'log.info(L,')
s = s.replace('log.warn("app",', 'log.warn(L,')
s = s.replace('log.error("app",', 'log.error(L,')
s = s.replace('logBurnDebug("app",', 'logBurnDebug(L,')
p.write_text(s, encoding='utf-8', newline='\n')

sub('user/app.lua', [
    ('burnCheck("runtime.APP_RUNTIME.battery_percent"', 'burnCheck("batRt"'),
    ('"require fail"', '"rqF"'),
    ('"t3x wake req"', '"twk"'),
    ('"mqtt offline"', '"moff"'),
    ('"mqtt off, skip wake"', '"msk"'),
    ('"lp off, ignore enter"', '"lpXi"'),
    ('"usb, ignore rest"', '"uXr"'),
    ('"enter lp"', '"lp+"'),
    ('"exit lp"', '"lp-"'),
    ('"bad uart stack"', '"uart?"'),
    ('"net not ready, skip mqttcfg"', '"mcfg?"'),
    ('"mqttcfg unchanged, skip restart"', '"mcfg="'),
    ('"mqttcfg bad"', '"mcfg!"'),
    ('"t3x mqtt cfg"', '"mcfg"'),
    ('"mqtt t3x cfg"', '"mcfgOk"'),
    ('"uart line"', '"ux"'),
    ('"lp off, skip usb rest"', '"lpXu"'),
    ('"rndis, skip gpio rest"', '"rnX"'),
    ('"usb remove"', '"u-"'),
    ('"usb insert"', '"u+"'),
    ('"+++++ imei=" .. imei .. " ++++++"', '"id", imei'),
    ('"burn: skip mqtt"', '"bMqtt"'),
    ('"no mqtt cfg"', '"noCfg"'),
    ('"mqtt task on"', '"mOn"'),
    ('"mqtt flag off"', '"mOff"'),
    ('"no net mod"', '"noNet"'),
    ('"wait net_ready"', '"wnr"'),
    ('"net_ready OK"', '"nrOK"'),
    ('"net_ready timeout, try mqtt"', '"nrTo"'),
    ('"mqtt always-on start"', '"mAon"'),
    ('"mqtt already started"', '"mDup"'),
    ('"startMqtt fail"', '"mFail"'),
    ('"fota unavailable"', '"fota?"'),
    ('"fota 2004 hooked"', '"fota"'),
    ('"usb_rndis invalid"', '"rnd?"'),
    ('"rndis state"', '"rnd"'),
    ('"burn chk"', '"bC"'),
    ('"burn checks"', '"bChk"'),
    ('"burn cfg"', '"bCfg"'),
    ('"burn fail"', '"bFail"'),
    ('"burn stats"', '"bSt"'),
    ('"burn deny"', '"bDeny"'),
    ('"burn poll"', '"bPol"'),
    ('"burn retry"', '"bRet"'),
    ('"burn sum"', '"bSum"'),
    ('"burn allow"', '"bOk"'),
    ('"burn pass"', '"bPass"'),
    ('"burn t3xst"', '"bT3"'),
    ('"burn pins"', '"bPin"'),
    ('"stop for burn"', '"bStop"'),
    ('"rndis stopped preburn"', '"rnOff"'),
    ('"rndis stop fail preburn"', '"rnE"'),
    ('"burn mode gpio28"', '"bGo"'),
    ('"burn cond fail"', '"bCf"'),
    ('"bat ok"', '"bBat"'),
    ('"no t3x_ctrl"', '"noT3"'),
    ('"enterBoot fail"', '"bBoot"'),
    ('"burn seq start, wait coproc ready"', '"bSeq"'),
    ('"pir act"', '"pir"'),
    ('"rest, skip pir 1001"', '"pirX"'),
    ('"pir stop"', '"pir-"'),
    ('"t3x rec active, 1011 to t3x"', '"recT3"'),
    ('"pir media sync"', '"pirM"'),
    ('"req t3x stop rec"', '"stopT3"'),
    ('"t3x snap done"', '"snap"'),
    ('"t3x person cnt"', '"pcnt"'),
    ('"t3x rec end"', '"recE"'),
    ('"PIR GPIO"', '"pirG"'),
    ('"mqtt dl"', '"mdl"'),
    ('"mqtt pub wake"', '"mpw"'),
    ('"mqtt pub rest"', '"mpr"'),
    ('"ota st"', '"ota"'),
    ('"pwr short"', '"ps"'),
    ('"boot short"', '"bs"'),
    ('"usb, ignore 2002 rest"', '"u2X"'),
    ('"pwr long"', '"pl"'),
    ('"usb just inserted, ignore pwr long"', '"uPl"'),
    ('"boot long"', '"bl"'),
    ('"coproc ready"', '"cop"'),
    ('"burn end, pir resume"', '"bEnd"'),
    ('"usb, re-en rndis"', '"uRn"'),
    ('"lp off, no usb keep t3x"', '"lpT3"'),
    ('"app start ===="', '"go"'),
    ('"app ready ===="', '"rdy"'),
    ('"stack"', '"stk"'),
    ('string.format("[ALIVE #%d] USB=%d lowPwr=%d bat=%s mqtt=%s"', 'string.format("a%d u%d lp%d b%s m%s"'),
    ('failReason or "bat unknown"', 'failReason or "bat?"'),
    ('failReason or string.format("bat %d < %d", pct, minPct)', 'failReason or "batL"'),
    ('"need>=%d wait adc"', '"adcW"'),
    ('"req_valid=off"', '"rvOff"'),
    ('"will suspend"', '"susp"'),
    ('"no module"', '"noM"'),
    ('failReason or "no t3x_ctrl"', 'failReason or "noT3"'),
    ('"repeat allowed"', '"rpt"'),
    ('"already in boot"', '"inBoot"'),
    ('"not in boot"', '"okBoot"'),
    ('failReason or "in boot"', 'failReason or "boot"'),
])

sub('user/t3x_ctrl.lua', [
    ('local LOG_TAG = "t3x_ctrl"', 'local LOG_TAG = "t3x"'),
    ('"t3x_pwr_wake 未配置"', '"noPwr"'),
    ('"t3x_mcu_int 未配置"', '"noInt"'),
    ('"t3x_boot 未配置"', '"noBoot"'),
    ('"t3x_ota 未配置"', '"noOta"'),
    ('"========== T3x 控制模块启动 =========="', '"start"'),
    ('"========== T3x 控制模块启动完成 =========="', '"ready"'),
    ('"电源脚未初始化"', '"noPwrPin"'),
    ('"MCU_INT 未初始化"', '"noIntPin"'),
    ('"T3x 唤醒脉冲(低)"', '"wake"'),
    ('"电源脚未初始化，跳过断电"', '"noPwrOff"'),
    ('"进入 BOOT 模式"', '"boot+"'),
    ('"BOOT 模式失败：GPIO 未就绪"', '"bootFail"'),
    ('"USB_DEBUG_EN 未初始化"', '"noUsbEn"'),
    ('"USB_DEBUG_EN GPIO32 复位"', '"usbRst"'),
    ('"退出 BOOT：GPIO 未就绪"', '"bootX"'),
    ('"退出 BOOT 模式"', '"boot-"'),
    ('"已在休眠状态"', '"sleep"'),
    ('"HOSTEVT has_event，跳过 T3x 断电"', '"hevt"'),
    ('"========== 进入休眠 =========="', '"sleep+"'),
    ('"整模组 hibernate（MQTT 将断开）"', '"hib"'),
    ('"业务休眠：t3x 已断电，模组保持联网"', '"bizOff"'),
    ('"业务休眠：t3x 已处于断电"', '"bizIdle"'),
    ('"========== 唤醒设备 =========="', '"wake+"'),
    ('"唤醒原因:"', '"why"'),
    ('"========== 进入深度休眠 =========="', '"deep"'),
])

sub('lib/cellular_bootstrap.lua', [
    ('local LOG_TAG = "cellular"', 'local LOG_TAG = "cell"'),
    ('"imsi/iccid op mismatch"', '"opMm"'),
    ('"sim info timeout, try auto apn"', '"simTo"'),
    ('"unicom apn fb"', '"apnU"'),
    ('"s reset"', '"rst"'),
    ('"net fail"', '"netF"'),
    ('"setauto done"', '"auto"'),
    ('"have ip"', '"ip"'),
    ('"wait ip"', '"wIp"'),
])

sub('user/host_uart.lua', [
    ('"MQTTCFG"', '"mcfg"'),
    ('"SERVCREATE"', '"sc+"'),
    ('"SERVCLOSE"', '"sc-"'),
    ('"RIL"', '"ril"'),
    ('"gb28181"', '"gb"'),
    ('"started"', '"on"'),
    ('"stopped"', '"off"'),
    ('log.info(LOG_TAG, "wled", "AT+WLED=" .. on)', 'log.info(LOG_TAG, "wled", on)'),
])

sub('user/net_mqtt.lua', [
    ('"disconn"', '"dc"'),
    ('"idOff"', '"idX"'),
    ('"tf off"', '"d7X"'),
    ('"noHost"', '"noH"'),
    ('"noLib"', '"noL"'),
    ('"stopped"', '"off"'),
    ('"started"', '"dup"'),
    ('"ip to"', '"ipT"'),
])

sub('user/app.lua', [
    ('"reboot"', '"rb"'),
    ('"shutdown"', '"off"'),
    ('"pmd inited"', '"pmd"'),
    ('"wdt on"', '"wdt"'),
    ('"uart on"', '"ux"'),
    ('"no bat_adc, skip"', '"noBat"'),
    ('"no usb_charge, skip"', '"noChg"'),
    ('"noSntp"', '"noSn"'),
    ('"noMi"', '"noMi"'),
    ('passed and "ok" or "fail"', 'passed and "ok" or "ng"'),
])

sub('user/sound_prompt.lua', [
    ('local LOG_TAG = "sound_prompt"', 'local LOG_TAG = "snd"'),
    ('"uart_bridge 不可用，跳过"', '"noUb"'),
    ('"AT+PLAYSOUND"', '"play"'),
    ('"scene"', '"sc"'),
    ('"播放完成"', '"ok"'),
    ('"播放超时"', '"to"'),
    ('"等待 T3x +IPCSTATUS:ready"', '"wRd"'),
    ('"等待 T3x ready 超时，跳过开机音"', '"rdTo"'),
    ('"T3x ready"', '"rdy"'),
    ('"T3x 已发首条 AT"', '"1st"'),
    ('"等待 T3x 首条 AT"', '"w1st"'),
    ('"等待 T3x 首条 AT 超时，跳过开机音"', '"1stTo"'),
    ('"收到 T3x 首条 AT"', '"got1st"'),
])

sub('user/battery_guard.lua', [
    ('local LOG_TAG = "battery_guard"', 'local LOG_TAG = "batG"'),
    ('"config 缺少 BATTERY_CFG.guard."', '"cfg?"'),
    ('"PIR 已暂停（低电量）"', '"pir-"'),
    ('"PIR 已恢复"', '"pir+"'),
    ('"关机前检测到 USB 插入，取消关机"', '"usbXoff"'),
    ('"USB 插入，忽略低电量限制，保持 T3x 上电"', '"usb+"'),
    ('"USB 拔出，启用电量保护策略"', '"usb-"'),
    ('"已启动"', '"on"'),
    ('"% ≤ 休眠阈值，请求进 rest（app 上报 1002 + 断 T3x）"', '"≤rest"'),
    ('"% 已恢复，退出电量休眠并上电 T3x"', '">rest"'),
    ('"% ≤ 关机阈值，"', '"≤off"'),
    ('"s 后关机"', '"s off"'),
])

# pir_ctrl 勿改 log tag 为 "pir"（与 lib/pir.lua 冲突）；勿用独立 "ver" 字面量

sub('user/time_sync.lua', [
    ('"4G 时间无效，跳过推送"', '"tInv"'),
    ('"uart_bridge 不可用"', '"noUb"'),
    ('"AT+TIMESET"', '"ts"'),
    ('"TIMESET 超时"', '"tsTo"'),
    ('"TIMESET/唤醒跳过"', '"tsSk"'),
])

sub('user/main.lua', [
    ('"RNDIS taskInit(open)"', '"rnd+"'),
    ('"usb_rndis 不可用，跳过 RNDIS"', '"rnd?"'),
])

sub('lib/usb_rndis.lua', [
    ('local LOG_TAG = "usb_rndis"', 'local LOG_TAG = "rnd"'),
    ('"wait IP_READY"', '"wIP"'),
    ('"ip ok refresh rndis"', '"ipR"'),
    ('"rndis refreshed"', '"ref"'),
    ('"rndis on"', '"on"'),
    ('"rndis stop"', '"off"'),
    ('"switch ok"', '"sw"'),
    ('"rebind ok"', '"rb"'),
])

sub('lib/low_power_wakeup.lua', [
    ('"enter rest, keep tcp (mode=tcp)"', '"inT"'),
    ('"enter rest, close tcp (mode=mqtt)"', '"inM"'),
    ('"exit rest, restore tcp"', '"outT"'),
    ('"SERVCREATE blocked, mode=mqtt"', '"scB"'),
    ('"SERVCLOSE blocked, mode=mqtt"', '"scXB"'),
])

sub('lib/sntp_sync.lua', [
    ('log.info("sntpSync.trySync"', 'log.info("sntp"'),
    ('log.info("sntpSync"', 'log.info("sntp"'),
    ('log.warn("sntpSync"', 'log.warn("sntp"'),
    ('"sync ok"', '"ok"'),
    ('"server:"', '"srv"'),
    ('"unix:"', '"u"'),
    ('"sync timeout/fail, waiting retry..."', '"to"'),
])

sub('lib/libfota2.lua', [
    ('"http fota"', '"http"'),
    ('"need PRODUCT_KEY"', '"noPK"'),
    ('"version 无效"', '"ver?"'),
    ('"IoT version"', '"iot"'),
    ('"body"', '"b"'),
])

sub('lib/fota.lua', [
    ('"版本号错误"', '"ver?"'),
    ('"VERSION 须 xxx.yyy.zzz 或 IoT 版 内核.x.z"', '"fmt"'),
])

sub('lib/pir.lua', [
    ('"PIR_CFG 无效"', '"cfg?"'),
    ('"已启动"', '"on"'),
])

sub('lib/t3x_policy.lua', [
    ('"启动跳过 T3x 上电"', '"skipPwr"'),
])

sub('lib/uart_bridge.lua', [
    ('"UART_CFG 未定义"', '"noCfg"'),
    ('"UART_CFG.id 未配置"', '"noId"'),
    ('"UART_CFG.baud 未配置"', '"noBd"'),
    ('"UART_CFG.rx_line_max 未配置"', '"noRx"'),
])

sub('lib/adc_lib.lua', [
    ('log.info(LOG_TAG, "loaded -> _G.adcLib")\n', ''),
])

sub('user/led_ctrl.lua', [
    ('"no blue led"', '"noBl"'),
    ('"dual n/a, use single_blue"', '"1bl"'),
    ('"single_blue"', '"1bl"'),
])

sub('user/peripheral.lua', [
    ('"未知LED模式"', '"led?"'),
])

sub('lib/fota.lua', [
    ('"升级包下载成功,重启模块"', '"dlOK"'),
    ('"连接失败"', '"conn"'),
    ('"检查网络与 iot.openluat.com 可达性"', '"net?"'),
    ('"url错误"', '"url?"'),
    ('"合宙IoT拒绝或无新版本"', '"iotX"'),
    ('"请确认 IMEI 已加入项目、固件已上传且版本高于当前"', '"imei?"'),
    ('"接收报文错误"', '"rx?"'),
    ('"检查固件包或网络"', '"pkg?"'),
    ('"未知结果"', '"?"'),
    ('"升级进行中"', '"busy"'),
    ('"网络未就绪，跳过 OTA"', '"noNet"'),
    ('"IoT 配置无效"', '"cfg?"'),
    ('"开始检查升级"', '"chk"'),
    ('"libfota2.request"', '"req"'),
    ('"OTA 超时无回调"', '"to"'),
    ('"已启动"', '"on"'),
    ('"mode=合宙IoT"', '"iot"'),
    ('"PRODUCT_KEY"', '"pk"'),
])

sub('lib/uart_bridge.lua', [
    ('"行缓冲溢出，清空"', '"ovf"'),
    ('"已启动"', '"on"'),
    ('"已启用"', '"on"'),
    ('"已关闭"', '"off"'),
])

sub('lib/t3x_policy.lua', [
    ('"跳过唤醒"', '"skW"'),
])

sub('lib/watchdog.lua', [
    ('"当前固件无 wdt 库"', '"noWdt"'),
    ('"非 Air780 类 BSP，跳过模组 WDT"', '"noBsp"'),
    ('"Air780 模组 WDT 已启动"', '"on"'),
])

sub('user/main.lua', [
    ('"RNDIS"', '"rnd"'),
    ('"低功耗"', '"lp"'),
    ('"休眠查询"', '"hevt"'),
    ('"PIRSTAT.has_work 开"', '"1"'),
    ('"版本"', '"build"'),
    ('"core"', '"c"'),
    ('"project"', '"p"'),
    (' and "开" or "关"', ' and "1" or "0"'),
])

sub('user/time_sync.lua', [
    ('"SNTP 成功"', '"snOk"'),
])

sub('user/vbat.lua', [
    ('"start ch"', '"ch"'),
    ('"scale"', '"sc"'),
    ('"mV cell"', '"mv"'),
])

sub('user/t3x_ipc.lua', [
    ('"powerOnWaitReady 须在 task 内调用"', '"taskOnly"'),
])

print('all done')

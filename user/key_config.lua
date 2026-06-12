require "config"
module(..., package.seeall)
_G[_modname or (...)] = _M
local IN = _G.GPIO_IN or {}
local function pwrKeyPin()
    if gpio and gpio.PWR_KEY then
        return gpio.PWR_KEY
    end
    return IN.pwr_key and IN.pwr_key.pin
end
_G.KEY_CONFIG = {
    pwrkey = {
        pin = pwrKeyPin(),
        triggerMode = "both",
        pull = "pullup",
        debounce = 50,
        longPressMs = 3000,
        requireReleaseFirst = true,
        events = { short = "GPIO_PWRKEY_SHORT", long = "GPIO_PWRKEY_LONG" },
    },
    bootkey = {
        pin = IN.boot_key and IN.boot_key.pin,
        triggerMode = "both",
        pull = "pullup",
        debounce = 100,
        longPressMs = 2000,
        events = { short = "GPIO_BOOTKEY_SHORT", long = "GPIO_BOOTKEY_LONG" },
    },
    ready = {
        pin = IN.coproc_ready and IN.coproc_ready.pin,
        triggerMode = "rising",
        pull = "pulldown",
        debounce = 100,
        activeLevel = 1,
        event = "GPIO_COPROC_READY",
    },
}
return _M

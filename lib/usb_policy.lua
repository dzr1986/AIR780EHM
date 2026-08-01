require "usb_charge"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
isUsbInserted = usb_charge.isUsbInserted
blocksHostIdle = usb_charge.blocksHostIdle
blocks4gRest = usb_charge.blocks4gRest
mayEnterRest = usb_charge.mayEnterRest
return _M

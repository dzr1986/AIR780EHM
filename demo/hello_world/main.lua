--[[
@module  main
@summary Hello World demo 入口 / Hello World demo entry
@version 1.0
@date    2026.06.30
@usage
将本目录下的 main.lua 和 hello_luatos.lua 下载到模组即可运行。
]]

PROJECT = "AIR780EHM_hello_world"
VERSION = "001.999.001"

log.info("main", PROJECT, VERSION)

require "hello_luatos"

sys.run()

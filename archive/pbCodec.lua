--- 模块功能：基于 protobuf demo 抽出的可复用编解码库
-- @module pbCodec
-- @author GitHub Copilot
-- @release 2026.5.13

module(..., package.seeall)

local loadedFile
local lastMessageName = nil
local lastOperation = nil
local lastOk = nil
local lastPayloadSize = 0
local config = {
    pb_file = "/luadb/person.pb",
    message_name = "Person",
    data = {
        name = "wendal",
        id = 123,
        email = "abc@qq.com",
    },
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if value ~= nil then
            config[key] = value
        end
    end
    return config
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function loadDefinition(pbFile)
    pbFile = pbFile or config.pb_file
    assert(pbFile and pbFile ~= "", "pbCodec missing pbFile")
    if not io.exists(pbFile) then
        lastOperation = "loadDefinition"
        lastOk = false
        return false, "pb file not found"
    end

    local success, bytesRead = protobuf.load(io.readFile(pbFile))
    lastOperation = "loadDefinition"
    lastOk = success
    if success then
        loadedFile = pbFile
        return true, bytesRead
    end

    return false, bytesRead
end

function encodeMessage(messageName, data)
    messageName = messageName or config.message_name
    data = data or config.data
    assert(messageName and messageName ~= "", "pbCodec missing messageName")
    assert(type(data) == "table", "pbCodec data must be table")

    local payload = protobuf.encode(messageName, data)
    if not payload then
        lastOperation = "encodeMessage"
        lastMessageName = messageName
        lastOk = false
        return false, "encode failed"
    end

    lastOperation = "encodeMessage"
    lastMessageName = messageName
    lastPayloadSize = #payload
    lastOk = true
    return true, payload
end

function decodeMessage(messageName, payload)
    messageName = messageName or config.message_name
    assert(messageName and messageName ~= "", "pbCodec missing messageName")
    assert(payload and payload ~= "", "pbCodec missing payload")

    local data = protobuf.decode(messageName, payload)
    if not data then
        lastOperation = "decodeMessage"
        lastMessageName = messageName
        lastOk = false
        return false, "decode failed"
    end

    lastOperation = "decodeMessage"
    lastMessageName = messageName
    lastPayloadSize = #payload
    lastOk = true
    return true, data
end

function compareJsonSize(messageName, data)
    local ok, payload = encodeMessage(messageName, data)
    if not ok then
        return false, payload
    end

    local jsonPayload = json.encode(data)
    return true, {
        protobuf_size = #payload,
        json_size = jsonPayload and #jsonPayload or 0,
        protobuf_hex = payload:toHex(),
        json_text = jsonPayload,
    }
end

function runDemo(config)
    local cfg = mergeConfig(config or {})
    local pbFile = cfg.pb_file
    local messageName = cfg.message_name
    local data = cfg.data

    local loaded, loadDetail = loadDefinition(pbFile)
    if not loaded then
        return false, loadDetail
    end

    local compared, summary = compareJsonSize(messageName, data)
    if not compared then
        return false, summary
    end

    local encodedOk, payload = encodeMessage(messageName, data)
    if not encodedOk then
        return false, payload
    end

    local decodedOk, decodedData = decodeMessage(messageName, payload)
    if not decodedOk then
        return false, decodedData
    end

    return true, {
        definition_file = loadedFile,
        definition_size = loadDetail,
        encoded = summary,
        decoded = decodedData,
    }
end

function clearDefinition()
    protobuf.clear()
    loadedFile = nil
    lastOperation = "clearDefinition"
    lastOk = true
    lastPayloadSize = 0
end

function getState()
    return {
        loaded_file = loadedFile,
        last_message_name = lastMessageName,
        last_operation = lastOperation,
        last_ok = lastOk,
        last_payload_size = lastPayloadSize,
    }
end

local thrust_api = require("apis.thrusters")
local serialization = require("apis.serialization")

local function getEngineAPI()
    local status, data = serialization.native.loadf("engine_config.txt")
    if not status then
        error("Failed to load engine map: " .. data)
    end

    local status, data = thrust_api.init(data, 1)
    if not status then
        error("Failed to init engine API: " .. data)
    end

    return data
end

local api = getEngineAPI()

print("HALTING THRUSTERS")
for name, engine in pairs(api.thrusters) do
    engine.setManaged(false)
    engine.setLevel(0)
    engine.setPowerState(false)
end
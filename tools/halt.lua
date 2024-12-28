local thrust_api = require("libs.thrusters")
local serialization = require("libs.serialization")
local consts = require("components.consts")

print("HALTING THRUSTERS")
if carrieros then
    -- The CarrierOS server exposes a global API through the kernel
    carrieros.debug.halt()
    return
end

local function getThrusterAPI()
    local status, data = serialization.json.loadf(consts.THRUSTER_CONFIG_PATH)
    if not status then
        error("Failed to load engine map: " .. data)
    end

    local status, data = thrust_api.init(data, 1)
    if not status then
        error("Failed to init engine API: " .. data)
    end

    return data
end

local api = getThrusterAPI()
for name, engine in pairs(api.thrusters) do
    engine.setManaged(false)
    engine.setLevel(0)
    engine.setPowerState(false)
end
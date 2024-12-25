local stabilizer_api = require("components.stabilizer")
local autopilot_api = require("components.autopilot")
local thrust_api = require("libs.thrusters")
local serialization = require("libs.serialization")
local math3d = require("libs.math3d")

local function loadThrustProfiles()
    local profiles = {}
    for _, file in ipairs(fs.list("profiles")) do
        local fullPath = fs.combine("profiles", file)
        if not fs.isDir(fullPath) and file:match("%.json$") then
            print(string.format("Loading profile definition \"%s\"", file))
            local success, profile = serialization.json.loadf(fullPath)
            if not success then
                error("Failed to load profile: " .. profile)
            end

            if profiles[profile.type] ~= nil then
                error("Collision encountered: profile type " .. profile.type .. " already loaded")
            end

            profiles[profile.type] = profile
        end
    end

    return profiles
end

local function getEngineAPI(thrustProfiles, updateLength)
    local status, config = serialization.native.loadf("engine_config.txt")
    if not status then
        error("Failed to load engine map: " .. config)
    end

    local status, tapi = thrust_api.init(config, thrustProfiles, updateLength)
    if not status then
        error("Failed to init engine API: " .. tapi)
    end

    return tapi
end

local profiles = loadThrustProfiles()
local tapi = getEngineAPI(profiles, 3)
local config = {
    tickRate = 1,
    DELTA_K = 0.0075,
    pitchPID = {
        kp = 1.25,
        ki = 0.25,
        kd = 0.1
    },
    rollPID = {
        kp = 1.25,
        ki = 0.25,
        kd = 0.1
    },
    specialThrusterMap = {
        main = {
            FL = "main_front_left",
            FR = "main_front_right",
            BL = "main_back_left",
            BR = "main_back_right"
        }
    }
}

local stabilizer = stabilizer_api.new(tapi, config)
local autopilot = autopilot_api.new(stabilizer, 20, 80, 2.5)

stabilizer:start()
stabilizer:setTarget(math3d.Vector3.new(0, 0, 0))
autopilot:setActive(true)
autopilot:setNavigationActive(true)

-- Function to handle stabilizer updates
local function stabilizerLoop()
    while true do
        autopilot:update()
        stabilizer:update()
        os.sleep(0.05)
    end
end

-- Function to handle user input for changing target vector
local function inputLoop()
    while true do
        print("Enter new target vector (x y z):")
        local input = read() -- Wait for user input
        local x, y, z = input:match("^(%-?%d+%.?%d*) (%-?%d+%.?%d*) (%-?%d+%.?%d*)$")
        if x and y and z then
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            local vec = math3d.Vector3.new(x, y, z)
            autopilot:addWaypoint("TARGET", vec, 0)
            print(string.format("Target updated to: (%.2f, %.2f, %.2f)", x, y, z))
        else
            print("Invalid input. Please enter three numbers separated by spaces.")
        end
    end
end

-- Run both loops in parallel
parallel.waitForAny(stabilizerLoop, inputLoop)
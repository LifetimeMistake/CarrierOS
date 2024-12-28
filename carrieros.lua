local stabilizer_api = require("components.stabilizer")
local autopilot_api = require("components.autopilot")
local consts = require("components.consts")
local thrust_api = require("libs.thrusters")
local serialization = require("libs.serialization")
local math3d = require("libs.math3d")
local logging = require("libs.logging")
local Vector3 = math3d.Vector3
local Waypoints = require("components.waypoints")

if not log then
    print("Setting up own logger")
    local logger = logging.Logger.new(100)

    _G.log = {
        debug = function(msg)
            logger:debug(msg)
        end,
        info = function(msg)
            logger:info(msg)
        end,
        warn = function(msg)
            logger:warn(msg)
        end,
        error = function(msg)
            logger:error(msg)
        end,
        instance = logger
    }

    logger:setHook(function (level, message)
        level = logging.LogLevel.tostring(level)
        print(string.format("[%s] %s", level, message))
    end)
end

-- Initialize waypoints database
local waypointsDb = Waypoints.new(consts.WAYPOINT_DB_PATH, true)

local function loadThrustProfiles()
    local profiles = {}
    for _, file in ipairs(fs.list(consts.THRUST_PROFILES_DIR)) do
        local fullPath = fs.combine(consts.THRUST_PROFILES_DIR, file)
        if not fs.isDir(fullPath) and file:match("%.json$") then
            log.info(string.format("Loading profile definition \"%s\"", file))
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

local function loadThrusterAPI(thrustProfiles, updateLength)
    local status, config = serialization.json.loadf(consts.THRUSTER_CONFIG_PATH)
    if not status then
        error("Failed to load engine map: " .. config)
    end

    local status, tapi = thrust_api.init(config, thrustProfiles, updateLength)
    if not status then
        error("Failed to init engine API: " .. tapi)
    end

    if peripheral.protect then
        for k,v in pairs(tapi.thrusters) do
            local name = peripheral.getName(v.data.integrator)
            peripheral.protect(name, "w")
        end
    end

    return tapi
end

local function loadSystemConfig()
    local defaults = {
        tickRate = 1,
        thrusterWindupTicks = 3,
        autopilot = {
            speedLimit = 20,
            slowdownThreshold = 80,
            arrivalThreshold = 2.5
        },
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

    if not fs.exists(consts.SYSTEM_CONFIG_PATH) then
        log.info("Loading default config")
        serialization.json.dumpf(defaults, consts.SYSTEM_CONFIG_PATH)
        return true, defaults
    end

    local success, data = serialization.json.loadf(consts.SYSTEM_CONFIG_PATH)
    if not success then
        log.error("Failed to load system config, falling back to default.")
        log.error(data)
        return false, defaults
    end

    log.info("Loaded config successfully")
    return true, data
end

local function loadState(stabilizer, autopilot)
    if not fs.exists(consts.STATE_PERSIST_PATH) then
        return
    end

    local success, state = serialization.json.loadf(consts.STATE_PERSIST_PATH)
    if not success then
        log.warn("Failed to load state from disk")
        return
    end

    -- Restore PIDs
    stabilizer.rollPID.prevError = state.stabilizer.rollPID.prevError
    stabilizer.rollPID.integral = state.stabilizer.rollPID.integral
    stabilizer.pitchPID.prevError = state.stabilizer.pitchPID.prevError
    stabilizer.pitchPID.integral = state.stabilizer.pitchPID.integral
    -- Restore stabilizer
    stabilizer.K = Vector3.from_table(state.stabilizer.K)
    stabilizer.weights = state.stabilizer.weights
    -- Restore autopilot
    local waypoints = {}
    for _,w in ipairs(state.autopilot.waypoints) do
        w.vector = Vector3.from_table(w.vector)
        table.insert(waypoints, w)
    end
    autopilot.active = state.autopilot.active
    autopilot.navigationActive = state.autopilot.navigationActive
    autopilot.waypoints = waypoints
end

local function saveState(stabilizer, autopilot)
    local rollPID = {
        prevError = stabilizer.rollPID.prevError,
        integral = stabilizer.rollPID.integral
    }

    local pitchPID = {
        prevError = stabilizer.pitchPID.prevError,
        integral = stabilizer.pitchPID.integral
    }

    local waypoints = {}
    for _,w in ipairs(autopilot.waypoints) do
        table.insert(waypoints, {
            name = w.name, 
            vector = Vector3.to_table(w.vector), 
            heading = w.heading
        })
    end

    local state = {
        stabilizer = {
            K = stabilizer.K,
            weights = stabilizer.weights,
            rollPID = rollPID,
            pitchPID = pitchPID,
        },
        autopilot = {
            active = autopilot.active,
            navigationActive = autopilot.navigationActive,
            waypoints = waypoints
        }
    }

    serialization.json.dumpf(state, consts.STATE_PERSIST_PATH)
end

local normalState, config = loadSystemConfig()
local profiles = loadThrustProfiles()
local tapi = loadThrusterAPI(profiles, config.thrusterWindupTicks)
local stabilizer = stabilizer_api.new(tapi, config)
local autopilot = autopilot_api.new(
    stabilizer,
    config.autopilot.speedLimit,
    config.autopilot.slowdownThreshold,
    config.autopilot.arrivalThreshold
)

stabilizer:start()
autopilot:setActive(true)

loadState(stabilizer, autopilot)
if normalState then
    saveState(stabilizer, autopilot)
end

-- CarrierOS API implementation
local api = {
    carrieros = {
        getVersion = function()
            return "1.0.0"
        end,
        
        getHostname = function()
            return os.getComputerLabel() or "CarrierOS"
        end,
        
        getHostId = function()
            return tostring(os.getComputerId())
        end,
        
        getRingBuffer = function(limit, offset)
            offset = offset or 0
            limit = limit or 100
            
            local result = {}
            local count = 0
            
            -- Get iterator over log entries
            for timestamp, level, message in log.instance:iter() do
                if count >= offset then
                    table.insert(result, {
                        timestamp = timestamp,
                        level = logging.LogLevel.tostring(level),
                        message = message
                    })
                    
                    if #result >= limit then
                        break
                    end
                end
                count = count + 1
            end
            
            return result
        end
    },
    
    waypoints = {
        list = function()
            local waypoints = waypointsDb:list()
            -- Convert Vector3 instances to tables for serialization
            for id, wp in pairs(waypoints) do
                wp.pos = Vector3.to_table(wp.pos)
            end
            return waypoints
        end,
        
        get = function(id)
            local wp = waypointsDb:get(id)
            if wp then
                wp.pos = Vector3.to_table(wp.pos)
            end
            return wp
        end,
        
        add = function(name, pos, heading)
            if type(pos) == "table" then
                pos = Vector3.from_table(pos)
            end
            local id = waypointsDb:add(name, pos, heading)
            waypointsDb:save()
            return id
        end,
        
        remove = function(id)
            local result = waypointsDb:remove(id)
            waypointsDb:save()
            return result
        end,
        
        update = function(id, data)
            if data.pos then
                data.pos = Vector3.from_table(data.pos)
            end
            local result = waypointsDb:update(id, data)
            waypointsDb:save()
            return result
        end
    },
    
    autopilot = {
        addStoredWaypoint = function(id)
            local wp = waypointsDb:get(id)
            if not wp then return false end
            autopilot:addWaypoint(wp.name, wp.pos, wp.heading)
            return true
        end,
        
        addWaypoint = function(name, pos, heading)
            if type(pos) == "table" then
                pos = Vector3.from_table(pos)
            end
            autopilot:addWaypoint(name, pos, heading)
        end,
        
        removeWaypoint = function(idx)
            local waypoints = autopilot:listWaypoints()
            if idx > 0 and idx <= #waypoints then
                table.remove(waypoints, idx)
                return true
            end
            return false
        end,
        
        listWaypoints = function()
            local waypoints = autopilot:listWaypoints()
            -- Convert Vector3 instances to tables
            for _, wp in ipairs(waypoints) do
                wp.vector = Vector3.to_table(wp.vector)
            end
            return waypoints
        end,
        
        getTargetPosition = function()
            if not autopilot.currentStrategy then return nil end
            local pos = autopilot.currentStrategy:getTargetPosition()
            return pos and Vector3.to_table(pos) or nil
        end,
        
        getStrategy = function()
            return autopilot:getStrategy()
        end,
        
        getEnabled = function()
            return autopilot:isActive()
        end,
        
        setEnabled = function(value)
            autopilot:setActive(value)
        end,
        
        getNavigationEnabled = function()
            return autopilot:isNavigationActive()
        end,
        
        setNavigationEnabled = function(value)
            autopilot:setNavigationActive(value)
        end
    },
    
    rc = {
        getFlightVector = function()
            return Vector3.to_table(autopilot.stabilizer.targetVector)
        end,
        
        setFlightVector = function(pos)
            if autopilot:isActive() then
                return false, "Autopilot is enabled"
            end
            if type(pos) == "table" then
                pos = Vector3.from_table(pos)
            end
            autopilot.stabilizer:setTarget(pos)
            return true
        end
    },
    
    debug = {
        getStabilizerState = function()
            local stab = autopilot.stabilizer
            return {
                target_vector = Vector3.to_table(stab.targetVector),
                force_diff = Vector3.to_table(stab.forceDiff),
                k_vector = Vector3.to_table(stab.K)
            }
        end,
        
        getThrusterInfo = function()
            local info = {}
            for _, thruster in ipairs(autopilot.stabilizer.thrusters) do
                local entry = {
                    name = thruster.name,
                    level = thruster.value.getLevel()
                }
                
                -- Add weight if it exists in the weight map
                local weight = autopilot.stabilizer.weights[thruster.name]
                if weight then
                    entry.weight = weight
                end
                
                table.insert(info, entry)
            end
            return info
        end,
        
        halt = function()
            autopilot.stabilizer:halt()
            halt = true
        end,
        
        unhalt = function()
            autopilot.stabilizer:start()
            halt = false
        end
    },
    
    navigation = {
        getInfo = function()
            return {
                position = Vector3.to_table(ship.getWorldspacePosition()),
                velocity = Vector3.to_table(ship.worldToLocal(ship.getVelocity())),
                rot = Vector3.to_table(Vector3.new(ship.getOrientation()))
            }
        end
    }
}

_G.carrieros = api

-- Function to handle stabilizer updates
local now = 0
local lastStateUpdateTick = 0
local function stabilizerLoop()
    while true do
        now = now + 1

        if not halt then
            autopilot:update()
            stabilizer:update()
            -- Persist state every 10 secs
            if now - lastStateUpdateTick >= 10*20 and normalState then
                saveState(stabilizer, autopilot)
                lastStateUpdateTick = now
            end
        end
        os.sleep(0.05)
    end
end

stabilizerLoop()
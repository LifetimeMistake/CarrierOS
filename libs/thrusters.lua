local utils = require("libs.utils")
local math3d = require("libs.math3d")

local control_api = {}
local thruster_api = {}

-- Thruster API
function thruster_api.getRawSignal(data)
    return data.integrator.getAnalogOutput(data.thrustSide)
end

function thruster_api.setRawSignal(data, value)
    data.integrator.setAnalogOutput(data.thrustSide, value)
    data.currentSignal = value
end

function thruster_api.setLevel(data, value)
    local signal = utils.clamp(math.floor((1.0 - value) * 15), 0, 15)
    data.targetSignal = signal

    -- Apply throttle directly if unmanaged
    if not data.isManaged then
        thruster_api.setRawSignal(data, signal)
    end
end

function thruster_api.getLevel(data)
    local signal = thruster_api.getRawSignal(data)
    return (15 - signal) / 15
end

function thruster_api.getPowerState(data)
    return data.integrator.getOutput(data.powerSide)
end

function thruster_api.setPowerState(data, state)
    data.integrator.setOutput(data.powerSide, state)
end

function thruster_api.isManaged(data)
    return data.isManaged
end

function thruster_api.setManaged(data, state)
    data.isManaged = state
end

function thruster_api.isConnected(data)
    return peripheral.isPresent(data.integratorName)
end

function thruster_api.supportsDirectionControl(data)
    return data.directionSide ~= nil
end

function thruster_api.isThrottleSynced(data)
    return data.targetSignal == data.currentSignal
end

-- Get normal direction
function thruster_api.getNormalDirection(data)
    return data.normalDirection
end

-- Get thruster direction
function thruster_api.getDirection(data)
    if not data.directionSide then
        return "normal"
    end

    local signal = data.integrator.getOutput(data.directionSide)
    if data.normalDirection == "reversed" then
        signal = not signal
    end

    if not signal then
        return "normal"
    else
        return "reversed"
    end
end

-- Set thruster direction
function thruster_api.setDirection(data, direction)
    if not data.directionSide then
        return false
    end

    local signal
    if direction == "normal" then
        signal = false
    elseif direction == "reversed" then
        signal = true
    else
        return false
    end

    if data.normalDirection == "reversed" then
        signal = not signal
    end

    data.integrator.setOutput(data.directionSide, signal)
    return true
end

function thruster_api.getForces(data, height)
    local pressure = utils.calculateAirPressure(height)
    local rawForces = data.rawForces

    return setmetatable({}, {
        __index = function(_, index)
            local force = rawForces[index]
            return force and force * pressure or nil
        end,
        __len = function()
            return #rawForces
        end,
        __pairs = function()
            local i = 0
            return function()
                i = i + 1
                if rawForces[i] then
                    return i, rawForces[i] * pressure
                end
            end
        end
    })
end

function thruster_api.setForce(data, force, height)
    local forcesTable = thruster_api.getForces(data, height)
    local closestIndex, closestForce

    for i = 1, #forcesTable do
        if forcesTable[i] >= force then
            closestIndex = i
            closestForce = forcesTable[i]
            break
        end
    end

    closestIndex = closestIndex or #forcesTable
    closestForce = closestForce or forcesTable[closestIndex]

    if closestIndex then
        thruster_api.setLevel(data, (closestIndex - 1) / 15)
    end

    return closestForce
end

function thruster_api.getForce(data, height)
    local level = thruster_api.getLevel(data)
    local index = math.floor(level * 15) + 1
    return thruster_api.getForces(data, height)[index]
end

function thruster_api.wrap(config, thrustProfile)
    local data = {
        integratorName = config.integrator,
        integrator = peripheral.wrap(config.integrator),
        powerSide = config.powerSide,
        thrustSide = config.thrustSide,
        directionSide = config.directionSide,
        isManaged = config.isManaged or false,
        targetSignal = 15,
        currentSignal = 15,
        type = thrustProfile.type,
        rawForces = thrustProfile.profile,
        thrustVector = math3d.Vector3.from_table(config.thrustVector),
        normalDirection = config.normalDirection
    }

    local thruster = {}
    for k, f in pairs(thruster_api) do
        if k ~= "wrap" then
            thruster[k] = function(...)
                return f(data, ...)
            end
        end
    end

    thruster.data = data
    return thruster
end

-- Get normal thrust vector
function thruster_api.getNormalThrustVector(data)
    return data.thrustVector
end

-- Get current thrust vector (inverted if direction is reversed)
function thruster_api.getCurrentThrustVector(data)
    if thruster_api.getDirection(data) == "reversed" then
        return -data.thrustVector
    else
        return data.thrustVector
    end
end

local function updateThrusters(t)
    t.tickId = t.tickId + 1
    if t.updateLength ~= t.tickId then
        -- defer update
        return
    end

    t.tickId = 0
    for _, engine in pairs(t.thrusters) do
        local currentSignal = engine.data.currentSignal
        local targetSignal = engine.data.targetSignal
        local diff = targetSignal - currentSignal

        if engine.isManaged() and currentSignal ~= targetSignal and diff ~= 0 then
            local delta
            if diff > 0 then
                delta = 1
            else
                delta = -1
            end

            currentSignal = currentSignal + delta
            engine.setRawSignal(currentSignal)

            local wantedPowerState = not (currentSignal == 15)
            if engine.getPowerState() ~= wantedPowerState then
                engine.setPowerState(wantedPowerState)
            end
        end
    end
end

local function waitForThrottleSync(t)
    while true do
        t.update()

        local synced = true
        for name, thruster in pairs(t.thrusters) do
            if not thruster.isThrottleSynced() then
                synced = false
                break
            end
        end

        if synced then
            break
        end

        os.sleep(0.05)
    end
end

function control_api.init(engineMap, thrustProfiles, updateLength)
    if not control_api.validateEngineMap(engineMap) then
        return false, "Some thrusters are missing, cannot wrap engine map"
    end
    
    local thrusters = {}
    for name, config in pairs(engineMap) do
        local profile = thrustProfiles[config.type]
        if not profile then
            return false, "Unknown force table type for thruster: " .. name
        end
        thrusters[name] = thruster_api.wrap(config, profile)
    end

    local t = {
        thrusters = thrusters,
        profiles = thrustProfiles,
        tickId = 0,
        updateLength = updateLength
    }

    for k, func in pairs(thruster_api) do
        t[k] = func
    end

    t.update = function ()
        updateThrusters(t)
    end

    t.sync = function()
        waitForThrottleSync(t)
    end

    return true, t
end

function control_api.validateEngineMap(engineMap)
    for engine, config in pairs(engineMap) do
        if not peripheral.isPresent(config.integrator) then
            return false
        end
    end

    return true
end

return control_api
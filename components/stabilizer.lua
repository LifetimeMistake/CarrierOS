local PID = require("apis.pid")
local math3d = require("apis.math3d")
local utils = require("apis.utils")
require("apis.shipExtensions")

local Vector3 = math3d.Vector3
local WORLD_GRAVITY = Vector3.new(0, -10, 0)

local function normalizeWeights(weights)
    local totalWeight = 0
    for _, weight in ipairs(weights) do
        totalWeight = totalWeight + weight
    end
    local scaleFactor = #weights / totalWeight
    for i, weight in ipairs(weights) do
        weights[i] = weight * scaleFactor
    end
end

local function clampWeights(weights, minWeight)
    for i, weight in ipairs(weights) do
        if weight < minWeight then
            weights[i] = minWeight
        end
    end
end

local function computeWeights(pitchError, rollError, pitchPID, rollPID)
    -- Start each cycle with equal weights
    local weights = {1, 1, 1, 1}

    -- Compute scaling factors from PID controllers
    local pitchScale = math.max(0, 1 - pitchPID:compute(0, math.abs(pitchError)))
    local rollScale = math.max(0, 1 - rollPID:compute(0, math.abs(rollError)))

    -- Adjust weights proportionally to pitch error
    weights[1] = weights[1] - pitchError * pitchScale -- front-left
    weights[2] = weights[2] - pitchError * pitchScale -- front-right
    weights[3] = weights[3] + pitchError * pitchScale -- back-left
    weights[4] = weights[4] + pitchError * pitchScale -- back-right

    -- Adjust weights proportionally to roll error
    weights[1] = weights[1] - rollError * rollScale -- front-left
    weights[3] = weights[3] - rollError * rollScale -- back-left
    weights[2] = weights[2] + rollError * rollScale -- front-right
    weights[4] = weights[4] + rollError * rollScale -- back-right

    -- Clamp and normalize weights
    local minWeight = 0.5
    clampWeights(weights, minWeight)
    normalizeWeights(weights)

    return weights
end

local function initThrusters(tapi)
    for name, thruster in pairs(tapi.thrusters) do
        thruster.isManaged(true)
        thruster.setLevel(0)
        thruster.setPowerState(true)
        thruster.setDirection("normal")
    end
end

local function stopThrusters(tapi, halt)
    for name, thruster in pairs(tapi.thrusters) do
        if halt then
            -- disabling managed mode will cause the request to be processed immediately
            thruster.isManaged(false)
        end

        thruster.setLevel(0)
        thruster.setPowerState(false)
    end

    tapi.sync()
end

local stabilizer = {}
stabilizer.__index = stabilizer

function stabilizer.new(thrusterAPI, config)
    local stabilizer = setmetatable({}, stabilizer)
    local thrusters = {}
    for name, thruster in pairs(thrusterAPI.thrusters) do
        local forces = thruster.getForces(0)
        table.insert(thrusters, {name = name, value = thruster, maxForce = forces[#forces] or 0})
    end
    
    table.sort(thrusters, function(a, b)
        return a.maxForce < b.maxForce
    end)
    
    stabilizer.tapi = thrusterAPI
    stabilizer.thrusters = thrusters
    stabilizer.targetVector = Vector3.new(0, 0, 0)
    stabilizer.targetHeading = 0
    stabilizer.K = config.K or Vector3.new(1, 1, 1)
    stabilizer.deltaK = config.DELTA_K or 0.0025
    stabilizer.idleTicks = utils.clamp(math.floor(20 / (config.tickRate or 20)), 1, 19)
    stabilizer.tickId = 1
    stabilizer.isRunning = false
    stabilizer.specialThrusterMap = config.specialThrusterMap or {}
    stabilizer.weights = {}

    stabilizer.pitchPID = PID:new(config.pitchPID.kp, config.pitchPID.ki, config.pitchPID.kd, 0.05 * stabilizer.idleTicks)
    stabilizer.rollPID = PID:new(config.rollPID.kp, config.rollPID.ki, config.rollPID.kd, 0.05 * stabilizer.idleTicks)

    return stabilizer
end

function stabilizer:start()
    self.isRunning = true
    initThrusters(self.tapi)
end

function stabilizer:stop()
    self.isRunning = false
    stopThrusters(self.tapi, false)
end

function stabilizer:halt()
    self.isRunning = false
    stopThrusters(self.tapi, true)
end

function stabilizer:doOrientationStep()
    local thrusterMap = self.specialThrusterMap

    if not thrusterMap.main then
        -- This stabilizer isn't configured for this type of rotational correction
        return
    end

    local weightMap = self.weights
    local pitch, yaw, roll = ship.getOrientation()
    local weights = computeWeights(pitch, roll, self.pitchPID, self.rollPID)

    -- print(
    --     string.format("Current orientation: (%f, %f, %f)",
    --     pitch,
    --     yaw,
    --     roll
    -- ))

    -- print(string.format("New weight matrix: [%f, %f, %f, %f]",
    --     table.unpack(weights)
    -- ))

    weightMap[thrusterMap.main.FL] = weights[1]
    weightMap[thrusterMap.main.FR] = weights[2]
    weightMap[thrusterMap.main.BL] = weights[3]
    weightMap[thrusterMap.main.BR] = weights[4]
end

function stabilizer:solveComponent(vel, height, reqForce, component)
    local targetVector = self.targetVector
    local weights = self.weights
    local reqForce = reqForce[component]

    local forceAxisAligned = reqForce > 0 or reqForce == 0
    local wantedVector = Vector3.new(0, 0, 0)
    wantedVector[component] = forceAxisAligned and 1 or -1

    local matchingThrusters = {}
    local matchingThrusterCount = 0
    for _, tWrapper in pairs(self.thrusters) do
        local thruster = tWrapper.value
        local thrustVector = thruster.getNormalThrustVector()
        local normalMatch = thrustVector == wantedVector
        local inverseMatch = -thrustVector == wantedVector

        if normalMatch or inverseMatch then
            if normalMatch or thruster.supportsDirectionControl() then
                matchingThrusterCount = matchingThrusterCount + 1
            end
            table.insert(matchingThrusters, tWrapper)
        end
    end

    local submittedForce = 0
    local submittedCount = 0
    reqForce = math.abs(reqForce)

    for _, tWrapper in pairs(matchingThrusters) do
        local name = tWrapper.name
        local thruster = tWrapper.value
        -- local forceDiff = reqForce - submittedForce
        local thrustVector = thruster.getNormalThrustVector()
        local normalMatch = thrustVector == wantedVector

        -- if (normalMatch or thruster.supportsDirectionControl()) and forceDiff > 0 then
        if (normalMatch or thruster.supportsDirectionControl()) then
            local weight = weights[name] or 1.0
            -- local wantedForce = weight * (reqForce / (matchingThrusterCount - submittedCount))
            local wantedForce = weight * (reqForce / matchingThrusterCount)
            local realForce = thruster.setForce(wantedForce, height)

            submittedForce = submittedForce + realForce
            submittedCount = submittedCount + 1

            if thruster.supportsDirectionControl() then
                local direction
                if normalMatch then
                    direction = "normal"
                else
                    direction = "reversed"
                end
                
                thruster.setDirection(direction)
            end
        else
            thruster.setLevel(0)
        end
    end

    -- Solve component error
    local vC = vel[component]
    local tgVC = targetVector[component]
    self.K[component] = utils.clamp(self.K[component] + self.deltaK * (tgVC - vC), 0.8, 2.0)

    return reqForce - submittedForce
end

function stabilizer:doThrustStep()
    local mass = ship.getMass()
    local pos = ship.getWorldspacePosition()
    local vel = ship.worldToLocal(ship.getVelocity())

    local reqAccel = self.targetVector - (vel + ship.worldToLocal(WORLD_GRAVITY))
    local reqForce = Vector3.componentWiseMultiply(reqAccel * mass, self.K)

    -- print(
    --     string.format("Required force: (%s, %s, %s)", 
    --     utils.formatForce(reqForce.x),
    --     utils.formatForce(reqForce.y),
    --     utils.formatForce(reqForce.z)
    -- ))

    local forceDiff = Vector3.new(
        self:solveComponent(vel, pos.y, reqForce, "x"),
        self:solveComponent(vel, pos.y, reqForce, "y"),
        self:solveComponent(vel, pos.y, reqForce, "z")
    )

    -- print("Force diff: " .. utils.formatForce(forceDiff:magnitude()))
    -- print(
    --     string.format("reqAccel: (%f, %f, %f)",
    --     reqAccel.x,
    --     reqAccel.y,
    --     reqAccel.z
    -- ))

    -- print(
    --     string.format("Current velocity: (%f, %f, %f)",
    --     vel.x,
    --     vel.y,
    --     vel.z
    -- ))

    -- print(
    --     string.format("K: (%f, %f, %f)",
    --     self.K.x,
    --     self.K.y,
    --     self.K.z
    -- ))
end

function stabilizer:setTarget(pos, heading)
    self.targetVector = Vector3.from_table(pos)
    self.targetHeading = heading or self.targetHeading
end

function stabilizer:doStep()
    self:doOrientationStep()
    self:doThrustStep()
end

function stabilizer:update()
    if self.tickId % self.idleTicks == 0 then
        self:doStep()
        self.tickId = 1
    end

    self.tapi.update()
    self.tickId = self.tickId + 1
end

return stabilizer
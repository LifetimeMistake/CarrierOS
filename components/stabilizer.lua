local PID = require("libs.pid")
local math3d = require("libs.math3d")
local utils = require("libs.utils")
require("libs.shipExtensions")

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
    stabilizer.targetHeading = nil
    stabilizer.K = config.K or Vector3.new(1, 1, 1)
    stabilizer.deltaK = config.DELTA_K or 0.0025
    stabilizer.idleTicks = utils.clamp(math.floor(20 / (config.tickRate or 20)), 1, 19)
    stabilizer.tickId = 1
    stabilizer.isRunning = false

    stabilizer.specialThrusterMap = config.specialThrusterMap or {}
    stabilizer.rotReservedThrusters = {}
    stabilizer.weights = {}

    stabilizer.pitchPID = PID:new(config.pitchPID.kp, config.pitchPID.ki, config.pitchPID.kd, 0.05 * stabilizer.idleTicks)
    stabilizer.rollPID = PID:new(config.rollPID.kp, config.rollPID.ki, config.rollPID.kd, 0.05 * stabilizer.idleTicks)
    stabilizer.yawPID = PID:new(config.yawPID.kp, config.yawPID.ki, config.yawPID.kd, 0.05 * stabilizer.idleTicks)

    stabilizer.lastYaw = 0
    stabilizer.yawVelocity = 0
    stabilizer.deadzone = config.deadzone or 5  -- Default deadzone in degrees

    -- Diagnostics
    stabilizer.forceDiff = Vector3.new(0, 0, 0)
    stabilizer.reqForce = Vector3.new(0, 0, 0)
    
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

function stabilizer:doTiltStep()
    local thrusterMap = self.specialThrusterMap

    if not thrusterMap.main then
        -- This stabilizer isn't configured for this type of rotational correction
        return
    end

    local weightMap = self.weights
    local pitch, yaw, roll = ship.getOrientation()
    local weights = computeWeights(pitch, roll, self.pitchPID, self.rollPID)

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
        local name = tWrapper.name
        local thruster = tWrapper.value
        local thrustVector = thruster.getNormalThrustVector()
        local normalMatch = thrustVector == wantedVector
        local inverseMatch = -thrustVector == wantedVector

        if normalMatch or inverseMatch and not self.rotReservedThrusters[name] then
            if normalMatch or thruster.supportsDirectionControl() then
                matchingThrusterCount = matchingThrusterCount + 1
            end
            table.insert(matchingThrusters, tWrapper)
        end
    end

    local submittedForce = 0
    local submittedCount = 0
    reqForce = math.abs(reqForce)

    -- Avoid updating K
    if matchingThrusterCount == 0 then
        return reqForce
    end

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

function stabilizer:calculateYawVelocity()
    local _, yaw, _ = ship.getOrientation()
    yaw = math.deg(yaw)
    local deltaTime = 0.05 * self.idleTicks  -- Time between measurements in seconds
    
    -- Calculate yaw delta in degrees and handle wraparound
    local yawDelta = yaw - self.lastYaw
    if yawDelta > 180 then
        yawDelta = yawDelta - 360
    elseif yawDelta < -180 then
        yawDelta = yawDelta + 360
    end
    
    -- Calculate angular velocity in degrees per second
    self.yawVelocity = yawDelta / deltaTime
    
    -- Update last yaw value
    self.lastYaw = yaw
    
    return self.yawVelocity
end

function stabilizer:doRotationStep()
    local yawVelocity = self:calculateYawVelocity()

    self.rotReservedThrusters = {}
    if self.targetHeading == nil then
        return
    end

    local rotLarge = self.specialThrusterMap.rotLarge
    local rotSmall = self.specialThrusterMap.rotSmall

    if not rotSmall and not rotLarge then
        return
    end

    -- Get current orientation
    local pos = ship.getWorldspacePosition()
    local _, currentYaw, _ = ship.getOrientation()
    currentYaw = math.deg(currentYaw)

    -- Calculate heading error
    local yawError = self.targetHeading - currentYaw
    -- Normalize to [-180, 180]
    while yawError > 180 do yawError = yawError - 360 end
    while yawError < -180 do yawError = yawError + 360 end

    -- Check if yawError is within the deadzone
    if math.abs(yawError) < self.deadzone then
        return  -- Relinquish thrusters if within deadzone
    end

    -- Use angle PID to get desired velocity
    local targetVelocity = self.yawPID:compute(0, yawError)

    -- Use velocity PID to get thrust level
    local velocityError = targetVelocity - yawVelocity

    local thrustLevel = math.abs(yawError / 90.0)
    thrustLevel = utils.clamp(thrustLevel, 0.0, 1.0)
    
    -- Determine which thrusters to use based on required power and available options
    local useLargeThrusters = rotLarge and (
        math.abs(velocityError) > 30 or  -- Large velocity error
        math.abs(yawError) > 45 or  -- Large angle error
        not rotSmall  -- No small thrusters available
    )
    
    -- Here we just assume that the thrusters support reverse thrust
    -- Otherwise this type of control doesn't work anyway
    if useLargeThrusters then
        -- Handle using large thrusters
        self.rotReservedThrusters[rotLarge.LEFT] = true
        self.rotReservedThrusters[rotLarge.RIGHT] = true

        -- Since we're taking over the thrusters we need to factor in the wanted Z thrust
        -- If reqForce < 0, subtract power from the normal thruster to have a negative velocity
        -- If reqForce > 0, subtract power from the reverse thruster to have a positive velocity

        local reqForce = self.reqForce.z
        local left = self.tapi.thrusters[rotLarge.LEFT]
        local right = self.tapi.thrusters[rotLarge.RIGHT]

        local function computeBias(posThruster, negThruster)
            local posBias, negBias = 0, 0
            if reqForce < 0 then
                posBias = posThruster.getLevelFromForce(math.abs(reqForce), pos.y)
            elseif reqForce > 0 then
                negBias = negThruster.getLevelFromForce(math.abs(reqForce), pos.y)
            end

            return posBias, negBias
        end
        
        if velocityError < 0 then  -- Need to turn left (negative error means we need more positive velocity)
            local posBias, negBias = computeBias(right, left)
            local leftThrustLevel = utils.clamp(thrustLevel - negBias, 0, 1)
            local rightThrustLevel = utils.clamp(thrustLevel - posBias, 0, 1)
            print("LEFT, T: " .. self.targetHeading, "C: " .. currentYaw, ", Pb: " .. posBias, "Nb: " .. negBias, ", Ltt: " .. leftThrustLevel, ", Rtt: " .. rightThrustLevel)
            -- Turn left
            left.setDirection("reversed")
            right.setDirection("normal")
            left.setLevel(leftThrustLevel)
            right.setLevel(rightThrustLevel)
        else
            local posBias, negBias = computeBias(left, right)
            local leftThrustLevel = utils.clamp(thrustLevel - posBias, 0, 1)
            local rightThrustLevel = utils.clamp(thrustLevel - negBias, 0, 1)
            print("RIGHT, T: " .. self.targetHeading, "C: " .. currentYaw, ", Pb: " .. posBias, "Nb: " .. negBias, ", Ltt: " .. leftThrustLevel, ", Rtt: " .. rightThrustLevel)
            -- Turn right
            left.setDirection("normal")
            right.setDirection("reversed")
            left.setLevel(leftThrustLevel)
            right.setLevel(rightThrustLevel)
        end
        
        return
    end

    -- Else handle with small thrusters
    self.rotReservedThrusters[rotSmall.FL] = true
    self.rotReservedThrusters[rotSmall.BR] = true
    self.rotReservedThrusters[rotSmall.FR] = true
    self.rotReservedThrusters[rotSmall.BL] = true

    local tFL = self.tapi.thrusters[rotSmall.FL]
    local tBR = self.tapi.thrusters[rotSmall.BR]
    local tFR = self.tapi.thrusters[rotSmall.FR]
    local tBL = self.tapi.thrusters[rotSmall.BL]

    local directionSupported = tFL.supportsDirectionControl() and tBR.supportsDirectionControl()
    and tFR.supportsDirectionControl() and tBL.supportsDirectionControl()
    
    if velocityError < 0 then  -- Need to turn left (negative error means we need more positive velocity)
        -- Turn left
        if directionSupported then
            tFR.setDirection("reversed")
            tBL.setDirection("reversed")
            tFR.setLevel(thrustLevel)
            tBL.setLevel(thrustLevel)
        else
            tFR.setLevel(0)
            tBL.setLevel(0)
        end

        tFL.setDirection("normal")
        tBR.setDirection("normal")
        tFL.setLevel(thrustLevel)
        tBR.setLevel(thrustLevel)
    else
        -- Turn right
        if directionSupported then
            tFL.setDirection("reversed")
            tBR.setDirection("reversed")
            tFL.setLevel(thrustLevel)
            tBR.setLevel(thrustLevel)
        else
            tFL.setLevel(0)
            tBR.setLevel(0)
        end

        tFR.setDirection("normal")
        tBL.setDirection("normal")
        tFR.setLevel(thrustLevel)
        tBL.setLevel(thrustLevel)
    end
end

function stabilizer:doThrustStep()
    local mass = ship.getMass()
    local pos = ship.getWorldspacePosition()
    local vel = ship.worldToLocal(ship.getVelocity())

    local reqAccel = self.targetVector - (vel + ship.worldToLocal(WORLD_GRAVITY))
    local reqForce = Vector3.componentWiseMultiply(reqAccel * mass, self.K)

    self.reqForce = reqForce
    self.forceDiff = Vector3.new(
        self:solveComponent(vel, pos.y, reqForce, "x"),
        self:solveComponent(vel, pos.y, reqForce, "y"),
        self:solveComponent(vel, pos.y, reqForce, "z")
    )
end

function stabilizer:setTarget(pos, heading)
    self.targetVector = Vector3.from_table(pos)
    self.targetHeading = heading
end

function stabilizer:doStep()
    self:doTiltStep()
    self:doThrustStep()
    self:doRotationStep()
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
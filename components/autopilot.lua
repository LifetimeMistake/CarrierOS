local math3d = require("libs.math3d")
local utils = require("libs.utils")
local Vector3 = math3d.Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

-- Define the Strategy Base Class
local Strategy = {}
Strategy.__index = Strategy

function Strategy:new()
    local obj = {}
    setmetatable(obj, self)
    return obj
end

function Strategy:update(autopilot)
    -- Abstract method to be implemented by subclasses
    error("Strategy:update must be implemented in subclasses")
end

function Strategy:onLoad(autopilot)
    -- Abstract method for when the strategy is loaded
end

function Strategy:onUnload(autopilot)
    -- Abstract method for when the strategy is unloaded
end

function Strategy:getTargetPosition()
    -- Abstract method to retrieve the current target position
    error("Strategy:getTargetPosition must be implemented in subclasses")
end

-- Define the HoldStrategy
local HoldStrategy = setmetatable({}, Strategy)
HoldStrategy.__index = HoldStrategy

function HoldStrategy:new()
    local obj = Strategy:new()
    setmetatable(obj, self)
    obj.holdPosition = nil
    obj.holdHeading = nil  -- Store the heading we want to maintain
    return obj
end

function HoldStrategy:onLoad(autopilot)
    self.holdPosition = ship.getWorldspacePosition()
end

function HoldStrategy:onUnload(autopilot)
    self.holdPosition = nil
end

function HoldStrategy:update(autopilot)
    if not self.holdPosition then
        return
    end
    
    local currentPosition = ship.getWorldspacePosition()
    local direction = self.holdPosition - currentPosition
    local distance = direction:magnitude()

    -- Set movement and rotation
    if distance < autopilot.arrivalThreshold then
        autopilot.stabilizer:setTarget(ZERO_VECTOR, nil)
        return
    end

    local targetVelocity = ship.worldToLocal(direction:normalize() * autopilot.speedLimit)
    if distance < autopilot.slowdownThreshold then
        targetVelocity = targetVelocity * (distance / autopilot.slowdownThreshold)
    end

    autopilot.stabilizer:setTarget(targetVelocity, nil)
end

function HoldStrategy:getTargetPosition()
    return self.holdPosition
end

-- Define the NavigateStrategy
local NavigateStrategy = setmetatable({}, Strategy)
NavigateStrategy.__index = NavigateStrategy

function NavigateStrategy:new()
    local obj = Strategy:new()
    setmetatable(obj, self)
    obj.currentWaypoint = nil
    obj.alignmentStart = 0
    obj.alignmentDuration = 5
    obj.isAligned = false
    return obj
end

function NavigateStrategy:onLoad(autopilot)
    self.currentWaypoint = autopilot.waypoints[1]
    self.targetHeading = nil
    self.alignmentStart = os.clock()
    self.isAligned = false
end

function NavigateStrategy:onUnload(autopilot)
    self.currentWaypoint = nil
    self.targetHeading = nil
end

function NavigateStrategy:update(autopilot)
    if #autopilot.waypoints == 0 then
        autopilot:setStrategy("HOLD")
        return
    end

    local currentPosition = ship.getWorldspacePosition()
    self.currentWaypoint = autopilot.waypoints[1]
    local targetPosition = self.currentWaypoint.vector
    local direction = targetPosition - currentPosition
    local distance = direction:magnitude()

    if distance < autopilot.arrivalThreshold then
        table.remove(autopilot.waypoints, 1)
        self.currentWaypoint = autopilot.waypoints[1]
        self.alignmentStart = os.clock()
        self.isAligned = false

        print("NAVIGATE strategy reached waypoint")
        return
    end

    -- Determine desired heading based on distance
    local desiredHeading
    if distance < autopilot.slowdownThreshold and self.currentWaypoint.heading ~= nil then
        desiredHeading = self.currentWaypoint.heading
    elseif distance < autopilot.slowdownThreshold and self.targetHeading ~= nil then
        desiredHeading = self.targetHeading
    else
        -- Calculate the direction to the target
        local worldDirection = direction:normalize()
        desiredHeading = math.deg(math.atan2(worldDirection.x, worldDirection.z))
        self.targetHeading = desiredHeading
    end

    if not self.isAligned then
        -- New alignment check within a cone of 20 degrees
        local _, currentHeading, _ = ship.getOrientation()
        local headingError = math.abs(math.deg(currentHeading) - desiredHeading)

        if headingError > 20 then
            self.alignmentStart = os.clock()
            autopilot.stabilizer:setTarget(ZERO_VECTOR, desiredHeading)
            self.isAligned = false
            return
        else
            if os.clock() - self.alignmentStart > self.alignmentDuration then
                print("Autopilot aligned to travel direction")
                self.isAligned = true
            else
                return
            end
        end
    end
    
    local targetVelocity = ship.worldToLocal(direction:normalize() * autopilot.speedLimit)
    if distance < autopilot.slowdownThreshold then
        targetVelocity = targetVelocity * (distance / autopilot.slowdownThreshold)
    end

    autopilot.stabilizer:setTarget(targetVelocity, desiredHeading)
end

function NavigateStrategy:getTargetPosition()
    return self.currentWaypoint and self.currentWaypoint.vector or nil
end

-- Define the Autopilot Class
local Autopilot = {}
Autopilot.__index = Autopilot

function Autopilot.new(stabilizer, speedLimit, rotationSpeedLimit, slowdownThreshold, arrivalThreshold)
    local obj = setmetatable({}, Autopilot)
    obj.stabilizer = stabilizer
    obj.active = false
    obj.navigationActive = false
    obj.speedLimit = speedLimit or 10
    obj.rotationSpeedLimit = rotationSpeedLimit or 30
    obj.slowdownThreshold = slowdownThreshold or 40
    obj.arrivalThreshold = arrivalThreshold or 5
    obj.strategyType = nil
    obj.currentStrategy = nil
    obj.waypoints = {}
    obj.strategies = {
        HOLD = HoldStrategy:new(),
        NAVIGATE = NavigateStrategy:new()
    }

    obj:setStrategy("HOLD")
    return obj
end

function Autopilot:setActive(state)
    self.active = state
end

function Autopilot:isActive()
    return self.active
end

function Autopilot:setNavigationActive(state)
    self.navigationActive = state
end

function Autopilot:isNavigationActive()
    return self.navigationActive
end

function Autopilot:setStrategy(strategyType)
    if self.strategies[strategyType] then
        print("Entering autopilot strategy: " .. strategyType)
        if self.currentStrategy then
            self.currentStrategy:onUnload(self)
        end
        self.strategyType = strategyType
        self.currentStrategy = self.strategies[strategyType]
        self.currentStrategy:onLoad(self)
    else
        error("Invalid strategy type: " .. strategyType)
    end
end

function Autopilot:getStrategy()
    return self.strategyType
end

function Autopilot:addWaypoint(name, vector, heading)
    table.insert(self.waypoints, {name = name, vector = vector, heading = heading})
end

function Autopilot:clearWaypoints()
    self.waypoints = {}
end

function Autopilot:listWaypoints()
    return self.waypoints
end

function Autopilot:listStrategies()
    local strategyNames = {}
    for strategyName, _ in pairs(self.strategies) do
        table.insert(strategyNames, strategyName)
    end
    return strategyNames
end

function Autopilot:update()
    if not self.active then
        return
    end

    self.currentStrategy:update(self)

    -- Cleanup and update state
    local wantedStrategy = (self.navigationActive and #self.waypoints > 0) and "NAVIGATE" or "HOLD"
    if self.strategyType ~= wantedStrategy then
        self:setStrategy(wantedStrategy)
    end
end

return Autopilot
local math3d = require("libs.math3d")
local utils = require("libs.utils")
local event = require("libs.event")
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

function NavigateStrategy.new()
    local obj = Strategy:new()
    setmetatable(obj, NavigateStrategy)
    obj.currentWaypoint = nil
    obj.targetHeading = nil
    return obj
end

function NavigateStrategy:resetAlignment(autopilot)
    self.alignmentStart = os.clock()
    self.alignmentDuration = autopilot.alignmentDuration
    self.alignmentThreshold = autopilot.alignmentThreshold
    self.isAligned = false
end

function NavigateStrategy:onLoad(autopilot)
    self.currentWaypoint = autopilot.waypoints[1]
    self:resetAlignment(autopilot)
end

function NavigateStrategy:onUnload(autopilot)
    self.currentWaypoint = nil
    self.targetHeading = nil
end

function NavigateStrategy:update(autopilot)
    if #autopilot.waypoints == 0 then
        autopilot.events.navigation_complete:fire()
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
        self:resetAlignment(autopilot)
        print("NAVIGATE strategy reached waypoint")
        
        autopilot.events.waypoint_reached:fire(self.currentWaypoint)
        if #autopilot.waypoints == 0 then
            autopilot.events.navigation_complete:fire()
        end
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
        local _, currentHeading, _ = ship.getOrientation()
        local velocity = ship.getVelocity():magnitude()
        local headingError = math.abs(math.deg(currentHeading) - desiredHeading)

        -- Safeguard to prevent the ship from running off in case of unbalanced mass
        if velocity > 5 then
            desiredHeading = nil
        end

        if headingError > self.alignmentThreshold then
            self:resetAlignment(autopilot)
            autopilot.stabilizer:setTarget(ZERO_VECTOR, desiredHeading)
            return
        else
            if os.clock() - self.alignmentStart > self.alignmentDuration then
                print("Autopilot aligned to travel direction")
                self.isAligned = true
                autopilot.events.departing:fire(self.currentWaypoint)
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
Autopilot.events = {
    state_updated = event.new("autopilot_state_updated"),
    departing = event.new("autopilot_departing"),
    strategy_updated = event.new("autopilot_strategy_updated"),
    waypoint_reached = event.new("autopilot_waypoint_reached"),
    navigation_complete = event.new("autopilot_navigation_complete"),
}

function Autopilot.new(stabilizer, config)
    local obj = setmetatable({}, Autopilot)
    obj.stabilizer = stabilizer
    obj.active = false
    obj.navigationActive = false
    obj.speedLimit = config.speedLimit or 10
    obj.rotationSpeedLimit = config.rotationSpeedLimit or 30
    obj.slowdownThreshold = config.slowdownThreshold or 40
    obj.arrivalThreshold = config.arrivalThreshold or 5
    obj.alignmentThreshold = config.alignmentThreshold or 15
    obj.alignmentDuration = config.alignmentDuration or 5
    obj.strategyType = "NONE"
    obj.currentStrategy = nil
    obj.waypoints = {}
    obj.strategies = {
        HOLD = HoldStrategy:new(),
        NAVIGATE = NavigateStrategy:new()
    }

    return obj
end

function Autopilot:setActive(state)
    local prevState = self.active
    if prevState == state then
        return
    end

    self.active = state
    if not state and self.currentStrategy ~= nil then
        self.currentStrategy:onUnload(self)
        self.currentStrategy = nil
        self.strategyType = "NONE"
    end

    self.events.state_updated:fire(prevState, state, self.navigationActive, self.navigationActive)
end

function Autopilot:isActive()
    return self.active
end

function Autopilot:setNavigationActive(state)
    local prevState = self.navigationActive
    if prevState == state then
        return
    end

    self.navigationActive = state
    self.events.state_updated:fire(self.active, self.active, prevState, state)
end

function Autopilot:isNavigationActive()
    return self.navigationActive
end

function Autopilot:setStrategy(strategyType)
    if self.strategies[strategyType] then
        local prevStrategy = self.currentStrategy
        if prevStrategy == strategyType then
            return
        end
        
        print("Entering autopilot strategy: " .. strategyType)
        if self.currentStrategy then
            self.currentStrategy:onUnload(self)
        end
        self.strategyType = strategyType
        self.currentStrategy = self.strategies[strategyType]
        self.currentStrategy:onLoad(self)

        self.events.strategy_updated:fire(prevStrategy, strategyType)
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

    if self.currentStrategy then
        self.currentStrategy:update(self)
    end

    -- Cleanup and update state
    local wantedStrategy = (self.navigationActive and #self.waypoints > 0) and "NAVIGATE" or "HOLD"
    if self.strategyType ~= wantedStrategy then
        self:setStrategy(wantedStrategy)
    end
end

return Autopilot
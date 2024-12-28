local utils = require("libs.utils")

local PID = {}
PID.__index = PID

function PID:new(kp, ki, kd, dt, mi, id)
    return setmetatable({
        kp = kp,
        ki = ki,
        kd = kd,
        dt = dt,
        prevError = 0,
        integral = 0,
        maxIntegral = mi or 10.0,  -- Maximum integral term
        integralDecay = id or 1.0 -- Decay factor per update
    }, self)
end

function PID:compute(setpoint, current)
    local error = setpoint - current
    
    -- Apply integral decay
    self.integral = self.integral * self.integralDecay
    
    -- Update integral with clamping
    self.integral = self.integral + error * self.dt
    self.integral = utils.clamp(self.integral, -self.maxIntegral, self.maxIntegral)
    
    local derivative = (error - self.prevError) / self.dt
    self.prevError = error
    return self.kp * error + self.ki * self.integral + self.kd * derivative
end

return PID
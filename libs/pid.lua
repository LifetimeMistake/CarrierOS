local utils = require("libs.utils")

local PID = {}
PID.__index = PID

function PID:new(kp, ki, kd, dt)
    return setmetatable({
        kp = kp,
        ki = ki,
        kd = kd,
        dt = dt,
        prevError = 0,
        integral = 0,
    }, self)
end

function PID:compute(setpoint, current)
    local error = setpoint - current
    self.integral = self.integral + error * self.dt
    local derivative = (error - self.prevError) / self.dt
    self.prevError = error
    return self.kp * error + self.ki * self.integral + self.kd * derivative
end

return PID
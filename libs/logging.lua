local RingBuffer = require("libs.ringBuffer")

local LogLevel = {
    DEBUG = 0,
    INFO = 1,
    WARN = 2,
    ERROR = 3
}

LogLevel.tostring = function(level)
    if level == LogLevel.DEBUG then
        return "DEBUG"
    end
    if level == LogLevel.INFO then
        return "INFO"
    end
    if level == LogLevel.WARN then
        return "WARN"
    end
    if level == LogLevel.ERROR then
        return "ERROR"
    end

    return nil
end

LogLevel.fromstring = function(level)
    if level == "DEBUG" then
        return LogLevel.DEBUG
    end
    if level == "INFO" then
        return LogLevel.INFO
    end
    if level == "WARN" then
        return LogLevel.WARN
    end
    if level == "ERROR" then
        return LogLevel.ERROR
    end

    return nil
end

local Logger = {}
Logger.__index = Logger

function Logger.new(capacity)
    return setmetatable({
        ringBuffer = RingBuffer.new(capacity or 100),
        logHook = nil
    }, Logger)
end

function Logger:log(level, message)
    self.ringBuffer:push(level, message)
    if self.logHook then
        self.logHook(level, message)
    end
end

function Logger:debug(message)
    self:log(LogLevel.DEBUG, message)
end

function Logger:info(message)
    self:log(LogLevel.INFO, message)
end

function Logger:warn(message)
    self:log(LogLevel.WARN, message)
end

function Logger:error(message)
    self:log(LogLevel.ERROR, message)
end

function Logger:setHook(hook)
    self.logHook = hook
end

function Logger:iter()
    return self.ringBuffer:iter()
end

local logging = {
    Logger = Logger,
    LogLevel = LogLevel
}

return logging
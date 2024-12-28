local ko = require("system.ko")
local logging = require("libs.logging")
local Logger, LogLevel = logging.Logger, logging.LogLevel

settings.define("kernel.logging.capacity", {
    default = 100,
    description = "[[The kernel's ring buffer capacity]]",
    type = "number"
})
settings.define("kernel.logging.log_level", {
    default = "INFO",
    description = "[[The kernel's log hook level]]",
    type = "string"
})

local logLevel = LogLevel.fromstring(settings.get("kernel.logging.log_level")) or LogLevel.INFO
local instance = Logger.new(settings.get("kernel.logging.capacity", 100))

local function wrapLogHook(hook)
    return function (level, message)
        if level < logLevel then
            return
        end

        hook(level, message)
    end
end

local exports = {
    debug = function(msg)
        instance:debug(msg)
    end,
    info = function(msg)
        instance:info(msg)
    end,
    warn = function(msg)
        instance:warn(msg)
    end,
    error = function(msg)
        instance:error(msg)
    end,
    log = function(level, msg)
        local levelNum = LogLevel.fromstring(level)
        if levelNum == nil then
            error("Invalid log level: " .. level)
        end
        instance:log(levelNum, msg)
    end,
    iterBuffer = function()
        return instance:iter()
    end,
    getLevel = function()
        return logLevel
    end,
    setLevel = function(level)
        local levelNum = LogLevel.fromstring(level)
        if levelNum == nil then
            error("Invalid log level: " .. level)
        end
        logLevel = levelNum
    end,
    setHook = function(hook_func)
        if hook_func then
            hook_func = wrapLogHook(hook_func)
        end
        instance:setHook(hook_func)
    end,
    LogLevel = LogLevel
}

_G.printk = function (...)
    local lines = {...}
    for _, line in ipairs(lines) do
        instance:info(line)
    end
end

_G.log = {
    debug = exports.debug,
    info = exports.info,
    warn = exports.warn,
    error = exports.error
}

exports.setHook(function(level, message)
    level = LogLevel.tostring(level)
    print(string.format("[%s] %s", level, message))
end)

return ko.subsystem("logging", exports)
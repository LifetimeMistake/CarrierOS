local ko = require("system.ko")
local process = kernel.getSubsystem("process")

local exports = {}
local publishedAPIs = {}

-- Check if the current process is privileged
local function checkPrivileged()
    local pid = process.getCurrentProcessID()
    if not pid then
        log.error("Used userspace API factory from kernel-space. Aborting.")
        error("Kernel error")
    end
    
    local proc = process.getProcessObject(pid)
    if not proc.privileged then
        error("Permission denied", 3)
    end

    return proc
end

function exports.publish(name, api, pid)
    if type(name) ~= "string" then
        error("API name must be a string", 2)
    end
    
    if type(api) ~= "table" then
        error("API must be a table", 2)
    end

    local proc = process.getProcessObject(pid)
    if publishedAPIs[name] then
        error("API already exists", 2)
    end

    proc.data.publishedAPIs[name] = api
    publishedAPIs[name] = api

    log.info(string.format("API published: %s by process %d", name, proc.pid))
end

function exports.unpublish(name, pid)
    if type(name) ~= "string" then
        error("API name must be a string", 2)
    end

    if not publishedAPIs[name] then
        error("API does not exist", 2)
    end

    local proc = process.getProcessObject(pid)
    proc.data.publishedAPIs[name] = nil
    publishedAPIs[name] = nil

    log.info(string.format("API unpublished: %s from process %d", name, proc.pid))
end

local api = {}

function api.publish(name, api)
    if type(name) ~= "string" then
        error("API name must be a string", 2)
    end
    
    if type(api) ~= "table" then
        error("API must be a table", 2)
    end

    local proc = checkPrivileged()
    exports.publish(name, api, proc.pid)
end

-- Userspace-facing unpublish API with permission checks
function api.unpublish(name)
    if type(name) ~= "string" then
        error("API name must be a string", 2)
    end

    local proc = checkPrivileged()
    
    if not publishedAPIs[name] then
        error("API does not exist", 2)
    end

    -- Check if this process owns the API
    if not proc.data.publishedAPIs or not proc.data.publishedAPIs[name] then
        error("Permission denied", 2)
    end

    exports.unpublish(name, proc.pid)
end

process.registerCreateHook(function(proc)
    proc.data.publishedAPIs = {}
    local mt = {
        __index = function(t, k)
            local gk = rawget(proc.env, k)
            if gk then
                return gk
            end

            return publishedAPIs[k]
        end
    }
    
    setmetatable(proc.env, mt)
    proc.env.api_factory = api
end)

-- Hook process exit to clean up published APIs
process.registerExitHook(function(proc)
    for name, _ in pairs(proc.data.publishedAPIs) do
        log.debug(string.format("Cleaning up API '%s' from process %d", name, proc.pid))
        publishedAPIs[name] = nil
    end
end)

return ko.subsystem("api_factory", exports)

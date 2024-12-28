local ko = require("system.ko")
local logging = require("libs.logging")
local Logger = logging.Logger

local services = {}
local exports = {}

-- Service status constants
local SERVICE_STATUS = {
    STOPPED = "stopped",
    RUNNING = "running",
    FAILED = "failed"
}

-- Restart policy parser
local function parseRestartPolicy(policy)
    if not policy then return { type = "no" } end
    
    if policy == "no" or policy == "always" then
        return { type = policy }
    end
    
    local ptype, limit = policy:match("^(on%-failure):(%d+)$")
    if ptype and limit then
        return { type = ptype, limit = tonumber(limit) }
    end
    
    error("Invalid restart policy: " .. policy)
end

-- Register a new service
function exports.register(name, filepath, options)
    if services[name] then
        error("Service already exists: " .. name)
    end
    
    if not fs.exists(filepath) or fs.isDir(filepath) then
        error("Service file does not exist: " .. filepath)
    end
    
    options = options or {}
    local restartPolicy = parseRestartPolicy(options.restartPolicy)
    local logger = Logger.new(options.loggerCapacity or 100)
    
    services[name] = {
        name = name,
        filepath = filepath,
        status = SERVICE_STATUS.STOPPED,
        restartPolicy = restartPolicy,
        failureCount = 0,
        process = nil,
        logger = logger,
        env = options.env or {}
    }
    
    log.info("Service created: " .. name)
    return true
end

-- Start a service
function exports.start(name)
    local service = services[name]
    if not service then
        error("Service not found: " .. name)
    end
    
    if service.status == SERVICE_STATUS.RUNNING then
        return false, "Service already running"
    end
    
    -- Create service environment
    local env = {
        print = function(...) 
            for _, v in ipairs({...}) do
                service.logger:info(v)
            end
        end,  -- Override print with logger.info
        log = service.logger
    }
    
    -- Merge with user-provided environment
    for k, v in pairs(service.env) do
        env[k] = v
    end
    
    -- Create the process
    service.process = kernel.process.runFile(
        service.filepath,
        nil,  -- no args
        false,  -- non-privileged by default
        env
    )
    
    service.status = SERVICE_STATUS.RUNNING
    service.logger:info("Service started")
    log.info("Service started: " .. name)
    return true
end

-- Stop a service
function exports.stop(name)
    local service = services[name]
    if not service then
        error("Service not found: " .. name)
    end
    
    if service.status ~= SERVICE_STATUS.RUNNING then
        return false, "Service not running"
    end
    
    kernel.process.kill(service.process.pid)
    service.status = SERVICE_STATUS.STOPPED
    service.process = nil
    service.logger:info("Service stopped")
    log.info("Service stopped: " .. name)
    return true
end

-- Unregister a service
function exports.unregister(name)
    local service = services[name]
    if not service then
        error("Service not found: " .. name)
    end
    
    if service.status == SERVICE_STATUS.RUNNING then
        exports.stop(name)
    end
    
    services[name] = nil
    log.info("Service deleted: " .. name)
    return true
end

-- Get service status
function exports.status(name)
    local service = services[name]
    if not service then
        error("Service not found: " .. name)
    end
    
    return {
        name = service.name,
        status = service.status,
        pid = service.process and service.process.pid or nil,
        failureCount = service.failureCount,
        restartPolicy = service.restartPolicy,
        filepath = service.filepath,
        logger = service.logger
    }
end

-- List all services
function exports.list()
    local result = {}
    for name, service in pairs(services) do
        result[name] = exports.status(name)
    end
    return result
end

local function checkPrivileged()
    local pid = kernel.process.getCurrentProcessID()
    if not pid then
        log.error("Used userspace services API from kernel-space. Aborting.")
        error("Kernel error")
    end
    
    local proc = kernel.process.getProcessObject(pid)
    if not proc.privileged then
        error("Permission denied", 3)
    end
end

local servicesAPI = {}
-- Read-only operations (available to all processes)
function servicesAPI.status(name)
    local status = exports.status(name)
    -- Don't expose internal logger object to userspace
    status.logger = nil
    return status
end

function servicesAPI.list()
    local list = exports.list()
    -- Don't expose internal logger objects to userspace
    for _, status in pairs(list) do
        status.logger = nil
    end
    return list
end

function servicesAPI.getLogs(name)
    local service = services[name]
    if not service then
        error("Service not found: " .. name)
    end
    
    local logs = {}
    for entry in service.logger:iter() do
        table.insert(logs, {
            level = logging.LogLevel.tostring(entry.level),
            message = entry.message,
            timestamp = entry.timestamp
        })
    end
    return logs
end

-- Management operations (requires privilege check)
function servicesAPI.register(name, filepath, options)
    checkPrivileged()
    return exports.register(name, filepath, options)
end

function servicesAPI.unregister(name)
    checkPrivileged()
    return exports.unregister(name)
end

function servicesAPI.start(name)
    checkPrivileged()
    return exports.start(name)
end

function servicesAPI.stop(name)
    checkPrivileged()
    return exports.stop(name)
end

-- Inject API into process environment
kernel.process.registerCreateHook(function(process)
    process.env.services = servicesAPI
end)

-- Handle process exit for all services
kernel.process.registerExitHook(function(proc)
    for _, service in pairs(services) do
        if service.process and proc.pid == service.process.pid then
            service.status = SERVICE_STATUS.STOPPED
            service.process = nil
            
            if proc.error then
                service.status = SERVICE_STATUS.FAILED
                service.failureCount = service.failureCount + 1
                service.logger:error("Service failed:", tostring(proc.error))
                log.error(string.format("Service %s failed: %s", service.name, tostring(proc.error)))
            else
                log.info(string.format("Service %s exited normally", service.name))
            end
            
            -- Handle restart policy
            if service.restartPolicy.type == "always" or 
               (service.restartPolicy.type == "on-failure" and 
                proc.error and 
                service.failureCount <= service.restartPolicy.limit) then
                service.logger:info("Restarting service due to policy:", service.restartPolicy.type)
                exports.start(service.name)
            end
            break
        end
    end
end)

-- Create and return the kernel subsystem
return ko.subsystem("services", exports)

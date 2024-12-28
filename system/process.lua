local ko = require("system.ko")

settings.define("kernel.process.limit", {
    default = 32,
    description = "[[The maximum number of tasks that can be running at any time]]",
    type = "number"
})

local processLimit = settings.get("kernel.process.limit")
local processes = {}
local coroutines = {}
local processCounter = 0
local cleanupHooks = {}
local createHooks = {}
local exports = {}

local function generatePID()
    processCounter = processCounter + 1
    return processCounter
end

local function createSafeEnvironment()
    local env = {}
    for key, value in pairs(_G) do
        if not kernel.isKernelExport(key) then
            env[key] = value
        end
    end

    env._G = env
    return env
end

local function executeHooks(hooks, ...)
    for _, hook in ipairs(hooks) do
        local ok, err = pcall(hook, ...)
        if not ok then
            log.error("[process] Hook execution failed: " .. tostring(err))
        end
    end
end

local function makeEntrypoint(entrypoint, env)
    return function(...)
        setfenv(entrypoint, env)
        return entrypoint(...)
    end
end

local function createProcessObject(name, env, isolated)
    local processEnv
    if isolated then
        if not env then
            error("Must provide an environment to run in isolated mode", 2)
        end

        processEnv = env
    else
        processEnv = createSafeEnvironment()
        if env then
            for k,v in pairs(env) do
                processEnv[k] = v
            end
        end
    end

    local process = {
        pid = generatePID(),
        name = name or "<unnamed>",
        env = processEnv,
        data = {},
        status = "running",
    }

    executeHooks(createHooks, process)
    return process
end

local function submitProcessObject(po, entrypoint)
    log.debug("Spawning process " .. po.pid)

    local wrappedEntrypoint = coroutine.create(makeEntrypoint(entrypoint, po.env))
    po.entrypoint = wrappedEntrypoint
    processes[po.pid] = po
    coroutines[wrappedEntrypoint] = po.pid
    return po
end

function exports.runFunc(name, entrypoint, env, isolated)
    if #processes >= processLimit then
        error("Process limit reached", 2)
    end
    if type(entrypoint) ~= "function" then
        error("Entrypoint must be a function", 2)
    end

    local process = createProcessObject(name, env, isolated)
    return submitProcessObject(process, entrypoint)
end

function exports.runFile(path, args, env, isolated)
    if type(path) ~= "string" then
        error("Path must be a string", 2)
    end

    if fs.isDir(path) or not fs.exists(path) then
        error("Specified file does not exist", 2)
    end
    
    local name = fs.getName(path)
    local process = createProcessObject(name, env, isolated)

    local fileMain, err = loadfile(path, nil, process.env)
    if not fileMain or err then
        if not err or err == "" then
            err = "loadfile failed with unknown error"
        end
        log.error(string.format("Failed to load image '%s': '%s'", path, err))
        error("Failed to load image")
    end

    local entrypoint
    if args and #args ~= 0 then
        entrypoint = function()
            fileMain(table.unpack(args))
        end
    else
        entrypoint = fileMain
    end

    return submitProcessObject(process, entrypoint)
end

function exports.kill(pid, error)
    local process = processes[pid]
    if not process then
        error("Invalid PID", 2)
    end

    process.status = "terminated"
    process.error = error

    -- Execute cleanup hooks
    executeHooks(cleanupHooks, process)

    processes[pid] = nil
    -- This should be cleaned up, but we have no mechanism for tracking threads
    -- coroutines[process.entrypoint] = nil

    log.info(string.format("Process killed: %d, reason: %s", pid, tostring(error)))
end

function exports.suspend(pid)
    local process = processes[pid]
    if not process then
        error("Invalid PID", 2)
    end
    process.status = "suspended"
end

function exports.resume(pid)
    local process = processes[pid]
    if not process then
        error("Invalid PID", 2)
    end
    process.status = "running"
end

function exports.getProcessObject(pid)
    local process = processes[pid]
    if not process then
        error("Invalid PID", 2)
    end
    
    return process
end

function exports.processExists(pid)
    return processes[pid] ~= nil
end

function exports.list()
    local list = {}
    for pid, process in pairs(processes) do
        table.insert(list, exports.getProcessObject(pid))
    end
    return list
end

function exports.runScheduler()
    local eventData = { n = 0 }
    while true do
        local hasProcesses = false
        for _, process in pairs(processes) do
            hasProcesses = true
            break
        end

        -- Exit if there are no active processes
        if not hasProcesses then
            printk("All processes have exited. Exiting kernel scheduler.")
            return
        end

        for pid, process in pairs(processes) do
            if process.status == "running" and coroutine.status(process.entrypoint) ~= "dead" then
                local ok, filter = coroutine.resume(process.entrypoint, table.unpack(eventData, 1, eventData.n))
                if not ok then
                    printError("Error in process " .. pid .. ": " .. tostring(filter))
                    if processes[pid] then
                        exports.kill(pid, filter)
                    end
                else
                    process.filter = filter
                end
            end

            -- Terminate dead processes
            if coroutine.status(process.entrypoint) == "dead" and processes[pid] then
                exports.kill(pid)
            end
        end

        -- Wait for events and pass them to processes
        eventData = table.pack(os.pullEventRaw())
    end
end

function exports.registerExitHook(hook)
    table.insert(cleanupHooks, hook)
end

function exports.registerCreateHook(hook)
    table.insert(createHooks, hook)
end

function exports.getCurrentProcessID()
    local co = coroutine.running()
    return coroutines[co] or nil -- Kernel space has no PID
end

-- Export some modified functions
-- Wrap the coroutine library to keep track of unmanaged coroutines
local safeCoroutineCreate = function(f, e)
    local co = f(e)
    local pid = exports.getCurrentProcessID()
    if not pid then
        log.warn("Used userspace coroutine library from kernel-space. Or is kernel-space being leaked?")
        return co
    end

    coroutines[co] = pid
    return co
end

local safeCoroutineLib = {
    create = function(f)
        return safeCoroutineCreate(coroutine.create, f)
    end,
    resume = coroutine.resume,
    running = coroutine.running,
    status = coroutine.status,
    wrap = function(f)
        return safeCoroutineCreate(coroutine.wrap, f)
    end,
    yield = coroutine.yield
}

-- Wrap os library
local safeOSLib = {}
for k,v in pairs(os) do
    safeOSLib[k] = v
end

-- Override os.run() with an implementation using the kernel scheduler
safeOSLib.run = function(tEnv, sPath, ...)
    log.info("run")
    local parentPID = exports.getCurrentProcessID()
    if parentPID == nil then
        log.warn("Used userspace os.run() call from kernel-space. Or is kernel-space being leaked?")
    else
        -- Share environment with parent
        local parent = exports.getProcessObject(parentPID)
        tEnv = setmetatable(tEnv, { __index = parent.env })
    end
    -- Create a process for the file
    local childProcess = exports.runFile(sPath, {...}, tEnv, true)

    -- Wait for the process to finish
    while true do
        if childProcess.status == "terminated" then
            if childProcess.error then
                if childProcess.error ~= "" then
                    printError(tostring(childProcess.error))
                end
                return false
            end

            return true
        end

        coroutine.yield()
    end
end

exports.registerCreateHook(function(process)
    process.env.coroutine = safeCoroutineLib
    process.env.os = safeOSLib
end)

return ko.subsystem("process", exports)
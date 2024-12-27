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

function exports.runFunc(name, entrypoint, env, isolated)
    if #processes >= processLimit then
        error("Process limit reached", 2)
    end
    if type(entrypoint) ~= "function" then
        error("Entrypoint must be a function", 2)
    end

    local processEnv
    if isolated then
        if not env then
            error("Must provide an environment to run in isolated mode", 2)
        end

        processEnv = env
    else
        local rootEnv = createSafeEnvironment()
        processEnv = setmetatable(env or {}, { __index = rootEnv })
    end

    local pid = generatePID()
    local wrappedEntrypoint = coroutine.create(makeEntrypoint(entrypoint, processEnv))

    local process = {
        pid = pid,
        name = name or "<unnamed>",
        entrypoint = wrappedEntrypoint,
        env = processEnv,
        data = {},
        status = "running",
    }

    -- Execute create hooks
    executeHooks(createHooks, process)

    processes[pid] = process
    coroutines[wrappedEntrypoint] = pid
    return pid
end

function exports.runFile(path, args, env, isolated)
    if type(path) ~= "string" then
        error("Path must be a string", 2)
    end

    if fs.isDir(path) or not fs.exists(path) then
        error("Specified file does not exist", 2)
    end
    
    local processEnv
    if isolated then
        if not env then
            error("Must provide an environment to run in isolated mode", 2)
        end

        processEnv = env
    else
        local rootEnv = createSafeEnvironment()
        processEnv = setmetatable(env or {}, { __index = rootEnv })
    end

    local fileMain, err = loadfile(path, nil, processEnv)
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

    local name = fs.getName(path)
    return exports.runFunc(name, entrypoint, processEnv, true)
end

function exports.kill(pid)
    local process = processes[pid]
    if not process then
        error("Invalid PID", 2)
    end
    process.status = "terminated"

    -- Execute cleanup hooks
    executeHooks(cleanupHooks, pid, process.data)

    processes[pid] = nil
    coroutines[process.entrypoint] = nil
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

function exports.getInformation(pid)
    local process = processes[pid]
    if not process then
        error("Invalid PID", 2)
    end
    return {
        pid = process.pid,
        name = process.name,
        status = process.status,
    }
end

function exports.list()
    local list = {}
    for pid, process in pairs(processes) do
        table.insert(list, exports.getInformation(pid))
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
                        exports.kill(pid)
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

function exports.addCleanupHook(hook)
    table.insert(cleanupHooks, hook)
end

function exports.addCreateHook(hook)
    table.insert(createHooks, hook)
end

function exports.getCurrentProcessID()
    local co = coroutine.running()
    return coroutines[co] or nil -- Kernel space has no PID
end

return ko.subsystem("process", exports)
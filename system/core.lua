if kernel then
    error("Kernel object already registered", 2)
end

-- Protect kernel and exports
local kernel = {
    subsystems = {},
    exports = {},
    kthreads = {}
}

local function createKernelOverlay()
    local ko = kernel
    local G = _G
    local rawget = rawget

    local overlay = setmetatable({}, {
        __index = function (_, k)
            return ko.exports[k] or rawget(G, k)
        end,
        __newindex = function (_, k, v)
            if ko.exports[k] then
                error("Kernel export collision: " .. k, 2)
            end

            ko.exports[k] = v
        end
    })

    setmetatable(_G, {
        __index = overlay,
        __newindex = function (_, k, v)
            overlay[k] = v
        end
    })

    return overlay
end

local kOverlay = createKernelOverlay()
setfenv(1, kOverlay)

_G.kernel = kernel

-- Set up require for the kernel space
local make_package = dofile("/rom/modules/main/cc/require.lua").make
local require
do
    local requireEnv = { kernel = kernel }
    requireEnv.require, requireEnv.package = make_package(requireEnv, "/")
    requireEnv = setmetatable(requireEnv, { __index = _ENV })
    require = requireEnv.require
end

function kernel.loadSubsystem(name, api, load_func)
    if kernel.subsystems[name] then
        error("Subsystem '" .. name .. "' is already registered", 2)
    end

    if kernel[name] then
        error("Subsystem name '" .. name .. "' is reserved by the kernel")
    end

    printk("Loading subsystem: " .. name)
    kernel.subsystems[name] = api
    kernel[name] = api
    
    if load_func then
        load_func(kernel)
    end
end

function kernel.getSubsystem(name)
    return kernel.subsystems[name] or error("Kernel subsystem '" .. name .. "' is not loaded")
end

function kernel.listSubsystems()
    local t = {}
    for name in pairs(kernel.subsystems) do
        table.insert(t, name)
    end

    return t
end

function kernel.isKernelExport(name)
    return kernel.exports[name] ~= nil
end

local function requireSubsystem(name)
    local ko = require(name)
    if not ko or not ko.is_kernel_subsystem then
        error("Loaded file is not a valid kernel subsystem", 2)
    end

    kernel.loadSubsystem(ko.name, ko.exports, ko.load_func)
end

settings.define("kernel.init_program", {
    default = "",
    description = "[[The program to run after the kernel finishes booting. Starts the CC shell if this setting is invalid.]]",
    type = "string"
})

settings.define("kernel.debug", {
    default = false,
    description = "[[Exposes the kernel interface to userspace if enabled.]]",
    type = "boolean"
})

function kernel.registerKThread(name, thread_func)
    if type(thread_func) ~= "function" then
        error("Thread function must be a function", 2)
    end
    
    local co = coroutine.create(thread_func)
    table.insert(kernel.kthreads, {
        name = name,
        co = co
    })
    return co
end

function kernel.runKernelScheduler()
    local eventData = { n = 0 }
    while true do
        local hasThreads = false
        for i, thread in ipairs(kernel.kthreads) do
            if coroutine.status(thread.co) ~= "dead" then
                hasThreads = true
                local ok, err = coroutine.resume(thread.co, eventData)
                if not ok then
                    local name = thread.name or ("kthread:" .. i)
                    printError("Error in kernel thread " .. name .. ": " .. tostring(err))
                    table.remove(kernel.kthreads, i)
                end
            else
                table.remove(kernel.kthreads, i)
            end
        end
        
        if not hasThreads then
            break
        end
        
        eventData = table.pack(os.pullEventRaw())
    end
end

local function boot()
    -- Load kernel subsystems
    requireSubsystem("system.logging")
    requireSubsystem("system.process")
    requireSubsystem("system.peripheral")
    requireSubsystem("system.services")

    if settings.get("kernel.debug", false) then
        kernel.process.registerCreateHook(function(process)
            if process.privileged then
                process.env.kernel = kernel
            end
        end)
    end

    kernel.process.registerCreateHook(function(process)
        process.env.getKernelLog = function()
            local logs = {}
            for entry in kernel.logging.iterBuffer() do
                table.insert(logs, {
                    level = kernel.logging.LogLevel.tostring(entry.level),
                    message = entry.message,
                    timestamp = entry.timestamp
                })
            end
            return logs
        end
    end)

    printk("Kernel load complete")
    printk("Loaded " .. #kernel.listSubsystems() .. " subsystems")

    printk("Bug workaround: Disabling multishell")
    settings.set("bios.use_multishell", false)
    
    printk("Transferring control to init process")
    -- Disable kernel logging to stdout
    kernel.logging.setHook(nil)
    -- Find init program
    local uInit = settings.get("kernel.init_program", "")
    local initPath
    if uInit ~= "" and fs.exists(uInit) and not fs.isDir(uInit) then
        initPath = uInit
    elseif term.isColour() and settings.get("bios.use_multishell") then
        initPath = "/rom/programs/advanced/multishell.lua"
    else
        initPath = "/rom/programs/shell.lua"
    end
    kernel.process.runFile(initPath, nil, true)
    
    printk("Starting kernel threads")
    kernel.runKernelScheduler()

    printk("Kernel finished. Halt.")
    for entry in kernel.logging.iterBuffer() do
        local level = kernel.logging.LogLevel.tostring(entry.level)
        print(string.format("[%s][%s] %s", entry.timestamp, level, entry.message))
    end
    os.sleep(10)
end

boot()
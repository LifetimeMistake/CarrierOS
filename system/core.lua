if kernel then
    error("Kernel object already registered", 2)
end

-- Protect kernel and exports
local kernel = {
    subsystems = {},
    exports = {}
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
local expect = require("cc.expect").expect
local exception = require "cc.internal.exception"

function kernel.loadSubsystem(name, api)
    if kernel.subsystems[name] then
        error("Subsystem '" .. name .. "' is already registered", 2)
    end

    if kernel[name] then
        error("Subsystem name '" .. name .. "' is reserved by the kernel")
    end

    printk("Loading subsystem: " .. name)
    kernel.subsystems[name] = api
    kernel[name] = api
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

    kernel.loadSubsystem(ko.name, ko.exports)
end

settings.define("kernel.init_program", {
    default = "",
    description = "[[The program to run after the kernel finishes booting. Starts the CC shell if this setting is invalid.]]",
    type = "string"
})

local function getPID()
    return kernel.process.getCurrentProcessID()
end

local function boot()
    -- Load kernel subsystems
    requireSubsystem("system.logging")
    requireSubsystem("system.process")

    printk("Kernel load complete")
    printk("Loaded " .. #kernel.listSubsystems() .. " subsystems")

    printk("Bug workaround: Disabling multishell")
    settings.set("bios.use_multishell", false)
    
    printk("Transferring control to init process")
    local uInit = settings.get("kernel.init_program", "")
    local initPath
    if uInit ~= "" and fs.exists(uInit) and not fs.isDir(uInit) then
        initPath = uInit
    elseif term.isColour() and settings.get("bios.use_multishell") then
        initPath = "/rom/programs/advanced/multishell.lua"
    else
        initPath = "/rom/programs/shell.lua"
    end
    
    kernel.process.runFile(initPath)
    kernel.process.runScheduler()

    printk("Kernel finished. Halt.")
    os.sleep(1)
end

boot()
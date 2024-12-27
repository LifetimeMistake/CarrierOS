if kernel then
    error("Kernel object already registered", 2)
end

_G.kernel = {}
kernel.subsystems = {}

-- Set up require for the kernel space
local make_package = dofile("/rom/modules/main/cc/require.lua").make
local require
do
    local kernelEnv = { kernel = kernel }
    kernelEnv.require, kernelEnv.package = make_package(kernelEnv, "/")
    kernelEnv = setmetatable(kernelEnv, { __index = _ENV })
    require = kernelEnv.require
end
local expect = require("cc.expect").expect
local exception = require "cc.internal.exception"

function kernel.loadSubsystem(name, api)
    if kernel.subsystems[name] then
        error("Subsystem '" .. name .. "' is already registered", 2)
    end

    printk("Loading subsystem: " .. name)
    kernel.subsystems[name] = api
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

local function requireSubsystem(name)
    local ko = require(name)
    if not ko or not ko.is_kernel_subsystem then
        error("Loaded file is not a valid kernel subsystem", 2)
    end

    kernel.loadSubsystem(ko.name, ko.exports)
end

local function boot()
    -- Load kernel subsystems
    requireSubsystem("system.logging")

    printk("Kernel load complete")
    printk("Loaded " .. #kernel.listSubsystems() .. " subsystems")

    printk("Starting init process")
    os.sleep(10)
end

boot()
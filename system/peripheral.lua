local ko = require("system.ko")
local process = kernel.getSubsystem("process")

local protected = {}
local exports = {}

function exports.protect(name, mode, ownerPID)
    if type(name) ~= "string" then
        error("Name must be a string", 2)
    end

    if not peripheral.isPresent(name) then
        error("Peripheral does not exist", 2)
    end

    -- mode contains r, mode contains w
    local protectRead, protectWrite = false, false
    if mode == "r" then
        protectRead = true
    elseif mode == "w" then
        protectWrite = true
    elseif mode == "rw" then
        protectRead = true
        protectWrite = true
    else
        error("Invalid protect mode", 2)
    end

    if protected[name] then
        error("Peripheral already protected", 2)
    end
    
    log.info(string.format("Peripheral protect: %s, mode: %s", name, mode))

    if ownerPID ~= nil then
        local process = kernel.process.getProcessObject(ownerPID)
        process.data.protectedPeripherals[name] = true
    end

    protected[name] = {
        protectRead = protectRead,
        protectWrite = protectWrite
    }
end

function exports.unprotect(name)
    if type(name) ~= "string" then
        error("Name must be a string", 2)
    end

    if not protected[name] then
        error("Peripheral not protected", 2)
    end

    log.info("Peripheral unprotect: " .. name)
    protected[name] = nil

    for _,process in ipairs(kernel.process.list()) do
        local p = process.data.protectedPeripherals
        if p[name] then
            p[name] = nil
            break
        end
    end
end

function exports.isProtected(name)
    if type(name) ~= "string" then
        error("Name must be a string", 2)
    end

    return protected[name] ~= nil
end

-- Hook into the peripheral API available inside processes and enforce protect rules
-- Kernel space is unaffected by the protect APIs
local function hasAccess(type, peripheral)
    local protect = protected[peripheral]
    if not protect then
        return true
    end

    local pid = kernel.process.getCurrentProcessID()
    if pid == nil then
        log.warn("Used userspace peripheral API from kernel-space. Or is kernel-space being leaked?")
    end

    local process = kernel.process.getProcessObject(pid)
    if not process then
        log.error("[peripheral] Failed to fetch process object")
        return false
    end

    local isOwner = process.data.protectedPeripherals[peripheral] or false
    return isOwner or (type == "read" and not protect.protectRead) or (type == "write" and not protect.protectWrite)
end

local function hasReadAccess(peripheral)
    return hasAccess("read", peripheral)
end

local function hasWriteAccess(peripheral)
    return hasAccess("write", peripheral)
end

local safePeripheralLib = {}
for k,v in pairs(peripheral) do
    safePeripheralLib[k] = v
end

function safePeripheralLib.getNames()
    local names = peripheral.getNames()
    for i, k in ipairs(names) do
        if not hasReadAccess(k) then
            table.remove(names, i)
        end
    end

    return names
end

function safePeripheralLib.isPresent(name)
    if not hasReadAccess(name) then
        return false
    end

    return peripheral.isPresent(name)
end

function safePeripheralLib.getType(name)
    if not hasReadAccess(name) then
        return nil
    end

    return peripheral.getType(name)
end

function safePeripheralLib.hasType(name, peripheral_type)
    if not hasReadAccess(name) then
        return nil
    end

    return peripheral.hasType(name, peripheral_type)
end

function safePeripheralLib.getMethods(name)
    if not hasReadAccess(name) then
        return nil
    end

    return peripheral.getMethods(name)
end

function safePeripheralLib.call(name, method, ...)
    if not hasWriteAccess(name) then
        error("Peripheral '" .. name .. "' is protected")
    end

    return peripheral.call(name, method, ...)
end

function safePeripheralLib.wrap(name)
    if not hasWriteAccess(name) then
        error("Peripheral is exclusively locked")
    end

    return peripheral.wrap(name)
end

function safePeripheralLib.find(ty, filter)
    if type(ty) ~= "string" then
        error(string.format("bad argument #1 to 'find' (expected string, got %s)", type(ty)))
    end
    if type(ty) ~= "function" and type(ty) ~= "nil" then
        error(string.format("bad argument #2 to 'find' (expected function, got %s)", type(filter)))
    end

    local results = {}
    for _, name in ipairs(safePeripheralLib.getNames()) do
        if peripheral.hasType(name, ty) then
            local wrapped = safePeripheralLib.wrap(name)
            if filter == nil or filter(name, wrapped) then
                table.insert(results, wrapped)
            end
        end
    end

    return table.unpack(results)
end

function safePeripheralLib.isProtected(name)
    return exports.isProtected(name)
end

function safePeripheralLib.protect(name, mode)
    local pid = kernel.process.getCurrentProcessID()
    if not pid then
        log.error("Used userspace protect API from kernel-space. Aborting.")
        error("Kernel error")
    end

    exports.protect(name, mode, pid)
end

function safePeripheralLib.unprotect(name)
    local pid = kernel.process.getCurrentProcessID()
    if not pid then
        log.error("Used userspace protect API from kernel-space. Aborting.")
        error("Kernel error")
    end

    local process = kernel.process.getProcessObject(pid)
    if not process then
        log.error("[peripheral] Failed to fetch process object")
        error("Kernel error")
    end

    local isOwner = process.data.protectedPeripherals[name] or false
    if protected[name] and not isOwner then
        error("Permission denied", 2)
    end

    exports.unprotect(name)
end

-- Hook process create/exit
kernel.process.registerCreateHook(function(process)
    process.data.protectedPeripherals = {}
    process.env.peripheral = safePeripheralLib
end)

kernel.process.registerExitHook(function(process)
    for k,_ in pairs(process.data.protectedPeripherals) do
        if exports.isProtected(k) then
            log.debug(string.format("Freeing protected peripheral '%s' for process %d", k, process.pid))
            exports.unprotect(k)
            process.data.protectedPeripherals[k] = nil
        end
    end
end)

return ko.subsystem("peripheral", exports)
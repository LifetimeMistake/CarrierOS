local ko = {}

function ko.new()
    return {
        name = nil,
        is_kernel_subsystem = false,
        is_kernel_module = false,
        exports = nil,
        load_func = nil,
        unload_func = nil
    }
end

function ko.subsystem(name, exports, entrypoint)
    local subsystem = ko.new()
    subsystem.name = name
    subsystem.is_kernel_subsystem = true
    subsystem.exports = exports
    subsystem.load_func = entrypoint

    return subsystem
end

function ko.module(name, load_func, unload_func)
    local module = ko.new()
    module.name = name
    module.is_kernel_module = true
    module.load_func = load_func
    module.unload_func = unload_func
end

return ko
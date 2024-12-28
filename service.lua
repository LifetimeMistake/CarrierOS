-- Check if we're running in kernel environment
if not services then
    error("This utility requires the kernel services API")
end

local hasColors = term.isColor()

local function printUsage()
    print("Usage: service <command> [options]")
    print("Commands:")
    print("  list                     List all services")
    print("  status <name>            Show service status")
    print("  start <name>             Start a service")
    print("  stop <name>              Stop a service")
    print("  register <name> <path>   Register a new service")
    print("  unregister <name>        Unregister a service")
    print("  logs <name>              Show service logs")
end

local function formatServiceStatus(status)
    print(string.format("Service: %s", status.name))
    print(string.format("Status: %s", status.status))
    print(string.format("PID: %s", status.pid or "N/A"))
    print(string.format("Path: %s", status.filepath))
    print(string.format("Failures: %d", status.failureCount))
    print(string.format("Restart Policy: %s", status.restartPolicy.type))
    if status.restartPolicy.type == "on-failure" then
        print(string.format("Restart Limit: %d", status.restartPolicy.limit))
    end
end

local function formatServiceList(services)
    -- Find maximum lengths for columns
    local maxNameLen = 4  -- "NAME" header length
    local maxStatusLen = 6  -- "STATUS" header length
    
    for name, service in pairs(services) do
        maxNameLen = math.max(maxNameLen, #name)
        maxStatusLen = math.max(maxStatusLen, #service.status)
    end
    
    -- Create format string
    local fmt = string.format("%%-%ds  %%-%ds  %%s",
        maxNameLen, maxStatusLen)
    
    -- Print header
    print(string.format(fmt, "NAME", "STATUS", "PID"))
    print(string.rep("-", maxNameLen + maxStatusLen + 8))
    
    -- Sort services by name
    local sortedNames = {}
    for name in pairs(services) do
        table.insert(sortedNames, name)
    end
    table.sort(sortedNames)
    
    -- Print each service
    for _, name in ipairs(sortedNames) do
        local service = services[name]
        print(string.format(fmt,
            name,
            service.status,
            service.pid or "N/A"
        ))
    end
end

local function formatLogs(logs)
    for _, entry in ipairs(logs) do
        if hasColors then
            local color = colors.white
            if entry.level == "ERROR" then
                color = colors.red
            elseif entry.level == "WARN" then
                color = colors.yellow
            elseif entry.level == "DEBUG" then
                color = colors.lightGray
            end
            term.setTextColor(color)
        end
        
        print(string.format("[%s][%s] %s",
            entry.timestamp,
            entry.level,
            entry.message
        ))
    end
    
    if hasColors then
        term.setTextColor(colors.white)
    end
end

local function main(args)
    if #args < 1 then
        printUsage()
        return
    end
    
    local command = args[1]
    
    if command == "list" then
        local services = services.list()
        formatServiceList(services)
        
    elseif command == "status" then
        if #args < 2 then
            print("Error: Service name required")
            return
        end
        local status = services.status(args[2])
        formatServiceStatus(status)
        
    elseif command == "start" then
        if #args < 2 then
            print("Error: Service name required")
            return
        end
        local ok, err = services.start(args[2])
        if not ok then
            print("Error starting service: " .. tostring(err))
        else
            print("Service started successfully")
        end
        
    elseif command == "stop" then
        if #args < 2 then
            print("Error: Service name required")
            return
        end
        local ok, err = services.stop(args[2])
        if not ok then
            print("Error stopping service: " .. tostring(err))
        else
            print("Service stopped successfully")
        end
        
    elseif command == "register" then
        if #args < 3 then
            print("Error: Service name and path required")
            return
        end
        local ok, err = services.register(args[2], args[3])
        if not ok then
            print("Error registering service: " .. tostring(err))
        else
            print("Service registered successfully")
        end
        
    elseif command == "unregister" then
        if #args < 2 then
            print("Error: Service name required")
            return
        end
        local ok, err = services.unregister(args[2])
        if not ok then
            print("Error unregistering service: " .. tostring(err))
        else
            print("Service unregistered successfully")
        end
        
    elseif command == "logs" then
        if #args < 2 then
            print("Error: Service name required")
            return
        end
        local logs = services.getLogs(args[2])
        formatLogs(logs)
        
    else
        print("Unknown command: " .. command)
        printUsage()
    end
end

main({...}) 
local rpc = require("components.rpc")

-- Helper function to find the first wireless modem
local function findWirelessModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
            return side
        end
    end
    return nil
end

-- Helper function to create the global API structure
local function createGlobalAPI(client)
    -- Get list of all available services
    local success, services = client:listServices()
    if not success then
        error("Failed to list services: " .. services)
    end

    -- Create the global carrieros table
    _G.carrieros = {}

    -- First wrap the main carrieros service to get top-level functions
    local success, carrierosService = client:wrapService("carrieros")
    if success then
        -- Add all top-level functions to _G.carrieros
        for name, func in pairs(carrierosService) do
            _G.carrieros[name] = function(...)
                local success, result = func(...)
                if success then
                    return result
                else
                    error(result)
                end
            end
        end
    end

    -- Now wrap all other services
    for serviceName, _ in pairs(services) do
        if serviceName ~= "carrieros" then
            local success, service = client:wrapService(serviceName)
            if success then
                -- Create a table for the service
                local serviceTable = {}
                -- Add all methods to the service table
                for name, func in pairs(service) do
                    serviceTable[name] = function(...)
                        local success, result = func(...)
                        if success then
                            return result
                        else
                            error(result)
                        end
                    end
                end
                -- Add the service table to _G.carrieros
                _G.carrieros[serviceName] = serviceTable
            else
                print("Warning: Failed to wrap service " .. serviceName .. ": " .. service)
            end
        end
    end
end

-- Main program
local function main()
    local modemSide = findWirelessModem()
    if not modemSide then
        error("No wireless modem found")
    end

    -- Create RPC client
    local client = rpc.RPCClient.new(modemSide)

    -- Discover available servers
    local hosts = client:discover()
    if #hosts == 0 then
        error("No CarrierOS RPC servers found")
    end

    -- Print available servers
    print("Found " .. #hosts .. " CarrierOS servers:")
    for i, hostId in ipairs(hosts) do
        print(i .. ". Computer #" .. hostId)
    end

    -- If there's only one server, connect to it automatically
    local selectedHost
    if #hosts == 1 then
        print("Automatically connecting to the only available server...")
        selectedHost = hosts[1]
    else
        -- Ask user to select a server
        write("Select server (1-" .. #hosts .. "): ")
        local selection = tonumber(read())
        if not selection or selection < 1 or selection > #hosts then
            error("Invalid selection")
        end
        selectedHost = hosts[selection]
    end

    -- Connect to the selected server
    client:associate(selectedHost)
    print("Connected to computer #" .. selectedHost)

    -- Create the global API structure
    createGlobalAPI(client)
    print("CarrierOS API initialized")

    -- Keep the program running to maintain the connection
    print("Client is running. Press Ctrl+T to terminate.")
    while true do
        os.sleep(1)
    end
end

-- Run the program
main() 
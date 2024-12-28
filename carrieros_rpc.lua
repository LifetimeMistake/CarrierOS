local rpc = require("components.rpc")

-- Helper function to check if CarrierOS is available
local function isCarrierOSAvailable()
    return _G.carrieros ~= nil
end

-- Helper function to find the first wireless modem
local function findWirelessModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
            return side
        end
    end
    return nil
end

-- Helper function to create a proxy that checks API availability
local function createServiceProxy(api)
    local proxy = {}
    for k, v in pairs(api) do
        if type(v) == "function" then
            proxy[k] = function(...)
                if not isCarrierOSAvailable() then
                    error("CarrierOS API is no longer available")
                end
                return v(...)
            end
        end
    end
    return proxy
end

-- Main program
local function main()
    local modemSide = findWirelessModem()
    if not modemSide then
        error("No wireless modem found")
    end
    
    local server = rpc.RPCServer.new(modemSide)
    server:start()

    print("Waiting for CarrierOS to become available...")
    while not isCarrierOSAvailable() do
        os.sleep(1)
    end
    print("CarrierOS detected, registering services...")

    -- Create the main carrieros service for top-level functions
    local carrierosService = {}
    
    -- Register all available CarrierOS API endpoints
    for name, api in pairs(_G.carrieros) do
        if type(api) == "table" then
            -- Register table APIs as separate services
            local success = server:registerService(name, createServiceProxy(api))
            if success then
                print("Registered service: " .. name)
            end
        elseif type(api) == "function" then
            -- Add top-level functions to the carrieros service
            carrierosService[name] = function(...)
                if not isCarrierOSAvailable() then
                    error("CarrierOS API is no longer available")
                end
                return api(...)
            end
        end
    end
    
    -- Register the main carrieros service
    if next(carrierosService) then
        local success = server:registerService("carrieros", carrierosService)
        if success then
            print("Registered main CarrierOS service")
        end
    end

    print("RPC server is running...")
    
    -- Main loop
    while true do
        -- Check if CarrierOS is still available
        if not isCarrierOSAvailable() then
            print("CarrierOS is no longer available, shutting down...")
            server:stop()
            break
        end
        
        -- Handle RPC requests
        server:receive(1)
    end
end

-- Run the program
main() 
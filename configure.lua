-- Engine configuration script
local thrust_api = require("libs.thrusters")
local serialization = require("libs.serialization")
local consts = require("components.consts")

local function loadConfig()
    if not fs.exists(consts.THRUSTER_CONFIG_PATH) then
        return nil
    end
    
    local status, data = serialization.json.loadf(consts.THRUSTER_CONFIG_PATH)
    if not status then
        error("Failed to read thruster config: " .. data)
    end

    return data
end

-- Helper function to check for active redstone signal
local function isActive(integrator)
    local sides = {"top", "bottom", "left", "right", "front", "back"}
    for _, side in ipairs(sides) do
        if peripheral.call(integrator, "getInput", side) then
            return true
        end
    end
    return false
end

-- Discover all redstone integrators on the network
local function discoverIntegrators()
    local integrators = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "redstoneIntegrator" then
            table.insert(integrators, name)
        end
    end
    return integrators
end

-- Reset all integrators by turning off all outputs
local function resetIntegrators(integrators)
    for _, integrator in ipairs(integrators) do
        local wrapped = peripheral.wrap(integrator)
        local sides = {"top", "bottom", "left", "right", "front", "back"}
        for _, side in ipairs(sides) do
            wrapped.setOutput(side, false)
            wrapped.setAnalogOutput(side, 0)
        end
    end
end

-- Main script logic
local integrators = discoverIntegrators()
if #integrators == 0 then
    error("No redstone integrators found on the network!")
end

-- Reset all integrators before starting configuration
resetIntegrators(integrators)

local thrusterMap = loadConfig()
if thrusterMap then
    print("Loaded configuration from file.")
    local allConnected = thrust_api.validateEngineMap(thrusterMap)
    if allConnected then
        print("All integrators are connected. Configuration is valid.")
    else
        print("Some integrators are missing.")
        for engine, config in pairs(thrusterMap) do
            if not peripheral.isPresent(config.integrator) then
                print("Error: Integrator for thruster " .. engine .. " is not connected.")
            end
        end
    end

    print("Would you like to reconfigure? (yes/no)")
    local answer = read()
    if answer:lower() ~= "yes" then
        if allConnected then
            print("Exiting.")
        else
            print("Configuration incomplete. Exiting.")
        end
        
        return
    end
end

-- Map to store engine-to-integrator mapping
thrusterMap = {}

-- Configuration process
for _, engine in ipairs(consts.THRUSTER_NAMES) do
    print("Please configure thruster " .. engine .. "...")

    local detectedIntegrator = nil

    -- Wait for the user to place a redstone source
    while not detectedIntegrator do
        for i, integrator in ipairs(integrators) do
            if isActive(integrator) then
                detectedIntegrator = integrator
                table.remove(integrators, i) -- Remove from future consideration
                break
            end
        end
        os.sleep(0.5) -- Prevent busy-waiting
    end

    print("Detected thruster " .. engine .. ": " .. detectedIntegrator)

    print("Enter thruster force map type (e.g. main, manouvering):")
    local type = read()

    -- Ask user for output sides
    print("Enter the side for power control (e.g., top, bottom):")
    local powerSide = read()
    print("Enter the side for thrust control (e.g., left, right):")
    local thrustSide = read()

    print("Enter direction vector (x,y,z):")
    local thrustVectorInput = read() -- User enters a comma-separated vector like "1,0,0"
    local thrustVector = {}

    -- Parse the input into numeric components
    for value in string.gmatch(thrustVectorInput, "([^,]+)") do
        table.insert(thrustVector, tonumber(value))
    end

    -- Validate the input
    if #thrustVector ~= 3 then
        error("Invalid thrust vector. Please enter 3 numeric components separated by commas.")
    end

    thrustVector = {
        x = thrustVector[1],
        y = thrustVector[2],
        z = thrustVector[3]
    }
    
    print("Enable thrust direction control? (yes/no)")
    local directionSide = nil
    local normalDirection = "normal"
    if read():lower() == "yes" then
        print("Enter direction control side (e.g. front, back)")
        directionSide = read()
        print("Is normal direction reversed? (yes/no)")
        if read():lower() == "yes" then
            normalDirection = "reversed"
        end
    end

    thrusterMap[engine] = {
        type = type,
        integrator = detectedIntegrator,
        powerSide = powerSide,
        thrustSide = thrustSide,
        directionSide = directionSide,
        thrustVector = thrustVector,
        normalDirection = normalDirection
    }

    -- Wait for the signal to turn off
    while isActive(detectedIntegrator) do
        os.sleep(0.5)
    end
end

-- Save the final mapping
serialization.json.dumpf(thrusterMap, consts.THRUSTER_CONFIG_PATH)

-- Output the final mapping
do
    print("\nConfiguration complete! Thruster map:")
    for thruster, config in pairs(thrusterMap) do
        print(
            string.format("%s -> T: %s, Ig: %s, Ps: %s, Ts: %s, Ds: %s, V: {%d, %d, %d}, Dn: %s", 
            thruster, 
            config.type,
            config.integrator, 
            config.powerSide, 
            config.thrustSide, 
            config.directionSide or "N/A",
            config.thrustVector.x,
            config.thrustVector.y,
            config.thrustVector.z,
            config.normalDirection
        )
    )
    end
end
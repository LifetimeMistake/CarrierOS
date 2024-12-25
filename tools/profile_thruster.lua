local thrust_api = dofile("apis/thrusters.lua")
local serialization = dofile("apis/serialization.lua")
local math3d = dofile("apis/math3d.lua")

print("Enter integrator ID:")
local integratorId = read()

if not peripheral.isPresent(integratorId) then
    error("Invalid integrator ID")
end

-- Ask user for output sides
print("Enter the side for power control (e.g., top, bottom):")
local powerSide = read()
print("Enter the side for thrust control (e.g., left, right):")
local thrustSide = read()

local engine = {
    integrator = integratorId,
    powerSide = powerSide,
    thrustSide = thrustSide
}

local engineMap = {
    main = engine
}

local status, api = thrust_api.init(engineMap, 1)
if not status then
    error("Failed to init engine API: " .. api)
end

-- Start testing the thruster
local delta_t = 0.1
local simulation_length = 3
local required_stable_ticks = 100
local stable_threshold = 0.5
local data = {}
local main = api.thrusters.main

main.setPowerState(true)
main.setLevel(0)

local mass = ship.getMass()

local y_readings = {}
local function testEquilibrium()
    local pos = ship.getWorldspacePosition()
    local y = pos.y

    -- Add the current Y position to the readings
    table.insert(y_readings, y)

    -- Maintain a rolling window of readings to analyze stability
    if #y_readings > required_stable_ticks then
        table.remove(y_readings, 1)
    end

    -- Check for stability in the readings
    if #y_readings == required_stable_ticks then
        local min_y = math.min(table.unpack(y_readings))
        local max_y = math.max(table.unpack(y_readings))

        if (max_y - min_y) <= stable_threshold then
            return (min_y + max_y) / 2  -- Return the stable Y level
        else
            y_readings = {} -- Clear readings if not stable
        end
    end

    return nil
end

local function air_pressure(height)
    local offset = math.exp(-1.3333333333333333)  -- Precomputed constant
    local base_altitude = 64.0
    local decay_rate = 192.0

    local air_press = (math.exp(-(height - base_altitude) / decay_rate) - offset) / (1.0 - offset)
    return math.max(0.0, math.min(air_press, 1.0))  -- Clamp to [0, 1]
end

local base_y = ship.getWorldspacePosition().y
-- Main simulation loop
for i = 1, 15 do
    -- Set thruster level and wait for spin up
    main.setRawSignal(15 - i)
    os.sleep(3)

    local stableY
    while true do
        stableY = testEquilibrium()
        if stableY then
            break
        end

        os.sleep(delta_t)
    end

    local measured_accelerations = {}
    local elapsed = 0
    local last_velocity = ship.getVelocity()
    os.sleep(delta_t)

    while elapsed <= simulation_length do
        local velocity = ship.getVelocity()
        local delta_v = math3d.magnitude(math3d.subtract(velocity, last_velocity))
        local acceleration = delta_v / delta_t
        if math.abs(stableY - base_y) > 0.1 then
            acceleration = acceleration + 10
        end
        table.insert(measured_accelerations, acceleration)
        last_velocity = velocity
        elapsed = elapsed + delta_t
        os.sleep(delta_t)
    end

    -- Average the acceleration values
    local sum_accel = 0
    for _, accel in ipairs(measured_accelerations) do
        sum_accel = sum_accel + accel
    end
    local avg_accel = sum_accel / #measured_accelerations
    local pressure = air_pressure(stableY)
    local force = avg_accel * mass / pressure

    -- Store the averaged acceleration for the current level
    data[i] = { acceleration = avg_accel, force = force }

    print(string.format("level %d profile: a=%d m/s^2, F=%d N", i, avg_accel, force))
    os.sleep(3)
end

-- Power down
main.setLevel(0)
main.setPowerState(false)

serialization.json.dumpf(data, "thruster_profile.json")
print("Done")

local thrust_api = dofile("apis/thrusters.lua")
local serialization = dofile("apis/serialization.lua")

local function getEngineAPI()
    local status, data = serialization.native.loadf("engine_config.txt")
    if not status then
        error("Failed to load engine map: " .. data)
    end

    local status, data = thrust_api.init(data, 6)
    if not status then
        error("Failed to init engine API: " .. data)
    end

    return data
end

function getOrientation(transform)
    -- Extract rotation matrix
    local R11, R12, R13 = transform[1][1], transform[1][2], transform[1][3]
    local R21, R22, R23 = transform[2][1], transform[2][2], transform[2][3]
    local R31, R32, R33 = transform[3][1], transform[3][2], transform[3][3]
  
    -- Forward vector
    local Fx, Fy, Fz = R13, R23, R33
    -- Up vector
    local Ux, Uy, Uz = R12, R22, R32
  
    -- Calculate world yaw
    local yaw = math.atan2(Fx, Fz)
  
    -- Construct inverse yaw rotation matrix
    local cosYaw, sinYaw = math.cos(-yaw), math.sin(-yaw)
    local inverseYawMatrix = {
      { cosYaw, 0, sinYaw },
      { 0, 1, 0 },
      { -sinYaw, 0, cosYaw }
    }
  
    -- Align the matrix with the world axes (undo yaw)
    local alignedR12 = cosYaw * R12 + sinYaw * R32
    local alignedR22 = Uy  -- Y-axis unaffected by yaw
    local alignedR32 = -sinYaw * R12 + cosYaw * R32
  
    -- Calculate pitch (angle from Forward vector in XZ-plane)
    local pitch = math.atan2(Fy, math.sqrt(Fx^2 + Fz^2))
  
    -- Calculate roll (angle from Up vector in YZ-plane)
    local roll = math.atan2(alignedR12, alignedR22)
  
    return pitch, yaw, -roll
end

local api = getEngineAPI()

-- Enable automatic power management
for name, engine in pairs(api.thrusters) do
    print("Enabling management for " .. name)
    engine.setManaged(true)
end

print("WARNING: ENGINES POWERING UP")
os.sleep(0.5)
print("WARNING: ENGINES POWERING UP")
os.sleep(0.5)
print("WARNING: ENGINES POWERING UP")
os.sleep(3)

-- Clamp helper function
local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

local function setAllThrusters(level)
    api.thrusters.main_front_left.setLevel(level)
    api.thrusters.main_front_right.setLevel(level)
    api.thrusters.main_back_left.setLevel(level)
    api.thrusters.main_back_right.setLevel(level)
end

local function thrustersSynced()
    return api.thrusters.main_front_left.isThrottleSynced() 
    and api.thrusters.main_front_right.isThrottleSynced() 
    and api.thrusters.main_back_left.isThrottleSynced() 
    and api.thrusters.main_back_right.isThrottleSynced()
end

local function sync()
    while not thrustersSynced() do
        api.update()
        os.sleep(0.05)
    end
end

print("CALIBRATING LIFT POWER")
local minThrust = 0.0
local height = ship.getWorldspacePosition().y

while true do
    setAllThrusters(minThrust)
    sync()
    
    os.sleep(0.5)
    local newHeight = ship.getWorldspacePosition().y
    if newHeight - height > 1 then
        break
    end

    minThrust = minThrust + 0.025
end

print("DONE. THROTTLING DOWN.")
setAllThrusters(0.0)
sync()
os.sleep(0.1)

print("Optimal thrust level found: " .. minThrust)
os.sleep(3.0)

-- PID constants (adjust these gradually)
local altitude_Kp, altitude_Ki, altitude_Kd = 0.3, 0.1, 1.0
local pitch_Kp, pitch_Ki, pitch_Kd = 0.5, 0.02, 0.05
local roll_Kp, roll_Ki, roll_Kd = 0.5, 0.02, 0.05

-- PID state variables
local altitude_error_sum, altitude_last_error = 0, 0
local pitch_error_sum, pitch_last_error = 0, 0
local roll_error_sum, roll_last_error = 0, 0

-- Integral error clamping range
local integral_clamp = 10.0

-- Desired altitude
local desired_altitude = 100


local function pid()
    -- Altitude control
    local current_altitude = ship.getWorldspacePosition().y
    local altitude_error = desired_altitude - current_altitude
    altitude_error_sum = clamp(altitude_error_sum + altitude_error, -integral_clamp, integral_clamp)
    -- altitude_error_sum = altitude_error_sum + altitude_error
    local altitude_rate_of_change = altitude_error - altitude_last_error
    altitude_last_error = altitude_error

    local altitude_output = altitude_Kp * altitude_error
                            + altitude_Ki * altitude_error_sum
                            + altitude_Kd * altitude_rate_of_change

    -- Debug altitude control
    print(string.format(
        "Altitude: Current=%.2f, Error=%.2f, Output=%.2f",
        current_altitude, altitude_error, altitude_output
    ))

    local matrix = ship.getTransformationMatrix()
    local pitch, yaw, roll = calculateOrientation(matrix)
    -- remap axes
    pitch, yaw, roll = -roll, yaw, pitch

    -- Pitch control
    local pitch_error = -pitch
    pitch_error_sum = clamp(pitch_error_sum + pitch_error, -integral_clamp, integral_clamp)
    -- pitch_error_sum = pitch_error_sum + pitch_error
    local pitch_rate_of_change = pitch_error - pitch_last_error
    pitch_last_error = pitch_error

    local pitch_output = pitch_Kp * pitch_error
                        + pitch_Ki * pitch_error_sum
                        + pitch_Kd * pitch_rate_of_change

    -- Debug pitch control
    print(string.format(
        "Pitch: Current=%.2f, Error=%.2f, Output=%.2f",
        pitch, pitch_error, pitch_output
    ))

    -- Roll control
    local roll_error = -roll
    roll_error_sum = clamp(roll_error_sum + roll_error, -integral_clamp, integral_clamp)
    -- roll_error_sum = roll_error_sum + roll_error
    local roll_rate_of_change = roll_error - roll_last_error
    roll_last_error = roll_error

    local roll_output = roll_Kp * roll_error
                        + roll_Ki * roll_error_sum
                        + roll_Kd * roll_rate_of_change

    -- Debug roll control
    print(string.format(
        "Roll: Current=%.2f, Error=%.2f, Output=%.2f",
        roll, roll_error, roll_output
    ))

    -- Calculate thrust levels for each thruster
    local base_thrust = clamp(altitude_output / 4, minThrust / 2, 1.0) -- Divide equally among thrusters

    -- Apply corrections
    local front_left_thrust = clamp(base_thrust + roll_output + pitch_output, minThrust - 0.1, 1.0)
    local front_right_thrust = clamp(base_thrust - roll_output + pitch_output, minThrust - 0.1, 1.0)
    local back_left_thrust = clamp(base_thrust + roll_output - pitch_output, minThrust - 0.1, 1.0)
    local back_right_thrust = clamp(base_thrust - roll_output - pitch_output, minThrust - 0.1, 1.0)

    -- Debug thrust levels
    print(string.format(
        "Thrusters: FL=%.2f, FR=%.2f, BL=%.2f, BR=%.2f",
        front_left_thrust, front_right_thrust, back_left_thrust, back_right_thrust
    ))

    -- Set thruster levels
    api.thrusters.main_front_left.setLevel(front_left_thrust)
    api.thrusters.main_front_right.setLevel(front_right_thrust)
    api.thrusters.main_back_left.setLevel(back_left_thrust)
    api.thrusters.main_back_right.setLevel(back_right_thrust)
end

local i = 0

local reached_target = false

-- Main PID loop
while true do
    if i % 5 == 0 then
        pid()
    end

    if ship.getWorldspacePosition().y >= desired_altitude and not reached_target then
        reached_target = true
        api.thrusters.thrust_left.setLevel(1.0)
        api.thrusters.thrust_right.setLevel(1.0)
    end
    
    api.update()
    i = i + 1
    os.sleep(0.05)
end

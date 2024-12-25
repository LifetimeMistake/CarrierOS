local math3d = require("apis.math3d")
local Vector3 = math3d.Vector3

if not ship then
    error("Ship API not present")
end

if ship.__extensionsLoaded then
    return
end

local api = {}
-- Copy original API
for k, f in pairs(ship) do
    api[k] = f
end

function ship.getOrientation()
    local transform = ship.getTransformationMatrix()
    local R11, R12, R13 = transform[1][1], transform[1][2], transform[1][3]
    local R21, R22, R23 = transform[2][1], transform[2][2], transform[2][3]
    local R31, R32, R33 = transform[3][1], transform[3][2], transform[3][3]

    local Fx, Fy, Fz = R13, R23, R33
    local Ux, Uy, Uz = R12, R22, R32

    local yaw = math.atan2(Fx, Fz)
    local cosYaw, sinYaw = math.cos(-yaw), math.sin(-yaw)
    local alignedR12 = cosYaw * R12 + sinYaw * R32
    local alignedR22 = Uy
    local alignedR32 = -sinYaw * R12 + cosYaw * R32

    local pitch = math.atan2(Fy, math.sqrt(Fx^2 + Fz^2))
    local roll = math.atan2(alignedR12, alignedR22)

    return pitch, yaw, -roll
end

function ship.getForwardVector()
    local transform = ship.getTransformationMatrix()
    return Vector3.new(transform[1][3], transform[2][3], transform[3][3])
end

function ship.getUpVector()
    local transform = ship.getTransformationMatrix()
    return Vector3.new(transform[1][2], transform[2][2], transform[3][2])
end

function ship.getRightVector()
    local transform = ship.getTransformationMatrix()
    return Vector3.new(-transform[1][1], -transform[2][1], -transform[3][1])
end

-- Function to rotate a vector from the ship's local coordinates to world coordinates
function ship.localToWorld(localVector)
    local transform = ship.getTransformationMatrix()

    -- Apply rotation using the transformation matrix
    local worldVector = Vector3.new(
        -transform[1][1] * localVector.x + transform[1][2] * localVector.y + transform[1][3] * localVector.z,
        -transform[2][1] * localVector.x + transform[2][2] * localVector.y + transform[2][3] * localVector.z,
        -transform[3][1] * localVector.x + transform[3][2] * localVector.y + transform[3][3] * localVector.z
    )

    return worldVector
end

-- Function to rotate a vector from world coordinates to the ship's local coordinates
function ship.worldToLocal(worldVector)
    local transform = ship.getTransformationMatrix()

    -- Apply inverse rotation using the transformation matrix
    local localVector = Vector3.new(
        -transform[1][1] * worldVector.x + -transform[2][1] * worldVector.y + -transform[3][1] * worldVector.z,
        transform[1][2] * worldVector.x + transform[2][2] * worldVector.y + transform[3][2] * worldVector.z,
        transform[1][3] * worldVector.x + transform[2][3] * worldVector.y + transform[3][3] * worldVector.z
    )

    return localVector
end

-- Override some functions
function ship.getVelocity()
    return Vector3.from_table(api.getVelocity())
end

function ship.getWorldspacePosition()
    return Vector3.from_table(api.getWorldspacePosition())
end

-- Set the extensions flag
ship.__extensionsLoaded = true
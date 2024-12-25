local math3d = {}

-- Vector3 Class
local Vector3 = {}
Vector3.__index = Vector3

function Vector3.new(x, y, z)
    return setmetatable({x = x or 0, y = y or 0, z = z or 0}, Vector3)
end

function Vector3.from_table(t)
    return Vector3.new(t.x, t.y, t.z)
end

function Vector3.__add(v1, v2)
    return Vector3.new(v1.x + v2.x, v1.y + v2.y, v1.z + v2.z)
end

function Vector3.__sub(v1, v2)
    return Vector3.new(v1.x - v2.x, v1.y - v2.y, v1.z - v2.z)
end

function Vector3.__mul(v, scalar)
    if type(scalar) == "number" then
        return Vector3.new(v.x * scalar, v.y * scalar, v.z * scalar)
    else
        error("Mul operator can only perform scalar vector multiplication")
    end
end

function Vector3.__unm(v)
    return Vector3.new(-v.x, -v.y, -v.z)
end

function Vector3.__lt(v1, v2)
    return Vector3.magnitude(v1) < Vector3.magnitude(v2)
end

function Vector3.__eq(v1, v2)
    return v1.x == v2.x and v1.y == v2.y and v1.z == v2.z
end

function Vector3.__le(v1, v2)
    return Vector3.magnitude(v1) <= Vector3.magnitude(v2)
end

function Vector3.__tostring(v)
    return string.format("Vector3(%f, %f, %f)", v.x, v.y, v.z)
end

function Vector3.componentWiseMultiply(v1, v2)
    return Vector3.new(v1.x * v2.x, v1.y * v2.y, v1.z * v2.z)
end

function Vector3.dot(v1, v2)
    return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z
end

function Vector3.cross(v1, v2)
    return Vector3.new(
        v1.y * v2.z - v1.z * v2.y,
        v1.z * v2.x - v1.x * v2.z,
        v1.x * v2.y - v1.y * v2.x
    )
end

function Vector3:magnitude()
    return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
end

function Vector3:normalize()
    local mag = self:magnitude()
    if mag == 0 then return Vector3.new(0, 0, 0) end
    return self * (1 / mag)
end

math3d.Vector3 = Vector3

-- Quaternion Class
local Quaternion = {}
Quaternion.__index = Quaternion

function Quaternion.new(w, x, y, z)
    return setmetatable({w = w or 1, x = x or 0, y = y or 0, z = z or 0}, Quaternion)
end

function Quaternion.__mul(q1, q2)
    return Quaternion.new(
        q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z,
        q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
        q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
        q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w
    )
end

function Quaternion:conjugate()
    return Quaternion.new(self.w, -self.x, -self.y, -self.z)
end

function Quaternion:rotateVector(v)
    local qv = Quaternion.new(0, v.x, v.y, v.z)
    local result = self * qv * self:conjugate()
    return Vector3.new(result.x, result.y, result.z)
end

math3d.Quaternion = Quaternion

-- Conversion Functions
function math3d.toGlobal(localVector, shipPosition, shipOrientation)
    return shipPosition + shipOrientation:rotateVector(localVector)
end

function math3d.toLocal(globalVector, shipPosition, shipOrientation)
    local relativeVector = globalVector - shipPosition
    local inverseOrientation = shipOrientation:conjugate()
    return inverseOrientation:rotateVector(relativeVector)
end

-- Euler to Quaternion and vice versa
function math3d.eulerToQuaternion(pitch, yaw, roll)
    local cy = math.cos(yaw * 0.5)
    local sy = math.sin(yaw * 0.5)
    local cp = math.cos(pitch * 0.5)
    local sp = math.sin(pitch * 0.5)
    local cr = math.cos(roll * 0.5)
    local sr = math.sin(roll * 0.5)

    return Quaternion.new(
        cr * cp * cy + sr * sp * sy,
        sr * cp * cy - cr * sp * sy,
        cr * sp * cy + sr * cp * sy,
        cr * cp * sy - sr * sp * cy
    )
end

function math3d.quaternionToEuler(q)
    local sinr_cosp = 2 * (q.w * q.x + q.y * q.z)
    local cosr_cosp = 1 - 2 * (q.x * q.x + q.y * q.y)
    local roll = math.atan2(sinr_cosp, cosr_cosp)

    local sinp = 2 * (q.w * q.y - q.z * q.x)
    local pitch
    if math.abs(sinp) >= 1 then
        pitch = math.pi / 2 * (sinp < 0 and -1 or 1)
    else
        pitch = math.asin(sinp)
    end

    local siny_cosp = 2 * (q.w * q.z + q.x * q.y)
    local cosy_cosp = 1 - 2 * (q.y * q.y + q.z * q.z)
    local yaw = math.atan2(siny_cosp, cosy_cosp)

    return {pitch = pitch, yaw = yaw, roll = roll}
end

return math3d

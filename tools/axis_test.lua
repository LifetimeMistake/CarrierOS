local math3d = require("libs.math3d")
local Vector3 = math3d.Vector3
require("libs.shipExtensions")
local cb = peripheral.wrap("right")

local vec = Vector3.new(0, 0, 1)
while true do
    local forward, up, right = ship.getForwardVector(), ship.getUpVector(), ship.getRightVector()
    local localVec = ship.worldToLocal(vec)
    cb.sendMessage(string.format("F: %s, U: %s, R: %s, C: %s", tostring(forward), tostring(up), tostring(right), tostring(localVec)))
    os.sleep(1)
end
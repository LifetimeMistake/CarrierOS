local serialization = require("libs.serialization")
local event = require("libs.event")
local math3d = require("libs.math3d")
local Vector3 = math3d.Vector3

local function loadDB(databasePath, loadExisting)
    if loadExisting and fs.exists(databasePath) then
        local success, data = serialization.json.loadf(databasePath)
        if not success then
            log.error("Error loading database, falling back to empty DB")
            fs.move(databasePath, databasePath .. ".bak")
        end

        return data
    end

    return {}
end

local function findNextFreeId(db)
    local i = 1
    while true do
        if not db[i] then
            return i
        end

        i  = i + 1
    end
end

local Waypoints = {}
Waypoints.__index = Waypoints
Waypoints.events = {
    added = event.new("db_waypoint_added"),
    updated = event.new("db_waypoint_updated"),
    removed = event.new("db_waypoint_removed")
}

function Waypoints.new(databasePath, loadExisting)
    local db = loadDB(databasePath, loadExisting)
    return setmetatable({
        db = db,
        dbPath = databasePath
    }, Waypoints)
end

function Waypoints:save()
    local success, message = serialization.json.dumpf(self.db, self.dbPath)
    if not success then
        log.warn("Failed to save database: " .. message)
    end
end

function Waypoints:add(name, pos, heading)
    local id = findNextFreeId(self.db)
    local waypoint = {
        id = id,
        name = name,
        pos = Vector3.to_table(pos),
        heading = heading
    }

    self.db[id] = waypoint
    self.events.added(id, waypoint)
end

function Waypoints:remove(id)
    if not self.db[id] then
        return false
    end

    local waypoint = self.db[id]
    self.db[id] = nil

    self.events.removed(id, waypoint)
end

function Waypoints:update(id, data)
    local waypoint = self.db[id]
    if not waypoint then
        return false
    end

    if data.pos then
        data.pos = Vector3.to_table(data.pos)
    end

    for k,v in pairs(data) do
        waypoint[k] = v
    end

    self.events.updated(id, data)
    return true
end

function Waypoints:get(id)
    local waypoint = self.db[id]
    if not waypoint then
        return nil
    end

    return {
        id = id,
        name = waypoint.name,
        pos = Vector3.from_table(waypoint.pos),
        heading = waypoint.heading
    }
end

function Waypoints:list()
    local t = {}
    for k,_ in pairs(self.db) do
        t[k] = self:get(k)
    end

    return t
end

return Waypoints
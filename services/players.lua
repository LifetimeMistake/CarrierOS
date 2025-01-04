local logging = require("libs.logging")
local math3d = require("libs.math3d")
local Vector3 = math3d.Vector3

local CACHE_TTL = 1

if not log then
    print("Setting up own logger")
    local logger = logging.Logger.new(100)

    _G.log = {
        debug = function(msg)
            logger:debug(msg)
        end,
        info = function(msg)
            logger:info(msg)
        end,
        warn = function(msg)
            logger:warn(msg)
        end,
        error = function(msg)
            logger:error(msg)
        end,
        instance = logger
    }

    logger:setHook(function(level, message)
        level = logging.LogLevel.tostring(level)
        print(string.format("[%s] %s", level, message))
    end)
end

local function isPlayerInCubicRange(playerPos, shipPos, w, h, d)
    local wE, hE, dE = w / 2, h / 2, d / 2
    local wS, hS, dS = -wE, -hE, -dE

    local localPos = ship.worldToLocal(playerPos - shipPos)
    return (localPos.x >= wS and localPos.x < wE)
        and (localPos.y >= hS and localPos.y < hE)
        and (localPos.z >= dS and localPos.z < dE)
end

local function isPlayerInRange(shipPos, playerPos, rangeSq)
    local distSq = (shipPos - playerPos):magnitudeSquared()
    return distSq <= rangeSq
end

local detector
local detectorName
local playerCache = {}
local api = {}

function api.getPlayer(username)
    local now = os.clock()
    local cachedData = playerCache[username]
    if cachedData and (now - cachedData.timestamp) <= CACHE_TTL then
        return cachedData.data
    end

    -- Refresh cache if no valid data or expired
    local playerData = detector.getPlayer(username)
    if playerData then
        playerCache[username] = {
            data = playerData,
            timestamp = now
        }
    end
    return playerData
end

function api.getPlayersInRange(range)
    if ship then
        local rangeSq = range * range
        local shipPos = ship.getWorldspacePosition()
        local players = {}

        for _, name in ipairs(detector.getOnlinePlayers()) do
            local player = api.getPlayer(name)
            if player then
                local playerPos = Vector3.from_table(player)
                if isPlayerInRange(shipPos, playerPos, rangeSq) then
                    table.insert(players, name)
                end
            end
        end
        return players
    else
        return detector.getPlayersInRange(range)
    end
end

function api.getPlayersInCubic(w, h, d)
    if ship then
        local shipPos = ship.getWorldspacePosition()
        local players = {}

        for _, name in ipairs(detector.getOnlinePlayers()) do
            local player = api.getPlayer(name)
            if player then
                local playerPos = Vector3.from_table(player)
                if isPlayerInCubicRange(playerPos, shipPos, w, h, d) then
                    table.insert(players, name)
                end
            end
        end
        return players
    else
        return detector.getPlayersInCubic(w, h, d)
    end
end

function api.getPlayersOnboard()
    if not ship then
        return {}
    end

    local size = ship.getSize()
    return api.getPlayersInCubic(size.x, size.y, size.z)
end

function api.isPlayerInRange(range, username)
    if ship then
        local rangeSq = range * range
        local shipPos = ship.getWorldspacePosition()
        local player = api.getPlayer(username)
        if player then
            local playerPos = Vector3.from_table(player)
            return isPlayerInRange(shipPos, playerPos, rangeSq)
        end
        return false
    else
        return detector.isPlayerInRange(range, username)
    end
end

function api.isPlayerInCubic(w, h, d, username)
    if ship then
        local shipPos = ship.getWorldspacePosition()
        local player = api.getPlayer(username)
        if player then
            local playerPos = Vector3.from_table(player)
            return isPlayerInCubicRange(playerPos, shipPos, w, h, d)
        end
        return false
    else
        return detector.isPlayerInCubic(w, h, d, username)
    end
end

function api.isPlayerOnboard(username)
    if not ship then
        return false
    end

    local size = ship.getSize()
    return api.isPlayerInCubic(size.x, size.y, size.z, username)
end

function api.anyPlayersInRange(range)
    if ship then
        return #api.getPlayersInRange(range) > 0
    else
        return detector.anyPlayersInRange(range)
    end
end

function api.anyPlayersInCubic(w, h, d)
    if ship then
        return #api.getPlayersInCubic(w, h, d) > 0
    else
        return detector.anyPlayersInCubic(w, h, d)
    end
end

function api.anyPlayersOnboard()
    if not ship then
        return false
    end

    return #api.getPlayersOnboard() > 0
end

log.info("Looking for player detector device...")
while not detector do
    detector = peripheral.find("playerDetector")
    os.sleep(1)
end

detectorName = peripheral.getName(detector)
log.info("Using device: " .. detectorName)

api_factory.publish("players", api)

-- Idle until disconnected
while peripheral.isPresent(detectorName) do
    os.sleep(1)
end

log.error("Player detector disconnected, exiting.")
api_factory.unpublish("players")

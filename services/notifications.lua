local logging = require("libs.logging")
local serialization = require("libs.serialization")
local CONFIG_PATH = "/data/notifications.json"

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

local function loadConfig()
    local defaults = {
        onlyNotifyCrew = false,
        nearbyRadius = 100,
    }

    if not fs.exists(CONFIG_PATH) then
        log.info("Loading default config")
        serialization.json.dumpf(defaults, CONFIG_PATH)
        return defaults
    end

    local success, data = serialization.json.loadf(CONFIG_PATH)
    if not success then
        log.error("Failed to load system config, falling back to default.")
        log.error(data)
        return defaults
    end

    log.info("Loaded config successfully")
    return data
end

local chatBox
local handlers = {}
local config = loadConfig()

local function getMessageTargets(type)
    if type == "nearby" and not config.onlyNotifyCrew then
        return players.getPlayersInRange(config.nearbyRadius)
    end

    if type == "crew" or (type == "nearby" and config.onlyNotifyCrew) then
        return players.getPlayersOnboard()
    end

    error("Unknown message scope", 2)
end

function handlers.db_waypoint_added(_, waypoint)
    local content = string.format("%s (%d, %d, %d)", waypoint.name, waypoint.pos.x, waypoint.pos.y, waypoint.pos.z)
    for _, name in ipairs(getMessageTargets("crew")) do
        chatBox.sendToastToPlayer("Waypoint added to database: " .. content, "CarrierOS", name, "DB")
    end
end

function handlers.db_waypoint_removed(_, waypoint)
    local content = string.format("%s (%d, %d, %d)", waypoint.name, waypoint.pos.x, waypoint.pos.y, waypoint.pos.z)
    for _, name in ipairs(getMessageTargets("crew")) do
        chatBox.sendToastToPlayer("Waypoint removed from database: " .. content, "CarrierOS", name, "DB")
    end
end

function handlers.autopilot_departing(waypoint)
    for _, name in ipairs(getMessageTargets("nearby")) do
        chatBox.sendToastToPlayer("Now departing for waypoint \"" .. waypoint.name .. "\"", "CarrierOS", name, "Autopilot")
    end
end

function handlers.autopilot_waypoint_reached(waypoint)
    for _, name in ipairs(getMessageTargets("nearby")) do
        chatBox.sendToastToPlayer("Arrived at waypoint \"" .. waypoint.name .. "\"", "CarrierOS", name, "Autopilot")
    end
end

function handlers.autopilot_navigation_complete()
    for _, name in ipairs(getMessageTargets("crew")) do
        chatBox.sendToastToPlayer("Arrived at final destination. Navigation complete.", "CarrierOS", name, "Autopilot")
    end
end

log.info("Looking for chatBox peripheral...")
while not chatBox do
    chatBox = peripheral.find("chatBox")
    os.sleep(1)
end

local chatBoxName = peripheral.getName(chatBox)
log.info("Using device: " .. chatBoxName)

while peripheral.isPresent(chatBoxName) do
    local eventData = table.pack(os.pullEvent())
    local handler = handlers[eventData[1]]
    if handler and players then
        log.debug("Handling event " .. eventData[1])
        handler(table.unpack(eventData, 2, eventData.n))
    end
end

log.error("ChatBox peripheral disconnected, exiting.")
local logging = require("libs.logging")
local serialization = require("libs.serialization")

local CONFIG_PATH = "/data/welcome.json"

local function loadConfig()
    local defaults = {
        cooldown = 5*60,
        captain = "",
        messageTitle = "CarrierOS",
        messageContent = "Welcome aboard, %s!"
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
local lastSeen = {}
local config = loadConfig()

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

log.info("Looking for chatBox peripheral...")
while not chatBox do
    chatBox = peripheral.find("chatBox")
    os.sleep(1)
end

local chatBoxName = peripheral.getName(chatBox)
log.info("Using device: " .. chatBoxName)

log.info("Starting player monitoring...")
while peripheral.isPresent(chatBoxName) do
    if players then
        local onboardPlayers = players.getPlayersOnboard()
        local now = os.clock()

        for _, playerName in ipairs(onboardPlayers) do
            if not lastSeen[playerName] or (now - lastSeen[playerName]) > config.cooldown then
                log.info("Welcoming player: " .. playerName)
                local name = config.captain == playerName and "Captain" or playerName
                local title = string.format(config.messageTitle, name)
                local content = string.format(config.messageContent, name)

                local success, err = chatBox.sendToastToPlayer(content, title, playerName, "SYSTEM")
                if not success then
                    log.error("Failed to send toast to player: " .. playerName .. ". Error: " .. tostring(err))
                end
            end

            lastSeen[playerName] = now
        end
    end

    os.sleep(1)
end

log.error("ChatBox peripheral disconnected, exiting.")

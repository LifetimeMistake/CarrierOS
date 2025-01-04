local sShell
if term.isColour() and settings.get("bios.use_multishell") then
    sShell = "rom/programs/advanced/multishell.lua"
else
    sShell = "rom/programs/shell.lua"
end

if not process and not services then 
    os.run({}, sShell)
    return
end

services.register(
    "carrieros_server", 
    "/services/server.lua",
    {
        restartPolicy = "on-failure:15",
        loggerCapacity = 100,
        privileged = true
    }
)

services.register(
    "carrieros_rpc", 
    "/services/rpc.lua",
    {
        restartPolicy = "on-failure:5",
        loggerCapacity = 100,
        privileged = false
    }
)

services.register(
    "carrieros_notifications",
    "/services/notifications.lua",
    {
        restartPolicy = "on-failure:5",
        loggerCapacity = 100,
        privileged = false
    }
)


services.register(
    "player_detection",
    "/services/players.lua",
    {
        restartPolicy = "on-failure:5",
        loggerCapacity = 100,
        privileged = true
    }
)

services.register(
    "welcome",
    "/services/welcome.lua",
    {
        restartPolicy = "on-failure:5",
        loggerCapacity = 100,
        privileged = false
    }
)

services.start("carrieros_server")
services.start("carrieros_rpc")
services.start("carrieros_notifications")
services.start("player_detection")
services.start("welcome")

term.clear()
term.setCursorPos(0, 0)
process.runFile(sShell, nil, false)
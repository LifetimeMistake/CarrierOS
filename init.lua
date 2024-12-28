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
    "/carrieros.lua",
    {
        restartPolicy = "on-failure:5",
        loggerCapacity = 100
    }
)

services.start("carrieros_server")
term.clear()
term.setCursorPos(0, 0)
process.runFile(sShell, nil, true)
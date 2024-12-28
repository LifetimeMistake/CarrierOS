-- Check if we're running in kernel environment
if not process then
    error("This utility requires the kernel process API")
end

local function printUsage()
    print("Usage: kill <pid>")
    print("Terminates the process with the specified PID.")
    print("Note: Unprivileged processes can only kill other unprivileged processes.")
end

local function main(args)
    if #args ~= 1 or args[1] == "-h" or args[1] == "--help" then
        printUsage()
        return
    end
    
    -- Parse PID
    local pid = tonumber(args[1])
    if not pid then
        print("Error: Invalid PID: " .. args[1])
        return
    end
    
    -- Check if process exists
    if not process.exists(pid) then
        print("Error: Process does not exist: " .. pid)
        return
    end
    
    -- Try to kill the process
    local ok, err = pcall(function()
        process.kill(pid)
    end)
    
    if ok then
        print(string.format("Process %d killed", pid))
    else
        print("Error killing process: " .. tostring(err))
    end
end

main({...}) 
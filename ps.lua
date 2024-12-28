-- Check if we're running in kernel environment
if not process then
    error("This utility requires the kernel process API")
end

local function formatProcessList(processes)
    -- Find the maximum lengths for each column
    local maxPidLen = 5  -- "PID" header length
    local maxNameLen = 4  -- "NAME" header length
    local maxStatusLen = 6  -- "STATUS" header length
    
    for _, proc in pairs(processes) do
        maxPidLen = math.max(maxPidLen, #tostring(proc.pid))
        maxNameLen = math.max(maxNameLen, #proc.name)
        maxStatusLen = math.max(maxStatusLen, #proc.status)
    end
    
    -- Create format string for consistent column widths
    local fmt = string.format("%%-%ds  %%-%ds  %%-%ds  %%s",
        maxPidLen, maxNameLen, maxStatusLen)
    
    -- Print header
    print(string.format(fmt, "PID", "NAME", "STATUS", "PRIV"))
    print(string.rep("-", maxPidLen + maxNameLen + maxStatusLen + 8))
    
    -- Sort processes by PID for consistent output
    local sortedProcs = {}
    for _, proc in pairs(processes) do
        table.insert(sortedProcs, proc)
    end
    table.sort(sortedProcs, function(a, b) return a.pid < b.pid end)
    
    -- Print each process
    for _, proc in ipairs(sortedProcs) do
        print(string.format(fmt,
            proc.pid,
            proc.name,
            proc.status,
            proc.privileged and "yes" or "no"
        ))
    end
end

local function main(args)
    local processes = process.list()
    formatProcessList(processes)
end

main({...}) 
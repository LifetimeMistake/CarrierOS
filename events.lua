local blacklistedEvents = {
    timer = true,
    task_complete = true,
}

while true do
    local eventData = table.pack(os.pullEvent())
    local eventType = eventData[1]
    
    if not blacklistedEvents[eventType] then
        print("Event: " .. eventType)
        for i = 2, eventData.n do
            print("  Data[" .. (i - 1) .. "]: " .. tostring(eventData[i]))
        end
        
        print()
    end
end
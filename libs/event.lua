local Event = {}
Event.__index = Event

function Event.new(eventType)
    local self = setmetatable({}, Event)
    self.eventType = eventType
    return self
end

function Event:fire(...)
    os.queueEvent(self.eventType, ...)
end

return Event
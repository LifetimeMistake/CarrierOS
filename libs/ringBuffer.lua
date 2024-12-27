local RingBuffer = {}
RingBuffer.__index = RingBuffer

--- Creates a new ring buffer with the specified maximum size
-- @param max_size The maximum number of messages the ring buffer can hold
function RingBuffer.new(max_size)
    return setmetatable({
        buffer = {},
        max_size = max_size,
        start = 1,
        size = 0
    }, RingBuffer)
end

--- Push a new log message to the ring buffer
-- @param self The ring buffer instance
-- @param level The log level ("debug", "info", "warn", "error")
-- @param message The log message text
function RingBuffer:push(level, message)
    local timestamp = os.clock()
    local entry = { level = level, timestamp = timestamp, message = message }

    -- Determine the position to write in the ring buffer
    local pos = (self.start + self.size - 1) % self.max_size + 1

    self.buffer[pos] = entry

    if self.size < self.max_size then
        self.size = self.size + 1
    else
        -- Advance the start index when overwriting oldest entry
        self.start = self.start % self.max_size + 1
    end
end

--- Iterate over the messages in the ring buffer in order
-- @param self The ring buffer instance
-- @return Iterator function returning each log entry
function RingBuffer:iter()
    local index = 0
    return function()
        if index < self.size then
            local pos = (self.start + index - 1) % self.max_size + 1
            index = index + 1
            return self.buffer[pos]
        end
    end
end

return RingBuffer
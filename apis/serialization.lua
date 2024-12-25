local serialization = {
    native = {},
    json = {}
}

local function writeFile(string, path)
    local file = fs.open(path, "w")
    if not file then
        return false, "Failed to open file for writing"
    end

    file.write(string)
    file.close()
    return true
end

local function readFile(path)
    if not fs.exists(path) then
        return false, "File does not exist"
    end

    local file = fs.open(path, "r")
    if not file then
        return false, "Failed to open file for reading"
    end

    local data = file.readAll()
    file.close()

    return true, data
end

function serialization.native.dumps(object)
    return textutils.serialise(object)
end

function serialization.native.loads(string)
    return textutils.unserialise(string)
end

function serialization.native.dumpf(object, path)
    local data = serialization.native.dumps(object)
    return writeFile(data, path)
end

function serialization.native.loadf(path)
    local status, data = readFile(path)
    if not status then
        return false, data
    end

    return true, serialization.native.loads(data)
end

function serialization.json.dumps(object)
    return textutils.serialiseJSON(object)
end

function serialization.json.loads(string)
    return textutils.unserialiseJSON(string)
end

function serialization.json.dumpf(object, path)
    local data = serialization.json.dumps(object)
    return writeFile(data, path)
end

function serialization.json.loadf(path)
    local status, data = readFile(path)
    if not status then
        return false, data
    end

    return true, serialization.json.loads(data)
end

return serialization
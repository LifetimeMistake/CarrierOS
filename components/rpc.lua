local PROTOCOL_ID = "carrieros_rpc"
local REQUEST_TYPE = "rpc_request"
local RESPONSE_TYPE = "rpc_response"

local function generateRequestId()
    return tostring(os.clock()):gsub("%.", "") .. math.random(1000, 999999)
end

local function callRequest(method, args)
    return {
        id = generateRequestId(),
        type = REQUEST_TYPE,
        command = "call",
        method = method,
        args = args
    }
end

local function listRequest(service)
    return {
        id = generateRequestId(),
        type = REQUEST_TYPE,
        command = "list",
        service = service
    }
end

local function responseOk(request, result)
    return {
        id = request.id,
        type = RESPONSE_TYPE,
        success = true,
        result = result
    }
end

local function responseErr(request, message)
    return {
        id = request.id,
        type = RESPONSE_TYPE,
        success = false,
        message = message
    }
end

local RPCServer = {}
RPCServer.__index = RPCServer

function RPCServer:new(modemName, hostname)
    local instance = setmetatable({}, self)
    instance.hostname = hostname or ("carrieros_" + tostring(generateRequestId()))
    instance.modem = modemName
    instance.isRunning = false
    instance.services = {}
    return instance
end

function RPCServer:start()
    if self.isRunning then
        return
    end

    if not rednet.isOpen(self.modem) then
        rednet.open(self.modem)
    end

    rednet.host(PROTOCOL_ID, self.hostname)
    self.isRunning = true
end

function RPCServer:stop()
    if not self.isRunning then
        return
    end

    rednet.unhost(PROTOCOL_ID, self.hostname)
    self.isRunning = false
end

function RPCServer:registerService(name, methods)
    if self.services[name] then
        return false, "Service " .. name .. " is already registered" 
    end

    self.services[name] = methods
    return true
end

function RPCServer:unregisterService(name)
    if not self.services[name] then
        return false, "Service " .. name .. " is not registered"
    end

    self.services[name] = nil
    return true
end

function RPCServer:handleRequest(message)
    local requestType = message.type
    local response = { id = message.id, type = "rpc_response" }

    if requestType == "list" then
        
    elseif requestType == "call" then

    else
        response.type = "rpc_response"
    end


    local service = self.services[message.service]

    if service and service[message.method] then
        local success, result = pcall(service[message.method], table.unpack(message.args))
        response.success = success
        response.result = success and result or tostring(result)
    else
        response.success = false
        response.result = "Service or method not found"
    end
end

function RPCServer:run()
    while true do
        local senderId, message, protocol = rednet.receive(PROTOCOL_ID, 0.1)
        if senderId and message and type(message) == "table" and message.type == REQUEST_TYPE then
            local response = self:handleRequest(message)
            rednet.send(senderId, response, protocol)
        end
    end
end
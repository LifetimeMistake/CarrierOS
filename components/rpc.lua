local PROTOCOL_ID = "carrieros_rpc"
local REQUEST_TYPE = "rpc_request"
local RESPONSE_TYPE = "rpc_response"

local function generateRequestId()
    return tostring(os.clock()):gsub("%.", "") .. math.random(1000, 999999)
end

local function callRequest(service, method, args)
    return {
        id = generateRequestId(),
        type = REQUEST_TYPE,
        command = "call",
        service =  service,
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

function RPCServer.new(modemName, hostname)
    local instance = setmetatable({}, RPCServer)
    instance.hostname = hostname or ("carrieros_" .. tostring(generateRequestId()))
    instance.modem = modemName
    instance.isRunning = false
    instance.services = {}

    if not rednet.isOpen(modemName) then
        rednet.open(modemName)
    end

    return instance
end

function RPCServer:start()
    if self.isRunning then
        return
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

function RPCServer:handleRequest(request)
    local requestType = request.command

    if requestType == "list" then
        local data = {}
        if request.service then
            local service = self.services[request.service]
            if not service then
                return responseErr(request, "Object not found")
            end

            for k, _ in pairs(service) do 
                table.insert(data, k)
            end
        else
            for name, service in pairs(self.services) do
                local t = {}
                for k, _ in pairs(service) do
                    table.insert(t, k)
                end
                data[name] = t
            end
        end

        return responseOk(request, data)
    elseif requestType == "call" then
        local service = self.services[request.service]
        if not service or not service[request.method] then
            return responseErr(request, "Object not found")
        end

        local method = service[request.method]
        local success, result = pcall(method, table.unpack(request.args))
        if success then
            return responseOk(request, result)
        else
            return responseErr(request, result)
        end
    else
        return responseErr(request, "Unsupported protocol command")
    end
end

function RPCServer:receive(timeout)
    local senderId, message, protocol = rednet.receive(PROTOCOL_ID, timeout)
    if senderId and message and type(message) == "table" and message.type == REQUEST_TYPE then
        local response = self:handleRequest(message)
        rednet.send(senderId, response, protocol)
    end
end

function RPCServer:run()
    while true do
        self:receive(0.1)
    end
end

local RPCClient = {}
RPCClient.__index = RPCClient

function RPCClient.new(modemName, timeout)
    local instance = setmetatable({}, RPCClient)
    instance.modem = modemName
    instance.host = nil
    instance.timeout = timeout or 2
    instance.pendingRequests = {}

    if not rednet.isOpen(modemName) then
        rednet.open(modemName)
    end

    return instance
end

function RPCClient:discover()
    local hosts = {rednet.lookup(PROTOCOL_ID)}
    return hosts
end

function RPCClient:associate(hostId)
    self.host = hostId
end

function RPCClient:disassociate()
    self.host = nil
    self.pendingRequests = {}
end

function RPCClient:_handleResponse(response)
    local requestId = response.id
    if self.pendingRequests[requestId] then
        self.pendingRequests[requestId].response = response
        self.pendingRequests[requestId].received = true
    end
end

function RPCClient:_waitForResponse(requestId)
    local start = os.clock()
    while os.clock() - start < self.timeout do
        local senderId, response, protocol = rednet.receive(PROTOCOL_ID, 0.5)
        if senderId == self.host and protocol == PROTOCOL_ID and type(response) == "table" then
            self:_handleResponse(response)
            if self.pendingRequests[requestId] and self.pendingRequests[requestId].received then
                return true, self.pendingRequests[requestId].response
            end
        end
    end
    return false, "Request timed out."
end

function RPCClient:listServices(serviceName)
    if not self.host then
        return false, "No host associated."
    end

    local request = listRequest(serviceName)
    self.pendingRequests[request.id] = {response = nil, received = false}
    rednet.send(self.host, request, PROTOCOL_ID)

    local success, response = self:_waitForResponse(request.id)
    self.pendingRequests[request.id] = nil

    if not success then
        return false, response
    end

    if response.success then
        return true, response.result
    else
        return false, response.message
    end
end

function RPCClient:call(service, method, ...)
    if not self.host then
        return false, "No host associated."
    end

    local args = {...}
    local request = callRequest(service, method, args)
    self.pendingRequests[request.id] = {response = nil, received = false}
    rednet.send(self.host, request, PROTOCOL_ID)

    local success, response = self:_waitForResponse(request.id)
    self.pendingRequests[request.id] = nil

    if not success then
        return false, response
    end

    if response.success then
        return true, response.result
    else
        return false, response.message
    end
end

function RPCClient:wrapService(serviceName)
    if not self.host then
        return false, "No host associated."
    end

    local success, methods = self:listServices(serviceName)
    if not success then
        return false, methods
    end

    local proxy = {}

    for _, methodName in ipairs(methods) do
        proxy[methodName] = function(...)
            local callSuccess, result = self:call(serviceName, methodName, ...)
            if callSuccess then
                return true, result
            else
                return false, result
            end
        end
    end

    return true, proxy
end

return {
    RPCServer = RPCServer,
    RPCClient = RPCClient
}
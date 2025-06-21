--!strict
local HttpService: HttpService = game:GetService("HttpService")

local jobId = if game:GetService("RunService"):IsStudio() then `DEV-SERVER-{HttpService:GenerateGUID(false)}` else game.JobId

local Session = {}
Session.__index = Session

--[[
	The Zyntex Session type. Used for API requests.
]]--
export type SessionType = {
	--[[
		Represents the root API url. i.e.: https://api.zyntex.dev
	]]--
	rootUrl: string;
	--[[
		The game-token. Used whenever linking.
	]]--
	gameToken: string;
	--[[
		The server's Job ID
	]]
	jobID: string;
}

local Response = {}
Response.__index = Response

--[[
	The Zyntex Response type. Used for the response of a API request.
]]--
export type ResponseType = {
	--[[
		Wether or not the status code of the response was 200-299 AND data.success == true.
	]]--
	success: boolean;
	--[[
		The user message returned by the API
	]]--
	user_message: string;
	--[[
		The data that the API responded with.
	]]--
	data: any;
	--[[
		The status code of the HTTP request
	]]
	statusCode: number;
}

export type Session  = typeof(setmetatable({} :: SessionType, Session))
export type Response = typeof(setmetatable({} :: ResponseType, Response))

--[[
	Construct a new Response using decoded data
]]
function Response.new(success: boolean, user_message: string, statusCode: number, data: any?): Response
	local self = {}
	self.success = success
	self.user_message = user_message
	self.data = data
	self.statusCode = statusCode
	
	return setmetatable(self, Response)
end

--[[
	Construct a new Response using raw JSON data
]]
function Response.fromRaw(res: {["Body"]: string, [string]: any}, statusCode: number): Response
	local self = {}

	local JSONDecoded = HttpService:JSONDecode(res["Body"])
	self.success = JSONDecoded.success :: boolean
	self.user_message = JSONDecoded.user_message :: string

	local data = JSONDecoded.data
	if data then
		self.data = data
	end
	
	self.statusCode = statusCode

	return setmetatable(self, Response)
end

	
--[[
	Send an HTTP Request to the Zyntex API
]]
function Session.request(self: Session, endpoint: string, method: string, body: {[string]: any}?, autoError: boolean?): Response
	local success, data: Response = pcall(function()
		local res = HttpService:RequestAsync(
			{
				["Url"]     = `{self.rootUrl}{endpoint}`;
				["Method"]  = string.upper(method);
				["Body"]    = if body then HttpService:JSONEncode(body) else nil;
				["Headers"] = {
					["Authorization"] = `Game-Token {self.gameToken}`,
					["Job-ID"] = jobId,
					["Content-Type"] = "application/json"
				} 
			}
		)
				
		return Response.fromRaw(res, res.StatusCode)
	end)
	
	if autoError == nil then
		autoError = true
	end
	
	if success then
		return data
	end
	
	if autoError then
		error(`HTTP Request to {endpoint} failed, "{data}"`)
		return data
	end
	
	return data
end

--[[
	Shorthand for Session:request(endpoint, 'GET')
]]
function Session.get(self: Session, endpoint: string, autoError: boolean?): Response
	return self:request(endpoint, "GET", nil, autoError)
end

--[[
	Shorthand for Session:request(endpoint, 'POST', body)
]]
function Session.post(self: Session, endpoint: string, body: {string: any}?, autoError: boolean?): Response
	return self:request(endpoint, "POST", body, autoError)
end

--[[
	Shorthand for Session:request(endpoint, 'DELETE', body)
]]
function Session.delete(self: Session, endpoint: string, body: {string: any}?, autoError: boolean?): Response
	return self:request(endpoint, "DELETE", body, autoError)
end
	
--[[
	Construct a new Session
]]
function Session.new(gameToken: string, rootUrl: string?, link: boolean?)
	local self = {}
	self.gameToken = gameToken
	self.rootUrl = if rootUrl then rootUrl else "https://api.zyntex.dev"
	self.jobID = HttpService:GenerateGUID(false)
	
	return setmetatable(self, Session)
end

	
return Session

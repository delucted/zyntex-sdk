--!strict
local HttpService: HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Random = Random.new()

--==============================--
-- Session
--==============================--

local Session = {}
Session.__index = Session

-- Randomized small interval to naturally jitter pushes across servers
local FLUSH_DELTA = Random:NextInteger(5, 8)

local BUFFER: { { [string]: any } } = {}

local _onFlush: (data: any) -> () = function(_)
	-- no-op by default
end

--==============================--
-- Types
--==============================--

export type SessionType = {
	rootUrl: string,
	gameToken: string,
	jobID: string,

	_firstFlushDone: boolean,
}

local Response = {}
Response.__index = Response

export type ResponseType = {
	success: boolean,
	user_message: string,
	data: any?,
	statusCode: number,
}

export type Session = typeof(setmetatable({} :: SessionType, Session))
export type Response = typeof(setmetatable({} :: ResponseType, Response))

--==============================--
-- Utilities
--==============================--

local function nowISO(): string
	local dt = DateTime.now():ToUniversalTime()
	return string.format(
		"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
		dt.Year, dt.Month, dt.Day,
		dt.Hour, dt.Minute, dt.Second,
		dt.Millisecond
	)
end

local function toBatchItem(method: string, path: string, body: { [string]: any }?): { [string]: any }
	return {
		method = string.upper(method) .. " " .. path,
		t = nowISO(),
		-- keep native Lua table; server expects an object
		payload = body or {},
		-- lightweight client-side correlation id (handy for debugging server logs)
		rid = HttpService:GenerateGUID(false),
	}
end

--==============================--
-- Response helpers
--==============================--

function Response.new(success: boolean, user_message: string, statusCode: number, data: any?): Response
	local self = {}
	self.success = success
	self.user_message = user_message
	self.data = data
	self.statusCode = statusCode
	return setmetatable(self, Response)
end

function Response.fromRaw(res: { [string]: any }, statusCode: number): Response
	local self = {}
	local decoded = HttpService:JSONDecode(res["Body"])

	self.success = decoded.success :: boolean
	self.user_message = decoded.user_message :: string
	self.data = decoded.data
	self.statusCode = statusCode

	return setmetatable(self, Response)
end

--==============================--
-- Low-level HTTP
--==============================--

function Session:_requestRaw(url: string, method: string, body: any?): Response
	if not string.find(url, "http") then
		url = self.rootUrl .. url
	end
	local res = HttpService:RequestAsync({
		Url = url,
		Method = string.upper(method),
		Body = if body ~= nil then HttpService:JSONEncode(body) else nil,
		Headers = {
			["Authorization"] = `Game-Token {self.gameToken}`,
			["Job-ID"] = self.jobID,
			["Content-Type"] = "application/json",
		},
	})
	return Response.fromRaw(res, res.StatusCode)
end

--==============================--
-- Public API (enqueue writes, direct GET)
--==============================--

-- Queue a POST (batched via /roblox/push)
function Session.post(self: Session, path: string, body: { [string]: any }?, bypassBuffer: boolean?): string?
	if string.find(path, "telemetry") or bypassBuffer then
		self:_requestRaw(path, "POST", body)
		return
	end
	local item = toBatchItem("POST", path, body)
	table.insert(BUFFER, item)
	return item.rid
end

-- Queue a DELETE (batched via /roblox/push)
function Session.delete(self: Session, path: string, body: { [string]: any }?, _autoError: boolean?): string
	local item = toBatchItem("DELETE", path, body)
	table.insert(BUFFER, item)
	return item.rid
end

-- Direct GET (rare; kept for convenience)
function Session.get(self: Session, path: string): Response
	return self:_requestRaw(self.rootUrl .. path, "GET", nil)
end

--==============================--
-- Flush (push)
--==============================--

-- Flush the buffer immediately to /roblox/push.
function Session.Flush(self: Session, sinceISO: string?): Response?
	if #BUFFER == 0 then
		return nil
	end

	-- drain atomically
	local payload = BUFFER
	BUFFER = {}

	local url = self.rootUrl .. "/roblox/push"
	if sinceISO then
		url ..= "?since=" .. HttpService:UrlEncode(sinceISO)
	end

	local ok, resOrErr = pcall(function()
		return self:_requestRaw(url, "POST", payload)
	end)
	
	if not ok then
		-- put the batch back so next cycle retries
		for _, item in payload do
			table.insert(BUFFER, item)
		end
		warn(`[Zyntex]: /roblox/push flush failed, retrying later: {tostring(resOrErr)}`)
		return nil
	end

	local res: Response = resOrErr :: Response

	-- Invoke hook so Zyntex can react (ban/mute handling, manifest, listen_data)
	-- This is intentionally fire-and-forget; hook can be a small, synchronous handler.
	-- Expected shape: res.data = { results = [...], manifest?, listen_data? }
	local okHook, hookErr = pcall(function()
		if res.data ~= nil then
			_onFlush(res.data)
		end
	end)
	if not okHook then
		warn(`[Zyntex]: onFlush callback errored: {tostring(hookErr)}`)
	end

	-- Track “first flush that contained POST /servers”
	if not self._firstFlushDone then
		for _, item in payload do
			-- cheap prefix check; format is "METHOD /path"
			if string.sub(item.method, 1, 13) == "POST /servers" then
				self._firstFlushDone = true
				break
			end
		end
	end

	return res
end

-- Alias; some callers prefer explicit naming
function Session.FlushNow(self: Session, sinceISO: string?): Response?
	return self:Flush(sinceISO)
end

--==============================--
-- onFlush hook setter
--==============================--

-- Zyntex sets this to handle per-result errors, e.g.:
--   - method == "POST /players"
--   - success == false
--   - error == "403: reason" (ban) or "401: reason" (mute)
-- From there, Zyntex can kick/mute locally and/or print the reason.
function Session.onFlush(self: Session, cb: (data: any) -> ()): ()
	_onFlush = cb or function(_) end
end

--==============================--
-- Constructor
--==============================--

function Session.new(gameToken: string, rootUrl: string?, jobId: string?): Session
	local self: any = {}
	self.gameToken = gameToken
	self.rootUrl = rootUrl or "https://api.zyntex.dev"
	self.jobID = RunService:IsStudio() and `DEV-SERVER-{HttpService:GenerateGUID(false)}` or game.JobId
	self._firstFlushDone = false

	return setmetatable(self, Session)
end

return Session

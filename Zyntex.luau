--[[
	Zyntex Roblox SDK
	Version: 5
	Last Updated: 2025-08-02
	Author: Deluct
	
	This module is the main client for the Zyntex Advanced Admin/Ops Panel.
	It handles communication with the Zyntex API, manages server status, player events,
	and listens for administrative actions from the Zyntex dashboard.
	
	For full documentation, visit: https://docs.zyntex.dev/
]]

local Stats       = game:GetService("Stats")
local RunService  = game:GetService("RunService")
local Players     = game:GetService("Players")
local LogService  = game:GetService("LogService")
local Chat        = game:GetService("Chat")
local TCS         = game:GetService("TextChatService")
local MS          = game:GetService("MarketplaceService")

local API         = require(script.Parent:FindFirstChild("api"))
local TYPES       = require(script.Parent:FindFirstChild("types"))
local Telemetry   = require(script.Parent:FindFirstChild("Telemetry"))

local CLIENT_VERSION = 5

--[[
	@function now
	@return string
	
	Generates a UTC timestamp in ISO 8601 format. This is used for 'since'
	parameters in API calls to ensure all data is synchronized correctly.
]]
local function now()
	local dt = DateTime.now():ToUniversalTime()
	return string.format(
		"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
		dt.Year, dt.Month, dt.Day,
		dt.Hour, dt.Minute, dt.Second,
		dt.Millisecond
	)
end

--[[
	@function toFormat
	@param date DateTime
	@return string
	
	Converts a given Roblox DateTime object into a UTC timestamp in ISO 8601 format.
]]
local function toFormat(date: DateTime)
	local date = date:ToUniversalTime()
	return string.format(
		"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
		date.Year, date.Month, date.Day,
		date.Hour, date.Minute, date.Second,
		date.Millisecond
	)
end

--[[
	https://devforum.roblox.com/t/mute-players-with-textchatservice/2519300/4?u=deluc_t
]]
local function muteUserId(mutedUserId)
	-- listen for future TextSources
	TCS.DescendantAdded:Connect(function(child)
		if child:IsA("TextSource") then
			if child.UserId == mutedUserId then
				child:Destroy()
			end
		end
	end)

	-- mute any current TextSources
	for _, child in TCS:GetDescendants() do
		if child:IsA("TextSource") then
			if child.UserId == mutedUserId then
				child:Destroy()
			end
		end
	end
	
	game:GetService("ReplicatedStorage"):FindFirstChild("zyntex.events"):FindFirstChild("SystemChat"):FireClient(Players:GetPlayerByUserId(mutedUserId), `You're muted.`)
end

--[[
  _____  _                       
 |  __ \| |                      
 | |__) | | __ _ _   _  ___ _ __ 
 |  ___/| |/ _` | | | |/ _ \ '__|
 | |    | | (_| | |_| |  __/ |   
 |_|    |_|\__,_|\__, |\___|_|   
                  __/ |          
                 |___/           
                 
	This section defines the 'ZyntexPlayer' object, which represents a Player
	in the Zyntex dashboard.
]]

local ZyntexPlayer = {}
ZyntexPlayer.__index = ZyntexPlayer

-- Represents a single, recorded instance of an invoked event.
type ZyntexPlayerType = {
	id: number; -- The unique ID of this specific player. Equivalent to the Roblox UserId
	name: string; -- The player's username as it appears on Roblox.
	avatar_url: string; -- The player's headshot avatar url.
	avatar_url_cache_expiry: string; -- When the player's avatar URL expires. Not important for Roblox.
	reputation: string; -- The player's reputation enum. Can be: 'clean', 'suspect', or 'offender'. https://docs.zyntex.dev/moderation/reputation
	raw_reputation: number; -- The player's raw reputation as an integer. https://docs.zyntex.dev/moderation/reputation
}

export type ZyntexPlayer = typeof(setmetatable({} :: ZyntexPlayerType, ZyntexPlayer))

function ZyntexPlayer.new(id: number, name: string, avatar_url: string, avatar_url_cache_expiry: string, reputation: string, raw_reputation: number)
	local self = {}
	self.id = id;
	self.name = name
	self.avatar_url = avatar_url
	self.avatar_url_cache_expiry = avatar_url_cache_expiry
	self.reputation = reputation
	self.raw_reputation = raw_reputation

	return setmetatable(self, ZyntexPlayer)
end

local SERVER_ACTIVITY = {} -- stores player joins & leaves to send to Zyntex in the case that the servers go down during the server
local sendingStatus = false

--[[

  _____                                _   _               
 |_   _|                              | | (_)              
   | |  _ ____   _____   ___ __ _ | |_ _  ___  _ __   ___ 
   | | | '_ \ \ / / _ \ / __/ _` | __| |/ _ \| '_ \ / __|
  _| |_| | | \ V / (_) | (_| (_| | |_| | (_) | | | \__ \
 |_____|_| |_|\_/ \___/ \___\__,_|\__|_|\___/|_| |_|___/
                                                       
                                                       

	This section defines the 'Invocation' object, which represents a single,
	successful execution of an Event.
]]

export type Data = {{["key"]: string, ["value"]: any}}
export type DataSchema = {{["key"]: string, ["type"]: string}}

local Invocation = {}
Invocation.__index = Invocation

-- Represents a single, recorded instance of an invoked event.
type InvocationType = {
	id: number; -- The unique ID of this specific invocation.
	eventId: number; -- The ID of the Event that was invoked.
	data: Data; -- The data payload that was sent with the invocation.
	to: string; -- The destination of the invocation (e.g., a specific server or 'global').
	sender: string; -- Who or what sent the invocation (e.g., 'dashboard', 'server').
	fromServer: string; -- The ID of the server that sent the invocation, if applicable.
	invokedAt: string; -- The ISO 8601 timestamp of when the invocation occurred.
	toServer: string; -- The ID of the specific server this was sent to, if applicable.
	gameId: number; -- The Roblox Place ID where the invocation originated.
	invokedBy: number; -- The UserID of the admin who triggered the invocation from the dashboard, if applicable.
}

export type Invocation = typeof(setmetatable({} :: InvocationType, Invocation))

--[[
	@constructor Invocation.new
	@description Constructs a new Invocation object from raw data. This is typically used internally
	by the client to wrap data received from the API into a usable object.
	@param id number
	@param eventId number
	@param data Data
	@param to string
	@param sender string
	@param fromServer string
	@param invokedAt string
	@param toServer string
	@param gameId string
	@param invokedBy number
	@return Invocation
]]
function Invocation.new(id: number, eventId: number, data: Data, to: string, sender: string, fromServer: string, invokedAt: string, toServer: string, gameId: string, invokedBy: number)
	local self = {}
	self.id = id;
	self.eventId = eventId;
	self.data = data;
	self.to = to;
	self.sender = sender;
	self.fromServer = fromServer;
	self.invokedAt = invokedAt;
	self.toServer = toServer;
	self.gameId = gameId;
	self.invokedBy = invokedBy;

	return setmetatable(self, Invocation)
end

--[[

 ______                _      
|  ____|              | |     
| |__    _____ _ __  | |_ ___ 
|  __|  / / _ \ '_ \| __/ __|
| |____ V /  __/ | | | |_\__ \
|______\_/ \___|_| |_|\__|___/
                               
                               
	This section defines the 'Event' object, which represents a configurable,
	remote event that can be invoked from the game server or listened to.
]]

local Event = {}
Event.__index = Event

-- Represents a remote event defined in the Zyntex dashboard.
type EventType = {
	id: number; -- The unique ID of the event.
	name: string; -- The user-defined name of the event.
	description: string; -- The user-defined description of the event.
	dataStructure: Data; -- The schema defining the expected data payload.
	deleted: boolean; -- Whether the event has been marked as deleted.
	_zyntex: Zyntex; -- Internal reference to the main Zyntex client instance.
}

export type Event = typeof(setmetatable({} :: EventType, Event))

--[[
	@method Event:Invoke
	@description Sends an invocation for this Event to the Zyntex backend.
	This allows the game server to trigger events that can be logged or listened to by other systems.
	The data structure provided must match the schema defined on the Zyntex dashboard.
	
	@param self Event -- The event object to invoke.
	@param data Data -- A table containing the key-value data payload for the event.
	@return Invocation -- Returns an Invocation object if the API call is successful.
	
	@see https://docs.zyntex.dev/ for more details on creating and using events.
	
	@example
	local killEvent = Zyntex:GetEvent("PlayerKilled")
	killEvent:Invoke({
		killerId = 12345,
		victimId = 54321,
		weapon = "Sword"
	})
]]
function Event.Invoke(self: Event, data: Data): Invocation
	local res = self._zyntex._session:post(
		`/roblox/events/invoke`,
		{
			["event_id"] = self.id;
			["data"] = data
		}
	)

	if not res.success then
		error(`Could not invoke event {self.name}: {res.user_message}`)
	end

	return Invocation.new(
		res.data.id,
		res.data.event_id,
		res.data.data,
		res.data.to,
		res.data.sender,
		res.data.from_server,
		res.data.invoked_at,
		res.data.to_server,
		res.data.game_id,
		res.data.invoked_by
	)
end

--[[
	@method Event:Connect
	@description Establishes a listener for this specific event. The provided callback function
	will be executed whenever an invocation for this event is received from the Zyntex backend (e.g., sent from the dashboard).
	
	@param self Event -- The event object to listen to.
	@param listener (({[string]: any}, Invocation) -> nil) -- The callback function to execute.
		- The first argument passed to the listener is a simplified data table: `{["key"] = value}`.
		- The second argument is the full, raw Invocation object.
	
	@example
	local broadcastEvent = Zyntex:GetEvent("BroadcastMessage")
	broadcastEvent:Connect(function(data, invocation)
		print(`Received broadcast from user {invocation.invokedBy}: {data.Message}`)
	end)
]]
function Event.Connect(self: Event, listener: ({[string]: any}, Invocation) -> nil)
	local function wrapper(inv)
		if inv.event_id == self.id then
			local simpleData = {}

			for _,v in pairs(inv.data) do
				simpleData[v["key"]] = v["value"]
			end

			listener(
				simpleData, 
				Invocation.new(
					inv.id,
					inv.event_id,
					inv.data,
					inv.to,
					inv.sender,
					inv.from_server,
					inv.invoked_at,
					inv.to_server,
					inv.game_id,
					inv.invoked_by
				)
			)
		end
	end
	if not self._zyntex._listeners["invocation"] then
		self._zyntex._listeners["invocation"] = {}
	end
	table.insert(
		self._zyntex._listeners["invocation"], 
		wrapper
	)
end

--[[
	@constructor Event.new
	@description Constructs a new Event object. This is used internally during the initialization
	process to populate the list of available events from the Zyntex backend.
]]
function Event.new(zyntex: Zyntex, id: number, name: string, description: string, dataStructure: DataSchema, deleted: boolean)
	local self = {}
	self.id = id
	self.name = name
	self.description = description
	self.dataStructure = dataStructure
	self.deleted = deleted
	self._zyntex = zyntex

	return setmetatable(self, Event)
end

--[[
  ______                _   _                 
 |  ____|              | | (_)                
 | |__ _   _ _ __   ___| |_ _  ___  _ __  ___ 
 |  __| | | | '_ \ / __| __| |/ _ \| '_ \/ __|
 | |  | |_| | | | | (__| |_| | (_) | | | \__ \
 |_|   \__,_|_| |_|\___|\__|_|\___/|_| |_|___/
                                              
	This section defines the 'Function' object, which is similar to events, but
	can only be invoked from the web-dashboard and it sends back data
]]

local Function = {}
Function.__index = Function

type FunctionParameter = {
	name: string; -- The name of the paramater
	type: string; -- The type of the parameter's value
}

-- Represents a remote function defined in the Zyntex dashboard.
type FunctionType = {
	id: number; -- The unique ID of the function.
	name: string; -- The user-defined name of the event.
	description: string; -- The user-defined description of the event.
	parameters: {FunctionParameter}; -- The list of parameters the function accepts
	_zyntex: Zyntex;
	
	Connect: (self: Function, listener: ({[string]: any}) -> any) -> nil;
	
}

export type Function = typeof(setmetatable({} :: FunctionType, Function))

--[[
	@constructor Function.new
	@description Constructs a new Function object that represents a callable remote function
	defined in the Zyntex dashboard. This is typically used internally when the client
	initializes and materializes the functions available to your experience.

	@param zyntex Zyntex -- The active Zyntex client, used for networking and configuration.
	@param id number -- The unique ID of the remote function.
	@param name string -- The user-defined name of the function.
	@param description string -- A human-readable description of the function.
	@param parameters {FunctionParameter} -- The schema describing the parameters this function accepts.

	@return Function -- The constructed Function instance.
]]
function Function.new(zyntex: Zyntex, id: number, name: string, description: string, parameters: {FunctionParameter})
	local self = {}
	self.id = id
	self.name = name
	self.description = description
	self.parameters = parameters
	self._zyntex = zyntex

	return setmetatable(self, Function)
end

--[[
	@method Function:Connect
	@description Registers a listener that will be invoked whenever a call targeting this
	remote function is received from the Zyntex backend. The listener is passed a simple
	parameters table and is expected to return a value (typically a table) which will be
	sent back to Zyntex as the payload response.

	@param self Function -- The Function instance to listen on.
	@param listener (({[string]: any}) -> any) -- Callback executed when this function is invoked.
		- Receives: a table of parameter key/value pairs (`metadata.parameters`).
		- Returns: any serializable value (commonly a table) that becomes the payload response.

	@return nil -- This method registers the listener and does not return a connection handle.

	@errors Asserts if the payload POST fails; the assertion message is the API's `user_message`.

	@example
	-- Assume a remote function "Add" with parameters: { a: number, b: number }
	local addFn = Zyntex:GetFunction("Add")
	addFn:Connect(function(params)
		local a = params.a
		local b = params.b
		-- Whatever is returned here is sent back to Zyntex as the payload:
		return { sum = a + b }
	end)
]]
function Function.Connect(self: Function, listener: ({[string]: any}) -> any)
	local function wrapper(data)
		if data.metadata.function_id == self.id then
			if self._zyntex._config.debug then
				print(`[Zyntex]: Function received, calling listener...`)
			end

			local payload = listener(
				data.metadata.parameters
			)

			if self._zyntex._config.debug then
				print(`[Zyntex]: Sending payload response...`)
			end
			
			assert(payload ~= nil, 'Function:Connect hook must return a value')

			local callRes = self._zyntex._session:post(
				`/roblox/actions/{data.id}/send_payload`,
				{ ["data"] = payload }
			)
			
			assert(callRes.success, callRes.user_message)

			if self._zyntex._config.debug then
				print(`[Zyntex]: Successfully sent payload response to function`)
			end
		end
	end
	if not self._zyntex._listeners["function"] then
		self._zyntex._listeners["function"] = {}
	end
	table.insert(
		self._zyntex._listeners["function"], 
		wrapper
	)
end


--[[

  ______           _            
 |___  /          | |           
    / /_ __ _ _ __ | |_ _____  __
   / /| | | | '_ \| __/ _ \ \/ /
  / /_| |_| | | | | ||  __/>  < 
 /_____\__, |_| |_|\__\___/_/\_\
        __/ |                  
       |___/                   

	This section defines the main 'Zyntex' client object, which serves as the primary
	interface for interacting with the entire Zyntex system.
]]

local Zyntex = { VERSION = CLIENT_VERSION }
Zyntex.__index = Zyntex

-- The main state container for the Zyntex client.
type ZyntexType = {
	_session: API.Session; -- Handles authenticated requests to the Zyntex API.
	_config:  TYPES.Config; -- Stores the user-defined configuration for the client.
	_events:  {Event}; -- A list of all available Event objects fetched from the backend.
	_functions: {Function}; -- A list of all available Function objects fetched from the backend.
	_listeners: {[string]: ({[string]: any}) -> nil}; -- A dictionary of listeners for incoming actions (e.g., 'shutdown', 'rce').
	_version: number
}

export type Zyntex = typeof(setmetatable({} :: ZyntexType, Zyntex))

local maxPlayers = 0;

--[[
	@function serverStatus
	@description Gathers real-time performance metrics about the current server instance.
	@return table -- A dictionary containing health status, memory usage, network traffic, and FPS.
]]
local function serverStatus()
	local maxMemory = 6400 + 100 * maxPlayers
	local stats = {
		["memory_usage"] = Stats:GetTotalMemoryUsageMb() / maxMemory,
		["data_receive_kbps"] = Stats.DataReceiveKbps or 0,
		["data_send_kbps"] = Stats.DataSendKbps or 0,
		["server_fps"] = math.clamp(1/RunService.Heartbeat:Wait(), 0, 100),
		["activity"] = SERVER_ACTIVITY
	}

	if stats.memory_usage > .5 or stats.data_send_kbps > 500 or stats.data_receive_kbps > 500 or stats.server_fps < 30 then
		stats["health"] = "unhealthy"
		return stats
	end

	stats["health"] = "healthy"
	return stats
end

--[[
	@method Zyntex:statusUpdate
	@description Sends the server's current health and performance metrics to the Zyntex dashboard.
	@param self Zyntex
	@param status {string: number} -- A table of metrics generated by `serverStatus()`.
]]
function Zyntex.statusUpdate(self: Zyntex, status: {string: number})
	if sendingStatus then return end
	sendingStatus = true
	if self._config.debug then
		print("[Zyntex]: Submitting server status update...")
	end

	pcall(function()
		local res = self._session:post(
			"/roblox/servers/status", 
			status
		)

		if not res.success then
			warn(`Failed to submit server status update: {res.user_message}`)
		end

		if self._config.debug then
			print("[Zyntex]: Sent server status update")
		end
	end)
	
	sendingStatus = false
end

--[[
	@function statusUpdateLoop
	@description A background loop that periodically collects and sends server status updates.
	It intelligently sends updates only when metrics have changed to reduce unnecessary network traffic.
	@param self Zyntex
]]
local function statusUpdateLoop(self: Zyntex)
	local lastStatus = serverStatus()

	while true do
		task.wait(15)

		local newStatus = serverStatus()

		self:statusUpdate(newStatus)
	end
end

--[[
	@function onPlayerAdd
	@description Handles all tasks associated with a player joining the game, including
	registering them with the Zyntex backend and setting up client-side scripts.
	@param self Zyntex
	@param player Player -- The player who just joined.
]]
local function onPlayerAdd(self: Zyntex, player: Player)
	if self._config.debug then
		print(`[Zyntex]: Handling player join for {player.Name}`)
	end
	
	local when = now()
	local activity = {
		player_id = player.UserId,
		player_name = player.Name,
		joined_at = when
	}
	
	-- Register the player's session with the Zyntex backend.
	local res = self._session:post(
		"/roblox/players", 
		{
			["id"] = player.UserId,
			["name"] = player.Name,
			["timestamp"] = when
		},
		false
	)
	
	pcall(function()
		if not res.success then
			local _warn = true		
			-- Handle if the player is banned.
			if res.statusCode == 403 then
				if #self._listeners["ban"] == 0 then
					player:Kick(res.user_message)
					warn(`[Zyntex]: {player.Name} attempted to join but they are banned.`)
				else
					for _,listener in self._listeners["ban"] do
						listener(player.UserId, res.user_message)
					end
				end
				return
			end
			if res.statusCode == 403 then
				if #self._listeners["ban"] == 0 then
					muteUserId(player.UserId)
					warn(`[Zyntex]: {player.Name} attempted to join and are automatically muted.`)
				else
					for _,listener in self._listeners["ban"] do
						listener(player.UserId, res.user_message)
					end
				end
				_warn = false
			end
			if _warn then
				warn(`[Zyntex]: Could not submit POST /roblox/players: "{res.user_message}"`)
			end
		end

		if self._config.debug then
			print("[Zyntex]: Player join submitted.")
		end
		
		local zyntexEvents = Instance.new("Folder")
		zyntexEvents.Name = "zyntex.events"
		zyntexEvents.Parent = script.Parent
		
		local SystemChat = Instance.new("RemoteEvent")
		SystemChat.Name = "SystemChat"
		SystemChat.Parent = zyntexEvents

		-- Clone necessary client-side remote events into ReplicatedStorage if they don't exist.
		if not game:GetService("ReplicatedStorage"):FindFirstChild("zyntex.events") then
			zyntexEvents:Clone().Parent = game:GetService("ReplicatedStorage")
		end

		-- Provide the player with the client-side script handler.
		script.Parent:FindFirstChild("zyntex.client"):Clone().Parent = player.PlayerGui

		-- Listen for player chats and log them.
		pcall(function()
			player.Chatted:Connect(function(msg)
				self._session:post(
					"/roblox/players/chat",
					{
						["message"] = msg;
						["player_id"] = player.UserId
					}
				)
			end)
		end)

		-- Track the maximum concurrent players for server health calculations.
		local count = #Players:GetPlayers()
		if count > maxPlayers then
			maxPlayers = count
		end
	end)
	
	if tonumber(res.data) then
		activity["visit_id"] = tonumber(res.data)
	end
	
	table.insert(SERVER_ACTIVITY, activity)
end

--[[
	@function onPlayerRemove
	@description Handles a player leaving the game by notifying the Zyntex backend,
	which marks the player's session as ended.
	@param self Zyntex
	@param player Player -- The player who just left.
]]
local function onPlayerRemove(self: Zyntex, player: Player)
	if self._config.debug then
		print(`[Zyntex]: Handling player leave for {player.Name}`)
	end
	
	local when = now()

	local res = self._session:delete(
		"/roblox/players",
		{
			["id"] = player.UserId,
			["timestamp"] = when
		},
		false
	)
		
	if not res.success then
		warn(`[Zyntex]: Could not submit DELETE /roblox/players: "{res.user_message}"`)
	end

	if self._config.debug then
		print("[Zyntex]: Player leave submitted.")
	end
	
	for _,activity in SERVER_ACTIVITY do
		if activity.player_id == player.UserId and activity.left_at == nil then
			activity["left_at"] = when
			activity["visit_id"] = res.data
		end
	end
end

--[[
	@method Zyntex:GetEventByID
	@description Fetches a pre-loaded Event object using its unique numerical ID.
	@param self Zyntex
	@param eventId number -- The ID of the event to retrieve.
	@return Event? -- The corresponding Event object, if exists.
]]
function Zyntex.GetEventByID(self: Zyntex, eventId: number): Event?
	for i,event in pairs(self._events) do
		if event.id == eventId then
			return event
		end
	end
	return nil
end

--[[
	@method Zyntex:GetEvent
	@description Fetches a pre-loaded Event object using its unique string name. This is the most common way to get an event.
	@param self Zyntex
	@param eventName string -- The case-sensitive name of the event.
	@return Event? -- The corresponding Event object, if it exists.
]]
function Zyntex.GetEvent(self: Zyntex, eventName: string): Event?
	for i,event in pairs(self._events) do
		if event.name == eventName then
			return event
		end
	end
	return nil
end

--[[
	@method Zyntex:GetFunctionByID
	@description Fetches a pre-loaded Function object using its unique numerical ID.
	@param self Zyntex
	@param functionId number -- The ID of the function to retrieve.
	@return Function? -- The corresponding Function object, if it exists.
]]
function Zyntex.GetFunctionByID(self: Zyntex, functionId: number): Function?
	for i,func in self._functions do
		if func.id == functionId then
			return func
		end
	end
	return nil
end

--[[
	@method Zyntex:GetFunction
	@description Fetches a pre-loaded Function object using its unique string name. This is the most common way to get a function.
	@param self Zyntex
	@param functionName string -- The case-sensitive name of the function.
	@return Function? -- The corresponding Function object, if it exists.
]]
function Zyntex.GetFunction(self: Zyntex, functionName: string): Function?
	for i,func in self._functions do
		if func.name == functionName then
			return func
		end
	end
	return nil
end

--[[
	@method Zyntex:Moderate
	@description Submits a generic moderation action to the Zyntex backend. This is a flexible, low-level function;
	it is often easier to use the shorthand methods (:Ban, :Kick, :Mute, :Report).
	
	@warning If the `test` parameter is `false` or `nil` (and not in Studio), this action WILL permanently affect a player's reputation.
	
	@param self Zyntex
	@param player (Player | number) -- The Player object or the UserId of the target.
	@param type string -- The type of moderation (e.g., "ban", "kick", "mute", "report").
	@param reason string -- The reason for the moderation action. This will be visible to staff.
	@param expiresAt (DateTime?) -- An optional DateTime for when the moderation expires. If nil, it may be permanent depending on the type.
	@param test (boolean?) -- If `true`, the moderation is treated as a test and does not affect reputation. Defaults to `true` in Studio.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.Moderate(self: Zyntex, player: Player | number, type: string, reason: string, expiresAt: DateTime?, test: boolean?)
	local playerId = if typeof(player) == "Player" then player.UserId else player
	local playerObject = Players:GetPlayerByUserId(playerId)
	if self._config.debug then
		print(`[Zyntex]: Creating moderation {type} for {playerId}...`)
	end
	if expiresAt then
		expiresAt = toFormat(expiresAt)
	end

	-- Default to test mode if running in Roblox Studio unless explicitly overridden.
	if test == nil then
		test = RunService:IsStudio()
	end
	
	if type == "ban" then
		playerObject:Kick(reason)
	end
	
	local res = self._session:post(
		`/roblox/players/{playerId}/moderate`,
		{
			["type"] = type,
			["reason"] = reason,
			["expires_at"] = expiresAt,
			["test"] = test
		}
	)

	assert(res.success, `Failure when attempting to create moderation: {res.user_message}`)

	if self._config.debug then
		print(`[Zyntex]: Moderation created successfully.`)
	end

	return res.success
end

--[[
	@method Zyntex:Report
	@description Shorthand method to create a "report" moderation. Reports are used for logging player behavior
	and contribute to their reputation score but do not have direct in-game consequences by default.
	@param self Zyntex
	@param player (Player | number) -- The Player object or the UserId of the target.
	@param reason string -- The reason for the report.
	@param test (boolean?) -- If true, the report will not affect player reputation. Defaults to `true` in Studio.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.Report(self: Zyntex, player: Player | number, reason: string, test: boolean?)
	return self:Moderate(player, "report", reason, nil, test)
end

--[[
	@method Zyntex:Ban
	@description Shorthand method to create a "ban" moderation. This logs the ban action.
	Handles automatic kick automatically.
	@param self Zyntex
	@param player (Player | number) -- The Player object or the UserId of the target.
	@param reason string -- The reason for the ban.
	@param expiresAt (DateTime?) -- Optional expiration for the ban. If nil, the ban is permanent.
	@param test (boolean?) -- If true, the ban will not affect player reputation. Defaults to `true` in Studio.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.Ban(self: Zyntex, player: Player | number, reason: string, expiresAt: DateTime?, test: boolean?)
	return self:Moderate(player, "ban", reason, expiresAt, test)
end

--[[
	@method Zyntex:Mute
	@description Shorthand method to create a "mute" moderation. This logs the mute action.
	Mutes the player automatically.
	@param self Zyntex
	@param player (Player | number) -- The Player object or the UserId of the target.
	@param reason string -- The reason for the mute.
	@param expiresAt (DateTime?) -- Optional expiration for the mute. If nil, the mute is permanent.
	@param test (boolean?) -- If true, the mute will not affect player reputation. Defaults to `true` in Studio.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.Mute(self: Zyntex, player: Player | number, reason: string, expiresAt: DateTime?, test: boolean?)
	return self:Moderate(player, "mute", reason, expiresAt, test)
end

--[[
	@method Zyntex:Kick
	@description Shorthand method to create a "kick" moderation. This logs the kick action.
	Calls Player:Kick() automatically.
	@param self Zyntex
	@param player (Player | number) -- The Player object or the UserId of the target.
	@param reason string -- The reason for the kick.
	@param test (boolean?) -- If true, the kick will not affect player reputation. Defaults to `true` in Studio.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.Kick(self: Zyntex, player: Player | number, reason: string, test: boolean?)
	return self:Moderate(player, "kick", reason, nil, test)
end

--[[
	@method Zyntex:poll
	@description Initiates the long-polling loop to listen for real-time actions and invocations
	from the Zyntex dashboard. This runs in its own thread.
	@param self Zyntex
	@param since string -- An ISO 8601 timestamp to start listening from.
	@return (-> ()) -- Returns the polling function to be spawned in a new thread.
]]
function Zyntex.poll(self: Zyntex, since: string)
	return function()
		-- The wait time between polls, increases dynamically when no events are received.
		local nextWaitTime = 2;
		while true do
			if self._config.debug then
				print("[Zyntex]: Polling for updates...")
			end

			local res

			local success,data = pcall(function()
				res = self._session:get(`/roblox/listen?since={since}`)

				if not res.success then
					error(`[Zyntex]: Failure to poll for updates: {res.user_message}`)
				end
			end)

			if not success then
				warn(data)
				task.wait(nextWaitTime + 10) -- Longer wait on error
				continue
			end

			-- If the response was empty, slightly increase the wait time for the next poll.
			if #res.data == 0 then
				nextWaitTime = math.clamp(nextWaitTime + .1, 2, 5)
			end

			-- If we received data, reset the poll timer and update the 'since' timestamp.
			if #res.data > 0 then
				nextWaitTime = 2
				since = now()
			end

			-- Dispatch received events to their corresponding listeners.
			for i,event in pairs(res.data) do
				for _,listener in pairs(self._listeners[event.type]) do
					listener(event.data)
				end
			end

			task.wait(nextWaitTime)
		end
	end
end

--[[
	@method Zyntex:logServiceMessage
	@description Internal handler for capturing messages from Roblox's LogService (print, warn, error)
	and forwarding them to the Zyntex logs for the server.
	@param self Zyntex
	@param msg string -- The content of the log message.
	@param type Enum.MessageType -- The type of message (Output, Info, Warning, Error).
]]
function Zyntex.logServiceMessage(self: Zyntex, msg: string, type: Enum.MessageType)
	local convertedType: string?
	if type == Enum.MessageType.MessageOutput then
		convertedType = "info.print"
	end
	if type == Enum.MessageType.MessageError then
		convertedType = "info.error"
	end
	if type == Enum.MessageType.MessageWarning then
		convertedType = "info.warning"
	end
	if convertedType == nil then
		return type
	end

	-- Truncate long messages to prevent overly large payloads.
	local msg = string.sub(msg, 1, 100)    

	pcall(function()
		self._session:post(
			"/roblox/logservice",
			{
				["message"] = msg,
				["type"] = convertedType
			}
		)
	end)
end

--[[
	@method Zyntex:Log
	@description Logs a custom message to the Zyntex servers. This is useful for tracking specific
	game events. The log will appear in the main logs, the server's log tab, and the associated player's log tab if a player is provided.
	
	@param self Zyntex
	@param message string -- The custom message to log.
	@param player (Player? | number?) -- Optional. The Player or UserId to associate with this log entry.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.Log(self: Zyntex, message: string, player: Player? | number?)
	if self._config.debug then
		print(`[Zyntex]: Posting log...`)
	end
	local playerId, playerName;
	if player then
		playerId = if typeof(player) == "Player" then player.UserId else player
		playerName = if typeof(player) == "Player" then player.Name else Players:GetPlayerByUserId(player).Name
	end

	local payload = {
		["message"] = message
	}

	if playerId then
		payload["player_id"]   = playerId
		payload["player_name"] = playerName
	end

	local res = self._session:post(
		`/roblox/log`,
		payload
	)

	assert(res.success, `Failure when attempting to post log: {res.user_message}`)

	if self._config.debug then
		print(`[Zyntex]: Log posted succesfully.`)
	end

	return res.success
end

--[[
	@method Zyntex:ProcessPurchase
	@description Logs a player's in-game purchase. This should be wired up to `MarketplaceService.ProcessReceipt`
	to track player spending and LTV on the dashboard.
	
	@param self Zyntex
	@param player (Player | number) -- The Player object or UserId who made the purchase.
	@param price number -- The price of the item in Robux.
	@param productName string -- The name of the product purchased. Using the name is preferred over the ID for clarity on the dashboard.
	@return boolean -- Returns `true` on success.
]]
function Zyntex.ProcessPurchase(self: Zyntex, player: Player | number, price: number, productName: string): boolean
	local res = self._session:post(
		`/roblox/players/{if type(player) == "number" then player else player.UserId}/robux-spent`,
		{
			["robux_spent"] = price;
			["metadata"]    = productName
		}
	)

	assert(res.success, `Failed when attempting to process purchase: {res.user_message}`)

	return res.success
end

--[[
	@constructor Zyntex.new
	@description Constructs the main Zyntex client object and validates the API connection.
	It also checks if the client version is up-to-date with the latest version recommended by the backend.
	
	@param gameToken string -- The unique game token obtained from the Zyntex dashboard.
	@return Zyntex -- The newly created Zyntex instance.
]]
function Zyntex.new(gameToken: string): Zyntex
	local self = {}

	self._session   = API.new(gameToken)
	self._config    = {}
	self._events    = {}
	self._functions = {}
	self._listeners = {}
	self._version   = CLIENT_VERSION

	local current_version = self._session:get("/roblox/latest-client-version")

	assert(current_version.success, `Zyntex API is currently down.`)

	if (current_version.data ~= CLIENT_VERSION) then
		warn(`[Zyntex]: Your client is outdated, please download the latest version. current: v{CLIENT_VERSION}; latest: v{current_version.data}`)
	end

	return setmetatable(self, Zyntex)
end

--[[
	@function randomUsername
	@description Generates a random username for simulation purposes.
]]
local function randomUsername()
	return "User_" .. math.random(1000, 9999)
end

--[[
	@function simulateActivity
	@description When `config.simulate` is true, this function creates fake player join/leave events
	to help test the system in Studio without needing real players.
]]
local function simulateActivity(self)
	local fakePlayers = {}

	while true do
		task.wait(math.random(0.1, 10))

		local action = math.random(1, 4)

		if action == 1 or action == 2 then
			-- Simulate Player Join
			local name = randomUsername()
			local id = 16054156146
			local fakePlayer = {
				Name = name,
				UserId = id
			}
			table.insert(fakePlayers, fakePlayer)
			pcall(onPlayerAdd, self, fakePlayer)

		elseif (action == 3 or action == 4) and #fakePlayers > 0 then
			-- Simulate Player Leave
			local index = math.random(1, #fakePlayers)
			local fakePlayer = table.remove(fakePlayers, index)
			pcall(onPlayerRemove, self, fakePlayer)
		end
	end
end

--[[
	@method Zyntex:GetPlayerInfo
	@description Fetches and returns player information, such as reputation, total robux spent, and total time played.
	
	@param self Zyntex
	@param player Player|number -- Either a Player object or the player's UserId. If UserId, the player does not have to be in the server.
]]
function Zyntex.GetPlayerInfo(self: Zyntex, player: Player | number): {player: ZyntexPlayer, total_robux_spent: number, total_time_played: number}
	local res = self._session:get(`/roblox/players/{if type(player) == "number" then player else player.UserId}`)

	assert(res.success, `Failed when attempting to fetch player: {res.user_message}`)

	local playerInfo = res.data
	local playerInfoRaw = res.data.player
	
	playerInfo["player"] = ZyntexPlayer.new(
		playerInfoRaw.id,
		playerInfoRaw.name,
		playerInfoRaw.avatar_url,
		playerInfoRaw.avatar_url_cache_expiry,
		playerInfoRaw.reputation,
		playerInfoRaw.raw_reputation
	)
	
	return playerInfo
end

--[[
	@method Zyntex:OnModeration
	@description Creates a hook to the moderation action.
	
	@param self Zyntex
	@param moderationType string -- Returns a moderationType. Either 'ban', 'mute', or 'kick'.
	@param callback (playerId: number, reason: string) -> nil -- The callback that is called whenever the moderation occurs.
]]
function Zyntex.OnModeration(self: Zyntex, moderationType: string, callback: (player: number, reason: string) -> nil)
	table.insert(self._listeners[moderationType], callback)
end

--[[
	@method Zyntex:OnModeration
	@description Creates a hook to the 'kick' mo	eration action.
	
	@param self Zyntex
	@param callback (playerId: number, reason: string) -> nil -- The callback that is called whenever the kick occurs.
]]
function Zyntex.OnKick(self: Zyntex, callback: (player: number, reason: string) -> nil)
	return self:OnModeration("kick", callback)
end

--[[
	@method Zyntex:OnModeration
	@description Creates a hook to the 'ban' moderation action.
	
	@param self Zyntex
	@param callback (playerId: number, reason: string) -> nil -- The callback that is called whenever the ban occurs.
]]
function Zyntex.OnBan(self: Zyntex, callback: (player: number, reason: string) -> nil)
	return self:OnModeration("ban", callback)
end

--[[
	@method Zyntex:OnMute
	@description Creates a hook to the 'mute' moderation action.
	
	@param self Zyntex
	@param callback (playerId: number, reason: string) -> nil -- The callback that is called whenever the mute occurs.
]]
function Zyntex.OnMute(self: Zyntex, callback: (player: number, reason: string) -> nil)
	return self:OnModeration("mute", callback)
end

--[[
	@method Zyntex:init
	@description The main entry point to start the Zyntex client. This function initializes all core processes:
	it registers the server with the Zyntex backend, starts the status update and polling loops,
	sets up event listeners, and connects player tracking signals.
	
	@param self Zyntex
	@param config TYPES.Config -- A configuration table that controls client behavior (e.g., `debug`, `simulate`).
]]
function Zyntex.init(self: Zyntex, config: TYPES.Config)
	self._config = config

	local since = now()

	if config.debug then
		print("[Zyntex]: Zyntex.init")
		print("[Zyntex]: Initializing server...")
	end

	--// Initial server creation
	local privateServerId = game.PrivateServerId
	local privateServerParameter = ""
	if privateServerId ~= "" and game.PrivateServerOwnerId ~= 0 then
		privateServerParameter = `&isPrivate={privateServerId}`
	end
	local response = self._session:post(`/roblox/servers?version={game.PlaceVersion}{privateServerParameter}`)

	if response.success == false then
		error(`Error when attempting to initialize server: {response.user_message}`)
	end

	--// Capture and send historical logs from before the client initialized.
	-- Don't want to send 300 messages all at once :)
	task.spawn(function()
		local history = LogService:GetLogHistory()
		local delay   = 0
		if #history > 5 then
			delay = 1
		end
		-- Avoid sending an excessive number of historical logs.
		if #history > 30 then
			return
		end
		for _,message in pairs(history) do
			self:logServiceMessage(message.message, message.messageType)
			task.wait(delay)
		end
	end)

	--// Connect live LogService listener.
	LogService.MessageOut:Connect(function(msg: string, type: Enum.MessageType)
		self:logServiceMessage(msg, type)
	end)

	if config.debug then
		print("[Zyntex]: Server initialized")
	end

	--// On server shutdown, notify the Zyntex backend.
	game:BindToClose(function()
		if config.debug then
			print("[Zyntex]: Server closing...")
		end
		sendingStatus = true
		self._session:delete("/roblox/servers")
	end)

	--// Start the background processes.
	task.spawn(statusUpdateLoop, self)
	task.spawn(self:poll(since))

	if config.debug then
		print("[Zyntex]: Fetching events...")
	end

	--// Fetch event + function manifest
	local res = self._session:get("/roblox/manifest")

	if not res.success then
		warn(`[Zyntex]: Could not fetch manifest: {res.user_message}`)
	end

	for i,v in pairs(res.data) do
		if v.type == "function" then
			table.insert(self._functions, Function.new(
				self,
				v.id,
				v.name,
				v.description,
				v.parameters
				)
			)
			continue
		end
		table.insert(self._events, Event.new(
			self,
			v.id,
			v.name,
			v.description,
			v.data,
			false
			)
		)
	end

	--// Handle server shutdown action from the dashboard.
	self._listeners["shutdown"] = {}
	table.insert(self._listeners["shutdown"], function(action)
		local reason = action.metadata

		-- Kick all current and future players with the provided reason.
		for _,player in pairs(Players:GetPlayers()) do
			player:Kick(reason)
		end

		Players.PlayerAdded:Connect(function(player)
			player:Kick(reason)
		end)

		-- Notify the dashboard that the action has been fulfilled.
		local res = self._session:post(
			`/roblox/actions/{action.id}/fulfill`
		)

		if not res.success then
			warn(`[Zyntex]: Server shutdown fulfillment failed: {res.user_message}`)
		end

		if config.debug then
			print(`[Zyntex]: Server shutdown fulfilled.`)
		end
	end)

	--// Handle remote code execution (RCE) action from the dashboard.
	self._listeners["rce"] = {}
	table.insert(self._listeners["rce"], function(action)
		local code = action.metadata

		if config.debug then
			print(`[Zyntex]: Fulfilling RCE request...`)
		end

		-- Execute the code in a protected call to prevent crashes.
		task.spawn(function()
			local success,data = pcall(function()
				local executable,msg = require(script.Parent:FindFirstChild("Loadstring") :: ModuleScript)(code)
				executable()
			end)

			if not success then
				warn(`RCE Failure: {data}`)
			end
		end)

		local res = self._session:post(
			`/roblox/actions/{action.id}/fulfill`
		)

		if not res.success then
			warn(`[Zyntex]: RCE fulfillment failed: {res.user_message}`)
		end

		if config.debug then
			print(`[Zyntex]: RCE fulfilled.`)
		end
	end)

	--// Handle system chat message action from the dashboard.
	self._listeners["chat"] = {}
	table.insert(self._listeners["chat"], function(action)
		if config.debug then
			print(`[Zyntex]: Fulfilling chat request...`)
		end

		-- Fire a remote event to all clients to display a system message.
		game:GetService("ReplicatedStorage"):FindFirstChild("zyntex.events"):FindFirstChild("SystemChat"):FireAllClients(action.metadata)

		local res = self._session:post(
			`/roblox/actions/{action.id}/fulfill`
		)

		if not res.success then
			warn(`[Zyntex]: Chat fulfillment failed: {res.user_message}`)
		end

		if config.debug then
			print(`[Zyntex]: Chat fulfilled.`)
		end
	end)
	
	--// Handle moderation action from the dashboard.
	self._listeners["moderation"] = {}
	self._listeners["ban"]  = {}
	self._listeners["mute"] = {}
	self._listeners["kick"] = {}
	self._listeners["report"] = {}
	table.insert(self._listeners["moderation"], function(action)
		if config.debug then
			print(`[Zyntex]: Fulfilling moderation request...`)
			print(`[Zyntex]: {action}`)
		end
		
		local fullfilled = false
		
		local type = action.metadata.type
		local player_id = action.metadata.player_id
		local reason = action.metadata.reason
		
		
		if #self._listeners[type] == 0 then
			if type == "ban" or type == "kick" then
				local player = Players:GetPlayerByUserId(player_id)
				if player then
					player:Kick(reason)
					fullfilled = true
				end
			end
			
			if type == "mute" then
				local player = Players:GetPlayerByUserId(player_id)
				if player then
					muteUserId(player.UserId)
					fullfilled = true
				end
			end
		else
			for _,listener in self._listeners[type] do
				listener(player_id, reason)
			end
			fullfilled = true
		end
		
		if fullfilled then
			local res = self._session:post(
				`/roblox/actions/{action.id}/fulfill`
			)

			if not res.success then
				warn(`[Zyntex]: Moderation fulfillment failed: {res.user_message}`)
			end
		end

		if config.debug then
			print(`[Zyntex]: Moderation request fulfilled.`)
		end
	end)

	--// If simulation is enabled in the config, start the activity simulator.
	if config.simulate then
		task.spawn(function()
			simulateActivity(self)
		end)
	end
	
	--// Connect player join/leave listeners.
	Players.PlayerAdded:Connect(function(player: Player)
		return onPlayerAdd(self, player)
	end)

	--// Ensure any players already present at initialization are registered.
	for i,player in Players:GetPlayers() do
		onPlayerAdd(self, player)
	end
	
	Players.PlayerRemoving:Connect(function(player: Player)
		return onPlayerRemove(self, player)
	end)
end

--[[
	@method Zyntex:link
	@description A utility function used during initial setup. When called, it attempts
	to link the provided game token to the user's Roblox account via the Zyntex backend.
	This is typically only run once from the command bar in Studio.
]]
function Zyntex.link(self: Zyntex)
	local response = self._session:post("/links/games/link")

	if response.success == false then
		if response.statusCode == 404 then
			error(`Game token "{self._session.gameToken}" not found. Please make sure you pasted the full linking script from the site.`)
		end
		error(`Linking failed: {response.user_message}`)
	end

	print(`[Zyntex]: Linking success!`)
end

--[[
	@method Zyntex:Telemetry
	@description Constructs a new Telemetry object used for prometheus-style metrics.
	@param flushEvery number? -- How often to flush the buffer in seconds. Default is 10,
	which is the minimum to not get ratelimited.
	@param registryName string? -- The name of the registry. Default is "default"
]]
function Zyntex.Telemetry(self: Zyntex, flushEvery: number?, registryName: string?)
	if not flushEvery then
		flushEvery = 10
	end
	assert(flushEvery >= 10, `flushEvery must be no less than 10`)
	return Telemetry.new(
		registryName,
		flushEvery,
		self._session
	)
end

--[[
	The Zyntex module is returned to be required and used by other server scripts.
]]

return Zyntex

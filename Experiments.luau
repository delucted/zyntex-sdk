local Session = require(script.Parent:WaitForChild("api"))

local Experiment = {}
Experiment.__index = Experiment

-- Represents an experiment instance
type ExperimentType = {
	id: string; -- The unique ID of the experiment (e.g., "new_shop_ui").
	_session: Session.Session; -- Reference to the main Zyntex session.
}

export type Experiment = typeof(setmetatable({} :: ExperimentType, Experiment))

local Group = {}
Group.__index = Group

-- Represents a group instance
type GroupType = {
	id: string; -- The unique ID of the group (e.g., "group_a").
	playerId: number; -- The ID of the player that is in this group
	_experiment: Experiment;
}

export type Group = typeof(setmetatable({} :: GroupType, Group))

--[[
	@function Group:Convert
	@description Registers a conversion for that player in the group.
	@param value number? -- The value this conversion provided. For example: total robux spent, time spent completing tutorial
]]
function Group.Convert(self: Group, value: number?)
	self._experiment._session:post(`/experiments/{self._experiment.id}`, {
		value = value or 0;
		group_id = self.id;
		player_id = self.playerId;
	},
		true
	)
end

--[[
	@constructor Group.new
	@description Constructs a new Group object.
	@param session Session -- Reference to the main client (for API calls).
	@param id string -- Group ID as defined in the dashboard.
	@return Group
]]
function Group.new(Experiment: Experiment, id: string, playerId: number)
	local self = {}
	self.id = id
	self.playerId = playerId
	self._experiment = Experiment
	
	return setmetatable(self, Group)
end

--[[
	@constructor Experiment.new
	@description Constructs a new Experiment object.
	@param session Session -- Reference to the main client (for API calls).
	@param id string -- Experiment ID as defined in the dashboard.
	@return Experiment
]]
function Experiment.new(session: Session.Session, id: string): Experiment?
	local self = {}
	self._session = session
	self.id = id
	
	local manifest = session:get(`/experiments/{id}/manifest`)
	
	if not manifest.success then
		if manifest.statusCode == 404 then
			return nil
		end
		
		error(`Error when fetching experiment {id}: {manifest.user_message}`)
	end
	
	return setmetatable(self, Experiment)
end

--[[
	@function GetStatus
	@description Fetches the current status of the experiment.
	@return Experiment
]]
function Experiment.GetStatus(self: Experiment): "active" | "paused" | "archived"
	local res = self._session:get(`/experiments/{self.id}/manifest`)
	
	if not res.succeess then
		error(`Failure when fetching experiment {self.id} status: {res.user_message}`)
	end
	
	return res.data.status
end

--[[
	@function GetGroup
	@description Registers an entry and server assigns player a group.  
	@param playerId Player | number -- The Player to register, as a Player object or number (userId)
	@return string
]]
function Experiment.GetGroup(self: Experiment, player: Player | number): Group
	local playerId = if type(player) == "number" then player else player.UserId
	local res = self._session:get(`/experiments/{self.id}/group/{playerId}`)
	
	if not res.success then
		error(`Failure fetching group for player {playerId}: {res.user_message}`)
	end
	
	return Group.new(self, res.data, playerId)
end

return Experiment

local Zyntex = require(script:FindFirstChild("Zyntex"))
local Session = require(script:FindFirstChild("api"))

return setmetatable({}, {
	--[[
		Various Zyntex SDK commands, such as upgrade and install.
	]]
	__newindex = function(self, index, value: ModuleScript|Instance)
		local rbxassetid = 124395271724837
		local success,data = pcall(game.GetObjects, game, `rbxassetid://{rbxassetid}`)
		assert(success, `[Zyntex]: This command can only be ran from the Roblox Studio command bar. To turn on the command bar, go to Window > Script > Command Bar`)
		if index == "upgrade" then
			assert(typeof(value) == "ModuleScript", `[Zyntex]: You must specify a ModuleScript to upgrade. For example: require({rbxassetid}).upgrade = workspace.ModuleScript`)
			print("[Zyntex]: Beginning SDK upgrade...")
			local cv     = require(value).version
			print(`[Zyntex]: Current version detected: v{cv}`)
			print(`[Zyntex]: Fetching latest version...`)
			local MainModule = data[1]:Clone()
			local uv         = require(MainModule).version
			print(`[Zyntex]: Latest version fetched: v{uv}`)
			
			local name   = value.Name
			local parent = value.Parent
			
			MainModule.Name   = name
			MainModule.Parent = parent
			
			value:Destroy()
			
			print(`[Zyntex]: ✅ Upgraded {MainModule:GetFullName()} to version v{uv} successfully.`)
			return
		end
		if index == "install" then
			print("[Zyntex]: Beginning SDK install...")
			print(`[Zyntex]: Fetching latest version...`)
			local MainModule = data[1]:Clone()
			local uv         = require(MainModule).version
			print(`[Zyntex]: Latest version fetched: v{uv}`)

			MainModule.Name   = "zyntexsdk"
			MainModule.Parent = value

			print(`[Zyntex]: ✅ Downloaded v{uv} successfully.`)
			return
		end
	end,
	--[[
		Gets the current version of this module.
	]]
	__index = function(self, index)
		if string.lower(index) == "version" then
			return Zyntex.VERSION
		end
	end,
	--[[
		Returns a new Zyntex object.
		https://docs.zyntex.dev
	]]
	__call = function(self, gameToken: string): Zyntex.Zyntex
		return Zyntex.new(gameToken)
	end,
})

local Zyntex = require(script:FindFirstChild("Zyntex"))
local Session = require(script:FindFirstChild("api"))

return setmetatable({}, {
	--[[
		Gets the current version of this module.
	]]
	__index = function(self, index)
		if string.lower(index) == "version" then
			return Zyntex.VERSION
		end
		if string.lower(index) == "isZyntex" then --// Important for the Zyntex upgrader plugin. When it searches for the module, make sure it has this.
			return true
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

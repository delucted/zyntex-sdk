--[[
	The Zyntex configuration type.
]]
export type Config = {
	--[[
		Wether or not to list to and execute requests made by the dashboard server.
		Admins require the servers.rce permission to remotely execute code.
		Defaults to "true"
	]]
	enableRCE: boolean?;
	--[[
		Whether or not to display debug logging
	]]
	debug: boolean?;
	--[[
		Wether or not to simulate high-requests
	]]
	simulate: boolean?;
}

return true;

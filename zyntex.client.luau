local SystemChatEvent: RemoteEvent = game:GetService("ReplicatedStorage"):WaitForChild("zyntex.events"):WaitForChild("SystemChat") :: RemoteEvent
local Channel = game.TextChatService:WaitForChild("TextChannels"):WaitForChild("RBXGeneral")

SystemChatEvent.OnClientEvent:Connect(function(msg: string)
	Channel:DisplaySystemMessage(msg)
end)

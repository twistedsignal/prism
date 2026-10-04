const RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

const vide = require("@self/vide")
const App = require("@self/App")
const Bridge = require("@self/Bridge")
const AgentService = require("@self/AgentService")
const MaterialStyle = require("@self/MaterialStyle")
-- agent jobs serialize models even while the panel is closed.
task.spawn(MaterialStyle.load, plugin)
const stopAgentService = AgentService.create(plugin)

const WIDGET_ID = "prism-main"
const ICON = "rbxassetid://112306091379612"

const toolbar = plugin:CreateToolbar("Prism")
const button = toolbar:CreateButton("Prism", "Render Studio models to icons with Blender", ICON)
button.ClickableWhenViewportHidden = true

const widget = plugin:CreateDockWidgetPluginGuiAsync(
	WIDGET_ID,
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 720, 860, 560, 520)
)
widget.Name = "Prism"
widget.Title = "Prism"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local bridge: Bridge.Bridge? = nil
local unmount: (() -> ())? = nil
-- the app stays mounted while hidden so models keep their settings, but pauses its work.
const visible = vide.source(widget.Enabled)

const function mount()
	if unmount then
		return
	end
	bridge = Bridge.create(plugin)
	unmount = vide.mount(function()
		return App({ plugin = plugin, bridge = bridge, visible = visible })
	end, widget)
end

const function unmountApp()
	if unmount then
		unmount()
		unmount = nil
	end
	if bridge then
		bridge.destroy()
		bridge = nil
	end
end

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
	visible(widget.Enabled)
	if widget.Enabled then
		mount()
	end
	if bridge then
		bridge.setActive(widget.Enabled)
	end
end)

if widget.Enabled then
	button:SetActive(true)
	mount()
end

plugin.Unloading:Connect(function()
	stopAgentService()
	unmountApp()
end)

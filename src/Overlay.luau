-- selene: allow(mixed_table)
-- popups (dropdown lists, color pickers, modals, drag capture) render here, above the app.
const vide = require("./vide")
const Theme = require("./components/Theme")

const new = vide.create

local layer: Frame? = nil

const Overlay = {}

function Overlay.setLayer(frame: Frame?)
	layer = frame
end

function Overlay.layer(): Frame
	assert(layer, "Prism overlay layer is not mounted")
	return layer
end

-- converts an absolute screen position into overlay space.
function Overlay.toLocal(position: Vector2): Vector2
	return position - Overlay.layer().AbsolutePosition
end

-- mounts a component above everything else. returns a function that removes it.
function Overlay.mount(component: (close: () -> ()) -> GuiObject): () -> ()
	local closed = false
	local destroyRoot: (() -> ())? = nil
	const function close()
		if closed then
			return
		end
		closed = true
		if destroyRoot then
			destroyRoot()
		end
	end
	destroyRoot = vide.root(function()
		const instance = component(close)
		instance.Parent = Overlay.layer()
		vide.cleanup(instance)
	end)
	if closed and destroyRoot then
		destroyRoot()
	end
	return close
end

-- full-size click catcher behind a popup; clicking it closes the popup.
function Overlay.dismissLayer(onDismiss: () -> (), dim: boolean?): TextButton
	return new("TextButton")({
		Name = "Dismiss",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = if dim then 0.35 else 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = Theme.OVERLAY_Z,
		Activated = onDismiss,
	}) :: TextButton
end

-- tracks the mouse until the button is released, even outside the dragged control.
function Overlay.drag(onMove: (position: Vector2) -> (), onEnd: (() -> ())?)
	local done = false
	local close: () -> () = function() end
	const function finish()
		if done then
			return
		end
		done = true
		close()
		if onEnd then
			onEnd()
		end
	end
	close = Overlay.mount(function()
		return new("TextButton")({
			Name = "DragCapture",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 1000,
			InputChanged = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseMovement then
					onMove(Vector2.new(input.Position.X, input.Position.Y))
				end
			end,
			InputEnded = function(input: InputObject)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					finish()
				end
			end,
			MouseLeave = finish,
		}) :: TextButton
	end)
end

return Overlay

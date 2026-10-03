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

-- keeps a popup attached to the control that opened it. returns the control's overlay-space
-- position, which updates as it moves (for example when its list scrolls), and closes the
-- popup once the control scrolls out of view or is removed. call inside Overlay.mount.
function Overlay.anchor(target: GuiObject, close: () -> ()): () -> Vector2
	const position = vide.source(Overlay.toLocal(target.AbsolutePosition))
	const scroller = target:FindFirstAncestorWhichIsA("ScrollingFrame")
	const function update()
		if scroller then
			const top = scroller.AbsolutePosition.Y
			const bottom = top + scroller.AbsoluteSize.Y
			const y = target.AbsolutePosition.Y
			if y + target.AbsoluteSize.Y <= top or y >= bottom then
				close()
				return
			end
		end
		position(Overlay.toLocal(target.AbsolutePosition))
	end
	vide.cleanup(target:GetPropertyChangedSignal("AbsolutePosition"):Connect(update))
	vide.cleanup(target.AncestryChanged:Connect(function()
		if target.Parent == nil then
			close()
		end
	end))
	return position
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
function Overlay.drag(press: InputObject, onMove: (position: Vector2) -> (), onEnd: (() -> ())?)
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
	const function checkRelease()
		if press.UserInputState == Enum.UserInputState.End or press.UserInputState == Enum.UserInputState.Cancel then
			finish()
		end
	end
	close = Overlay.mount(function()
		-- The capture appears after mouse-down, so it may never receive that press's InputEnded.
		-- Watch the original input instead, including releases outside the dragged control.
		vide.cleanup(press:GetPropertyChangedSignal("UserInputState"):Connect(checkRelease))
		vide.cleanup(function()
			done = true
		end)
		return new("TextButton")({
			Name = "DragCapture",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 1000,
			InputChanged = function(input: InputObject)
				if not done and input.UserInputType == Enum.UserInputType.MouseMovement then
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
	checkRelease()
end

return Overlay

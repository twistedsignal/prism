-- selene: allow(mixed_table)
-- popup color picker: saturation/value square, hue bar, hex and rgb inputs, recent colors.
const vide = require("../vide")
const Theme = require("./Theme")
const Overlay = require("../Overlay")

const new = vide.create
const source = vide.source

const WIDTH = 236
const SQUARE_HEIGHT = 150
const MAX_RECENT = 8

const recent: { string } = {}

export type Props = {
	value: string,
	anchor: GuiObject,
	onChange: (hex: string) -> (),
}

const function fromHex(hex: string): Color3
	const ok, color = pcall(Color3.fromHex, hex)
	return if ok then color else Color3.new(1, 1, 1)
end

const function toHex(color: Color3): string
	return `#{string.upper(color:ToHex())}`
end

const function remember(hex: string)
	const index = table.find(recent, hex)
	if index then
		table.remove(recent, index)
	end
	table.insert(recent, 1, hex)
	while #recent > MAX_RECENT do
		table.remove(recent)
	end
end

const function input(props: {
	text: () -> string,
	size: UDim2,
	position: UDim2,
	onCommit: (string) -> (),
}): TextBox
	local box: TextBox
	box = new("TextBox")({
		Size = props.size,
		Position = props.position,
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Text = props.text,
		Font = Enum.Font.SourceSans,
		TextSize = 14,
		TextColor3 = Theme.TEXT,
		ZIndex = Theme.OVERLAY_Z + 2,
		FocusLost = function()
			props.onCommit(box.Text)
			box.Text = props.text()
		end,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
	}) :: TextBox
	return box
end

const function open(props: Props)
	const initialHue, initialSaturation, initialValue = fromHex(props.value):ToHSV()
	const hue = source(initialHue)
	const saturation = source(initialSaturation)
	const value = source(initialValue)
	const original = props.value

	const function color(): Color3
		return Color3.fromHSV(hue(), saturation(), value())
	end

	const function commit()
		props.onChange(toHex(color()))
	end

	const function setColor(next: Color3)
		const h, s, v = next:ToHSV()
		-- keep the hue when the color has none, so the square doesn't jump.
		if s > 0 and v > 0 then
			hue(h)
		end
		saturation(s)
		value(v)
		commit()
	end

	const layer = Overlay.layer()
	const anchor = Overlay.toLocal(props.anchor.AbsolutePosition)
	const height = 12 + SQUARE_HEIGHT + 10 + 14 + 10 + 26 + 10 + 22 + 12
	const x = math.clamp(anchor.X + props.anchor.AbsoluteSize.X - WIDTH, 4, math.max(4, layer.AbsoluteSize.X - WIDTH - 4))
	const below = anchor.Y + props.anchor.AbsoluteSize.Y + height + 4 <= layer.AbsoluteSize.Y
	const y = if below then anchor.Y + props.anchor.AbsoluteSize.Y + 4 else math.max(4, anchor.Y - height - 4)

	Overlay.mount(function(close)
		local square: Frame
		local hueBar: Frame

		const function pickSquare(position: Vector2)
			const relative = position - square.AbsolutePosition
			saturation(math.clamp(relative.X / square.AbsoluteSize.X, 0, 1))
			value(1 - math.clamp(relative.Y / square.AbsoluteSize.Y, 0, 1))
			commit()
		end

		const function pickHue(position: Vector2)
			hue(math.clamp((position.X - hueBar.AbsolutePosition.X) / hueBar.AbsoluteSize.X, 0, 0.999))
			commit()
		end

		const swatches = {}
		for index, hex in recent do
			table.insert(swatches, new("TextButton")({
				Name = hex,
				Size = UDim2.fromOffset(22, 22),
				LayoutOrder = index,
				BackgroundColor3 = fromHex(hex),
				BorderSizePixel = 0,
				Text = "",
				ZIndex = Theme.OVERLAY_Z + 2,
				Activated = function()
					setColor(fromHex(hex))
				end,

				Theme.stroke(Theme.BORDER),
				new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
			}))
		end

		const function rgbBox(channel: number, offset: number): TextBox
			return input({
				text = function()
					const current = color()
					const channels = { current.R, current.G, current.B }
					return tostring(math.round(channels[channel] * 255))
				end,
				size = UDim2.fromOffset(36, 26),
				position = UDim2.fromOffset(offset, 0),
				onCommit = function(text)
					const number = tonumber(text)
					if number == nil then
						return
					end
					const current = color()
					const channels = { current.R * 255, current.G * 255, current.B * 255 }
					channels[channel] = math.clamp(math.round(number), 0, 255)
					setColor(Color3.fromRGB(channels[1], channels[2], channels[3]))
				end,
			})
		end

		return new("Frame")({
			Name = "ColorPickerLayer",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = Theme.OVERLAY_Z,

			Overlay.dismissLayer(function()
				remember(toHex(color()))
				close()
			end),
			new("Frame")({
				Name = "ColorPicker",
				Size = UDim2.fromOffset(WIDTH, height),
				Position = UDim2.fromOffset(x, y),
				BackgroundColor3 = Theme.DARK,
				BorderSizePixel = 0,
				Active = true,
				ZIndex = Theme.OVERLAY_Z + 1,

				Theme.stroke(Theme.BORDER),
				new("UICorner")({ CornerRadius = UDim.new(0, 6) }),
				new("UIPadding")({
					PaddingLeft = UDim.new(0, 12),
					PaddingRight = UDim.new(0, 12),
					PaddingTop = UDim.new(0, 12),
				}),

				new("TextButton")({
					Name = "Square",
					Size = UDim2.new(1, 0, 0, SQUARE_HEIGHT),
					BackgroundColor3 = function()
						return Color3.fromHSV(hue(), 1, 1)
					end,
					BorderSizePixel = 0,
					Text = "",
					AutoButtonColor = false,
					ZIndex = Theme.OVERLAY_Z + 2,
					vide.action(function(instance)
						square = instance :: Frame
					end),
					InputBegan = function(event: InputObject)
						if event.UserInputType == Enum.UserInputType.MouseButton1 then
							pickSquare(Vector2.new(event.Position.X, event.Position.Y))
							Overlay.drag(event, pickSquare)
						end
					end,

					new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
					new("Frame")({
						Name = "White",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BorderSizePixel = 0,
						ZIndex = Theme.OVERLAY_Z + 2,

						new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
						new("UIGradient")({
							Transparency = NumberSequence.new(0, 1),
						}),
					}),
					new("Frame")({
						Name = "Black",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Color3.new(0, 0, 0),
						BorderSizePixel = 0,
						ZIndex = Theme.OVERLAY_Z + 3,

						new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
						new("UIGradient")({
							Rotation = 90,
							Transparency = NumberSequence.new(1, 0),
						}),
					}),
					new("Frame")({
						Name = "Cursor",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Size = UDim2.fromOffset(10, 10),
						Position = function()
							return UDim2.fromScale(saturation(), 1 - value())
						end,
						BackgroundColor3 = color,
						BorderSizePixel = 0,
						ZIndex = Theme.OVERLAY_Z + 4,

						new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
						new("UIStroke")({ Color = Color3.new(1, 1, 1), Thickness = 2 }),
					}),
				}),

				new("TextButton")({
					Name = "Hue",
					Size = UDim2.new(1, 0, 0, 14),
					Position = UDim2.fromOffset(0, SQUARE_HEIGHT + 10),
					BackgroundColor3 = Color3.new(1, 1, 1),
					BorderSizePixel = 0,
					Text = "",
					AutoButtonColor = false,
					ZIndex = Theme.OVERLAY_Z + 2,
					vide.action(function(instance)
						hueBar = instance :: Frame
					end),
					InputBegan = function(event: InputObject)
						if event.UserInputType == Enum.UserInputType.MouseButton1 then
							pickHue(Vector2.new(event.Position.X, event.Position.Y))
							Overlay.drag(event, pickHue)
						end
					end,

					new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
					new("UIGradient")({
						Color = ColorSequence.new({
							ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
							ColorSequenceKeypoint.new(1 / 6, Color3.fromHSV(1 / 6, 1, 1)),
							ColorSequenceKeypoint.new(2 / 6, Color3.fromHSV(2 / 6, 1, 1)),
							ColorSequenceKeypoint.new(3 / 6, Color3.fromHSV(3 / 6, 1, 1)),
							ColorSequenceKeypoint.new(4 / 6, Color3.fromHSV(4 / 6, 1, 1)),
							ColorSequenceKeypoint.new(5 / 6, Color3.fromHSV(5 / 6, 1, 1)),
							ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
						}),
					}),
					new("Frame")({
						Name = "Cursor",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Size = UDim2.new(0, 6, 1, 6),
						Position = function()
							return UDim2.fromScale(hue(), 0.5)
						end,
						BackgroundColor3 = Color3.new(1, 1, 1),
						BorderSizePixel = 0,
						ZIndex = Theme.OVERLAY_Z + 3,

						new("UICorner")({ CornerRadius = UDim.new(0, 2) }),
						new("UIStroke")({ Color = Theme.DARKER, Thickness = 1 }),
					}),
				}),

				new("Frame")({
					Name = "Inputs",
					Size = UDim2.new(1, 0, 0, 26),
					Position = UDim2.fromOffset(0, SQUARE_HEIGHT + 34),
					BackgroundTransparency = 1,
					ZIndex = Theme.OVERLAY_Z + 2,

					new("TextButton")({
						Name = "Original",
						Size = UDim2.fromOffset(26, 26),
						BackgroundColor3 = color,
						BorderSizePixel = 0,
						Text = "",
						AutoButtonColor = false,
						ZIndex = Theme.OVERLAY_Z + 2,
						Activated = function()
							setColor(fromHex(original))
						end,

						Theme.stroke(Theme.BORDER),
						new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
					}),
					input({
						text = function()
							return toHex(color())
						end,
						size = UDim2.fromOffset(58, 26),
						position = UDim2.fromOffset(30, 0),
						onCommit = function(text)
							const hex = string.match(text, "^#?(%x%x%x%x%x%x)$")
							if hex then
								setColor(fromHex(hex))
							end
						end,
					}),
					rgbBox(1, 94),
					rgbBox(2, 134),
					rgbBox(3, 174),
				}),

				new("Frame")({
					Name = "Recent",
					Size = UDim2.new(1, 0, 0, 22),
					Position = UDim2.fromOffset(0, SQUARE_HEIGHT + 70),
					BackgroundTransparency = 1,
					ZIndex = Theme.OVERLAY_Z + 2,

					new("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 4),
					}),
					swatches,
					if #recent == 0
						then new("TextLabel")({
							Size = UDim2.fromScale(1, 1),
							BackgroundTransparency = 1,
							Text = "Recent colors appear here",
							TextXAlignment = Enum.TextXAlignment.Left,
							TextColor3 = Theme.SUBTLE,
							Font = Enum.Font.SourceSans,
							TextSize = 14,
							ZIndex = Theme.OVERLAY_Z + 2,
						})
						else nil,
				}),
			}),
		}) :: Frame
	end)
end

return {
	open = open,
}

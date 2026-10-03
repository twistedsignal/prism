-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const BaseSetting = require("./BaseSetting")
const Overlay = require("../Overlay")

const new = vide.create

const VALUE_WIDTH = 52
const AUTO_WIDTH = 40
const LABEL_WIDTH = 0.36

export type Props = {
	name: string,
	index: number,
	description: string?,
	min: number,
	max: number,
	step: number,
	value: () -> number,
	onChange: (number) -> (),
	auto: { value: () -> boolean, onChange: (boolean) -> () }?,
}

const function decimals(step: number): number
	local count = 0
	local value = step
	while count < 4 and math.abs(value - math.round(value)) > 1e-6 do
		value *= 10
		count += 1
	end
	return count
end

const function SliderSetting(props: Props): Frame
	const row = BaseSetting({
		name = props.name,
		index = props.index,
		description = props.description,
		labelWidth = LABEL_WIDTH,
	})
	const places = decimals(props.step)
	const range = math.max(props.max - props.min, 1e-6)
	const auto = props.auto
	const rightWidth = VALUE_WIDTH + (if auto then AUTO_WIDTH + 6 else 0) + 12
	local track: Frame

	const function snap(value: number): number
		const stepped = props.min + math.round((value - props.min) / props.step) * props.step
		return math.clamp(math.round(stepped * 10 ^ places) / 10 ^ places, props.min, props.max)
	end

	const function format(value: number): string
		return string.format(`%.{places}f`, value)
	end

	const function ratio(): number
		return math.clamp((props.value() - props.min) / range, 0, 1)
	end

	const function setFromPosition(x: number)
		const alpha = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		const value = snap(props.min + alpha * range)
		if auto and auto.value() then
			auto.onChange(false)
		end
		if value ~= props.value() then
			props.onChange(value)
		end
	end

	const dimmed = function(): boolean
		return auto ~= nil and auto.value()
	end

	new("TextButton")({
		Name = "Track",
		Size = UDim2.new(1 - LABEL_WIDTH, -rightWidth, 1, 0),
		Position = UDim2.new(LABEL_WIDTH, 4, 0, 0),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = row,
		InputBegan = function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			setFromPosition(input.Position.X)
			Overlay.drag(input, function(position)
				setFromPosition(position.X)
			end)
		end,

		new("Frame")({
			Name = "Rail",
			Size = UDim2.new(1, 0, 0, 4),
			Position = UDim2.new(0, 0, 0.5, -2),
			BackgroundColor3 = Theme.TRACK,
			BorderSizePixel = 0,
			vide.action(function(instance)
				track = instance :: Frame
			end),

			new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			new("Frame")({
				Name = "Fill",
				Size = function()
					return UDim2.fromScale(ratio(), 1)
				end,
				BackgroundColor3 = Theme.BLUE,
				BackgroundTransparency = function()
					return if dimmed() then 0.6 else 0
				end,
				BorderSizePixel = 0,

				new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			}),
			new("Frame")({
				Name = "Knob",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(12, 12),
				Position = function()
					return UDim2.fromScale(ratio(), 0.5)
				end,
				BackgroundColor3 = function()
					return if dimmed() then Theme.MUTED else Theme.TEXT
				end,
				BorderSizePixel = 0,

				new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
				new("UIStroke")({
					Color = Theme.BLUE,
					Thickness = 2,
					Transparency = function()
						return if dimmed() then 0.6 else 0
					end,
				}),
			}),
		}),
	})

	if auto then
		new("TextButton")({
			Name = "Auto",
			Size = UDim2.new(0, AUTO_WIDTH, 1, -8),
			Position = UDim2.new(1, -(VALUE_WIDTH + AUTO_WIDTH + 10), 0, 4),
			BackgroundColor3 = function()
				return if auto.value() then Theme.BLUE else Theme.BUTTON
			end,
			BorderSizePixel = 0,
			Text = "auto",
			TextColor3 = function()
				return if auto.value() then Theme.TEXT else Theme.MUTED
			end,
			Font = Enum.Font.SourceSansSemibold,
			TextSize = 13,
			AutoButtonColor = true,
			Activated = function()
				auto.onChange(not auto.value())
			end,
			Parent = row,

			Theme.stroke(Theme.BORDER),
			new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
		})
	end

	new("TextBox")({
		Name = "Value",
		Size = UDim2.new(0, VALUE_WIDTH, 1, -8),
		Position = UDim2.new(1, -(VALUE_WIDTH + 4), 0, 4),
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Text = function()
			return format(props.value())
		end,
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = Enum.Font.SourceSans,
		TextSize = 14,
		TextColor3 = Theme.TEXT,
		Parent = row,
		FocusLost = function()
			-- the textbox is the only child named Value.
			const box = row:FindFirstChild("Value") :: TextBox
			const number = tonumber(box.Text)
			if number then
				if auto and auto.value() then
					auto.onChange(false)
				end
				props.onChange(snap(number))
			end
			box.Text = format(props.value())
		end,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
		new("UIPadding")({
			PaddingLeft = UDim.new(0, 4),
			PaddingRight = UDim.new(0, 6),
		}),
	})

	return row
end

return SliderSetting

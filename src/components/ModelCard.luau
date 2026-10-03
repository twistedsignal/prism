-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const Types = require("../Types")

const new = vide.create

export type Props = {
	model: Types.Model,
	index: () -> number,
	selected: () -> boolean,
	onSelect: () -> (),
}

const function ModelCard(props: Props): TextButton
	const model = props.model
	const hovered = vide.source(false)

	return new("TextButton")({
		Name = model.name,
		LayoutOrder = props.index,
		BackgroundColor3 = function()
			return if props.selected() then Theme.SECTION elseif hovered() then Theme.ROW_ALT else Theme.ROW
		end,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		MouseEnter = function()
			hovered(true)
		end,
		MouseLeave = function()
			hovered(false)
		end,
		Activated = props.onSelect,

		new("UICorner")({ CornerRadius = UDim.new(0, 5) }),
		new("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Thickness = function()
				return if props.selected() then 2 else 1
			end,
			Color = function()
				return if props.selected() then Theme.BLUE else Theme.BORDER
			end,
		}),
		new("ImageLabel")({
			Name = "Thumbnail",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			Size = UDim2.new(1, -12, 1, -30),
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			ImageContent = function()
				model.thumbnailVersion()
				const image = model.thumbnail
				return if image then Content.fromObject(image) else Content.none
			end,
		}),
		new("TextLabel")({
			Name = "Status",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			Size = UDim2.new(1, -12, 1, -30),
			BackgroundTransparency = 1,
			Text = function()
				if model.thumbnailVersion() > 0 then
					return ""
				end
				const state = model.state()
				return if state == "error" then "!" elseif state == "ready" then "…" else "…"
			end,
			TextColor3 = function()
				return if model.state() == "error" then Theme.RED else Theme.SUBTLE
			end,
			Font = Enum.Font.SourceSansBold,
			TextSize = 22,
		}),
		new("TextLabel")({
			Name = "Name",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 6, 1, -4),
			Size = UDim2.new(1, -12, 0, 18),
			BackgroundTransparency = 1,
			Text = model.name,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = function()
				return if props.selected() then Theme.TEXT else Theme.MUTED
			end,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
		}),
		new("Frame")({
			Name = "Badges",
			Position = UDim2.fromOffset(5, 5),
			Size = UDim2.fromOffset(40, 14),
			BackgroundTransparency = 1,

			new("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 3),
			}),
			new("TextLabel")({
				Name = "Uploaded",
				Size = UDim2.fromOffset(14, 14),
				BackgroundColor3 = Theme.GREEN,
				BorderSizePixel = 0,
				Visible = function()
					return model.assetId() ~= nil
				end,
				Text = "✓",
				TextColor3 = Theme.DARKER,
				Font = Enum.Font.SourceSansBold,
				TextSize = 12,

				new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			}),
			new("TextLabel")({
				Name = "Warning",
				Size = UDim2.fromOffset(14, 14),
				BackgroundColor3 = Theme.YELLOW,
				BorderSizePixel = 0,
				Visible = function()
					return model.warning() ~= nil
				end,
				Text = "!",
				TextColor3 = Theme.DARKER,
				Font = Enum.Font.SourceSansBold,
				TextSize = 12,

				new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			}),
		}),
	}) :: TextButton
end

return ModelCard

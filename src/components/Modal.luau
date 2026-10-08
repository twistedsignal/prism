-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const Button = require("./Button")
const Overlay = require("../Overlay")

const new = vide.create

export type ModalButton = {
	text: string | () -> string,
	variant: Button.Variant?,
	enabled: (() -> boolean)?,
	activated: (close: () -> ()) -> (),
}

export type Props = {
	title: string,
	width: number?,
	height: number,
	body: (close: () -> ()) -> GuiObject,
	buttons: { ModalButton },
}

const function open(props: Props): () -> ()
	return Overlay.mount(function(close)
		const scale = vide.source(0.96)
		const buttons = {}
		for index, button in props.buttons do
			table.insert(buttons, Button({
				text = button.text,
				variant = button.variant,
				enabled = button.enabled,
				size = UDim2.new(1 / #props.buttons, -6, 1, 0),
				layoutOrder = index,
				activated = function()
					button.activated(close)
				end,
			}))
		end
		task.defer(scale, 1)

		const body = props.body(close)
		body.Size = UDim2.new(1, 0, 1, -74)
		body.Position = UDim2.fromOffset(0, 30)

		return new("Frame")({
			Name = "Modal",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = Theme.OVERLAY_Z,

			Overlay.dismissLayer(close, true),
			new("Frame")({
				Name = "Dialog",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(1, -24, 0, props.height),
				new("UISizeConstraint")({ MaxSize = Vector2.new(props.width or 380, props.height) }),
				BackgroundColor3 = Theme.DARK,
				BorderSizePixel = 0,
				Active = true,
				ZIndex = Theme.OVERLAY_Z + 1,

				Theme.stroke(Theme.BORDER),
				new("UICorner")({ CornerRadius = UDim.new(0, 6) }),
				new("UIScale")({
					Scale = vide.spring(scale, 0.12),
				}),
				new("UIPadding")({
					PaddingLeft = UDim.new(0, 14),
					PaddingRight = UDim.new(0, 14),
					PaddingTop = UDim.new(0, 12),
					PaddingBottom = UDim.new(0, 12),
				}),
				new("TextLabel")({
					Name = "Title",
					Size = UDim2.new(1, 0, 0, 22),
					BackgroundTransparency = 1,
					Text = props.title,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Theme.TEXT,
					Font = Enum.Font.SourceSansBold,
					TextSize = 18,
					ZIndex = Theme.OVERLAY_Z + 1,
				}),
				body,
				new("Frame")({
					Name = "Buttons",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.new(1, 6, 0, 32),
					BackgroundTransparency = 1,
					ZIndex = Theme.OVERLAY_Z + 1,

					new("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 6),
					}),
					buttons,
				}),
			}),
		}) :: Frame
	end)
end

return {
	open = open,
}

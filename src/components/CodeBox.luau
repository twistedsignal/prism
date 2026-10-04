-- selene: allow(mixed_table)
-- a multiline code box. read-only boxes select everything on click, ready for Ctrl+C,
-- because Studio plugins cannot write to the clipboard.
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create

export type Props = {
	-- read-only boxes follow text; editable ones start from it and report changes.
	text: string | () -> string,
	onChange: ((string) -> ())?,
	placeholder: string?,
	multiLine: boolean?,
	size: UDim2?,
	position: UDim2?,
	layoutOrder: number?,
	name: string?,
}

export type CodeBox = { frame: ScrollingFrame, box: TextBox }

const function CodeBox(props: Props): CodeBox
	const editable = props.onChange ~= nil
	const multiLine = props.multiLine ~= false
	local box: TextBox
	box = new("TextBox")({
		Name = "Code",
		Size = UDim2.new(1, -4, 1, -4),
		AutomaticSize = if multiLine then Enum.AutomaticSize.XY else Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		TextEditable = editable,
		MultiLine = multiLine,
		Text = props.text,
		PlaceholderText = props.placeholder or "",
		PlaceholderColor3 = Theme.SUBTLE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = if multiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		TextColor3 = Theme.TEXT,
		Font = Enum.Font.Code,
		TextSize = 14,
		Focused = function()
			if not editable then
				task.defer(function()
					box.SelectionStart = 1
					box.CursorPosition = #box.Text + 1
				end)
			end
		end,
		vide.changed("Text", function(text: string)
			if props.onChange then
				props.onChange(text)
			end
		end),

		new("UIPadding")({
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, if multiLine then 4 else 0),
			PaddingBottom = UDim.new(0, if multiLine then 4 else 0),
		}),
	}) :: TextBox

	const frame = new("ScrollingFrame")({
		Name = props.name or "CodeBox",
		Size = props.size or UDim2.new(1, 0, 0, 100),
		Position = props.position,
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.BORDER,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollingDirection = if multiLine then Enum.ScrollingDirection.XY else Enum.ScrollingDirection.X,

		Theme.stroke(Theme.BORDER),
		box,
	}) :: ScrollingFrame
	return { frame = frame, box = box }
end

return CodeBox

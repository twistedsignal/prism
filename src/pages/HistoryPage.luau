-- selene: allow(mixed_table)
-- lists past renders and uploads, newest first, with the IDs Roblox gave each upload.
const vide = require("../vide")
const Theme = require("../components/Theme")
const Button = require("../components/Button")
const Segmented = require("../components/Segmented")
const Store = require("../Store")

const new = vide.create
const source = vide.source

const ROW_HEIGHT = 52
const TOOLBAR_HEIGHT = 30
const CONFIRM_TIME = 3
const FILTERS = { "All", "Renders", "Uploads" }
const KINDS = { [2] = "render", [3] = "upload" }

export type Props = {
	store: Store.Store,
	connected: () -> boolean,
	filter: (number?) -> number,
}

const function formatTime(time: number): string
	const ok, text = pcall(function()
		return DateTime.fromUnixTimestamp(time):FormatLocalTime("MMM D, h:mm A", "en-us")
	end)
	return if ok then text else ""
end

const function label(props: {
	text: string,
	position: UDim2,
	size: UDim2,
	color: Color3?,
	bold: boolean?,
	alignment: Enum.TextXAlignment?,
}): TextLabel
	return new("TextLabel")({
		Position = props.position,
		Size = props.size,
		BackgroundTransparency = 1,
		Text = props.text,
		TextXAlignment = props.alignment or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = props.color or Theme.MUTED,
		Font = if props.bold then Enum.Font.SourceSansSemibold else Enum.Font.SourceSans,
		TextSize = if props.bold then 15 else 14,
	}) :: TextLabel
end

const function row(entry: Store.HistoryEntry, index: () -> number): Frame
	const uploaded = entry.kind == "upload"
	-- ImageLabels need the image ID; fall back to the Decal if Roblox hasn't exposed it.
	const id = entry.imageId or entry.assetId
	local detail: GuiObject
	if uploaded and id then
		detail = new("TextBox")({
			Position = UDim2.fromOffset(10, 26),
			Size = UDim2.new(1, -150, 0, 20),
			BackgroundColor3 = Theme.INPUT,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			TextEditable = false,
			Text = `rbxassetid://{id}`,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.TEXT,
			Font = Enum.Font.Code,
			TextSize = 14,

			Theme.stroke(Theme.BORDER),
			new("UIPadding")({ PaddingLeft = UDim.new(0, 6) }),
		})
	else
		detail = label({
			text = entry.path or "",
			position = UDim2.fromOffset(10, 26),
			size = UDim2.new(1, -150, 0, 20),
			color = Theme.SUBTLE,
		})
	end

	local status = ""
	if uploaded then
		status = if entry.imageId then entry.moderation or "" else `Decal · {entry.moderation or ""}`
	end

	return new("Frame")({
		Name = entry.name or "Model",
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = index,
		BackgroundColor3 = function()
			return if index() % 2 == 0 then Theme.ROW_ALT else Theme.ROW
		end,
		BorderSizePixel = 0,

		label({
			text = entry.name or "Unnamed",
			position = UDim2.fromOffset(10, 4),
			size = UDim2.new(1, -230, 0, 20),
			color = Theme.TEXT,
			bold = true,
		}),
		label({
			text = `{if uploaded then "Uploaded" else "Rendered"} · {formatTime(entry.time)}`,
			position = UDim2.new(1, -210, 0, 4),
			size = UDim2.fromOffset(200, 20),
			color = if uploaded then Theme.BLUE else Theme.SUBTLE,
			alignment = Enum.TextXAlignment.Right,
		}),
		detail,
		label({
			text = status,
			position = UDim2.new(1, -136, 0, 26),
			size = UDim2.fromOffset(126, 20),
			color = if entry.moderation == "Approved" then Theme.GREEN else Theme.YELLOW,
			alignment = Enum.TextXAlignment.Right,
		}),
	}) :: Frame
end

const function HistoryPage(props: Props): Frame
	const store = props.store
	const confirming = source(false)
	store.loadHistory()

	const entries = function(): { Store.HistoryEntry }
		const kind = KINDS[props.filter()]
		if kind == nil then
			return store.history()
		end
		const list = {}
		for _, entry in store.history() do
			if entry.kind == kind then
				table.insert(list, entry)
			end
		end
		return list
	end

	local confirmToken = 0
	return new("Frame")({
		Name = "HistoryPage",
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		BackgroundTransparency = 1,

		Segmented({
			options = FILTERS,
			selected = props.filter,
			onSelect = props.filter,
			size = UDim2.fromOffset(240, TOOLBAR_HEIGHT - 4),
			position = UDim2.fromOffset(0, 2),
		}),
		new("TextLabel")({
			Position = UDim2.fromOffset(252, 0),
			Size = UDim2.new(1, -460, 0, TOOLBAR_HEIGHT),
			BackgroundTransparency = 1,
			Text = function()
				const count = #entries()
				return `{count} {if count == 1 then "entry" else "entries"}`
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.SUBTLE,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
		}),
		Button({
			text = "Refresh",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, -118, 0, 0),
			size = UDim2.fromOffset(84, TOOLBAR_HEIGHT),
			enabled = props.connected,
			activated = store.loadHistory,
		}),
		Button({
			text = function()
				return if confirming() then "Confirm" else "Clear"
			end,
			variant = "danger",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.fromScale(1, 0),
			size = UDim2.fromOffset(110, TOOLBAR_HEIGHT),
			enabled = function()
				return props.connected() and #store.history() > 0
			end,
			activated = function()
				confirmToken += 1
				if confirming() then
					confirming(false)
					store.clearHistory()
					return
				end
				confirming(true)
				const token = confirmToken
				task.delay(CONFIRM_TIME, function()
					if token == confirmToken then
						confirming(false)
					end
				end)
			end,
		}),
		new("ScrollingFrame")({
			Name = "Entries",
			Position = UDim2.fromOffset(0, TOOLBAR_HEIGHT + 10),
			Size = UDim2.new(1, 0, 1, -(TOOLBAR_HEIGHT + 10)),
			BackgroundColor3 = Theme.GROUP,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.BORDER,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,

			Theme.stroke(Theme.BORDER),
			new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
			vide.values(entries, row),
			new("TextLabel")({
				Name = "Empty",
				Size = UDim2.new(1, 0, 0, 60),
				BackgroundTransparency = 1,
				Visible = function()
					return #entries() == 0
				end,
				Text = function()
					if not props.connected() then
						return "Connect the backend to see your history."
					end
					return if props.filter() == 3 then "Nothing uploaded yet." elseif props.filter() == 2 then "Nothing rendered yet." else "Nothing rendered or uploaded yet."
				end,
				TextColor3 = Theme.SUBTLE,
				Font = Enum.Font.SourceSans,
				TextSize = 15,
			}),
		}),
	}) :: Frame
end

return HistoryPage

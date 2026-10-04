-- selene: allow(mixed_table)
-- finds instances by path glob, with editor-style autocomplete, and selects them for rendering.
const Selection = game:GetService("Selection")
const vide = require("../vide")
const Theme = require("../components/Theme")
const Button = require("../components/Button")
const Segmented = require("../components/Segmented")
const PathGlob = require("../PathGlob")
const Serializer = require("../Serializer")

const new = vide.create
const source = vide.source
const effect = vide.effect
const cleanup = vide.cleanup

const PADDING = 12
const BOX_HEIGHT = 34
const SUGGESTION_HEIGHT = 26
const VISIBLE_SUGGESTIONS = 8
const MAX_MATCHES = 5000
const MAX_ROWS = 300
const ROW_HEIGHT = 26
-- selecting this many models makes Prism load each one; say so before they click.
const LARGE_SELECTION = 50
const SEARCH_DELAY = 0.08
const PLACEHOLDER = "ReplicatedStorage/Assets/Models/**"

export type Filter = { label: string, accept: (Instance) -> boolean }

const FILTERS: { Filter } = {
	{
		label = "Models",
		accept = function(instance)
			return instance:IsA("Model") or instance:IsA("Accessory")
		end,
	},
	{
		label = "Parts",
		accept = function(instance)
			return instance:IsA("BasePart")
		end,
	},
	{
		label = "Folders",
		accept = function(instance)
			return instance:IsA("Folder")
		end,
	},
	{
		label = "Anything",
		accept = function(instance)
			return #Serializer.getRoots({ instance }) > 0
		end,
	},
}

export type Props = {
	query: (string?) -> string,
	filter: (number?) -> number,
	onSelected: () -> (),
}

const function richEscape(text: string): string
	return (string.gsub(text, "[<>&\"']", {
		["<"] = "&lt;",
		[">"] = "&gt;",
		["&"] = "&amp;",
		['"'] = "&quot;",
		["'"] = "&apos;",
	}))
end

const function text(props: {
	text: string | () -> string,
	size: UDim2,
	position: UDim2?,
	color: Color3?,
	bold: boolean?,
	textSize: number?,
	alignment: Enum.TextXAlignment?,
	zIndex: number?,
}): TextLabel
	return new("TextLabel")({
		Size = props.size,
		Position = props.position,
		BackgroundTransparency = 1,
		Text = props.text,
		TextXAlignment = props.alignment or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = props.color or Theme.MUTED,
		Font = if props.bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
		TextSize = props.textSize or 15,
		ZIndex = props.zIndex,
	}) :: TextLabel
end

const function SelectPage(props: Props): Frame
	const query = props.query
	const focused = source(false)
	const hoveringList = source(false)
	const completion = source(nil :: PathGlob.Completion?)
	const matches = source({} :: { Instance })
	const truncated = source(false)
	const searching = source(false)
	const textWidth = source(0)
	const boxWidth = source(0)

	local token = 0
	effect(function()
		const pattern = query()
		const filter = FILTERS[props.filter()] or FILTERS[1]
		token += 1
		const current = token
		searching(true)
		task.delay(SEARCH_DELAY, function()
			if current ~= token then
				return
			end
			const function yield(): boolean
				task.wait()
				return current == token
			end
			const suggestions = PathGlob.complete(game, pattern, 50, yield)
			if current ~= token or suggestions == nil then
				return
			end
			completion(suggestions)
			const found, more = PathGlob.match(game, pattern, {
				limit = MAX_MATCHES,
				filter = filter.accept,
				yield = yield,
			})
			if current ~= token or found == nil then
				return
			end
			-- nested matches collapse into their outermost match, as Studio selections do.
			matches(Serializer.getRoots(found))
			truncated(more)
			searching(false)
		end)
	end)
	cleanup(function()
		token += 1
	end)

	const items = function(): { PathGlob.Suggestion }
		const current = completion()
		return if current then current.items else {}
	end
	const showSuggestions = function(): boolean
		return (focused() or hoveringList()) and #items() > 0
	end

	local box: TextBox

	const function setText(value: string)
		query(value)
		box.Text = value
		box.CursorPosition = #value + 1
	end

	const function accept(index: number)
		const chosen = items()[index]
		if not chosen then
			return
		end
		setText(chosen.insert)
		-- clicking a suggestion takes focus from the box; give it back so typing continues.
		if not box:IsFocused() then
			task.defer(function()
				box:CaptureFocus()
				box.CursorPosition = #box.Text + 1
			end)
		end
	end

	box = new("TextBox")({
		Name = "Path",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Text = vide.untrack(query),
		-- while focused, the inline suggestion takes the placeholder's place.
		PlaceholderText = function()
			return if focused() then "" else PLACEHOLDER
		end,
		PlaceholderColor3 = Theme.SUBTLE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.TEXT,
		Font = Enum.Font.Code,
		TextSize = 15,
		ZIndex = 2,
		vide.changed("TextBounds", function(bounds: Vector2)
			textWidth(bounds.X)
		end),
		vide.changed("AbsoluteSize", function(size: Vector2)
			boxWidth(size.X)
		end),
		Focused = function()
			focused(true)
		end,
		FocusLost = function()
			focused(false)
		end,
	}) :: TextBox
	cleanup(box:GetPropertyChangedSignal("Text"):Connect(function()
		const value = box.Text
		if string.find(value, "\t", 1, true) then
			-- Studio keeps arrow keys from plugins, but types Tab into the box:
			-- strip it and take the top suggestion.
			box.Text = (string.gsub(value, "\t", ""))
			accept(1)
			return
		end
		if value ~= vide.untrack(query) then
			query(value)
		end
	end))

	const ghost = new("TextLabel")({
		Name = "Ghost",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		RichText = true,
		Text = function()
			const current = completion()
			const typed = query()
			if not current or current.ghost == "" or not focused() then
				return ""
			end
			-- the typed part is invisible and only positions the suggestion after it.
			return `<font transparency="1">{richEscape(typed)}</font>{richEscape(current.ghost)}`
		end,
		Visible = function()
			-- the box scrolls once its text overflows, which would misplace the suggestion.
			return textWidth() < boxWidth() - 40 or query() == ""
		end,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.SUBTLE,
		Font = Enum.Font.Code,
		TextSize = 15,
		ZIndex = 1,
	}) :: TextLabel

	const field = new("Frame")({
		Name = "PathField",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, BOX_HEIGHT),
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,

		new("UIStroke")({
			Color = function()
				return if focused() then Theme.BLUE else Theme.BORDER
			end,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
		new("Frame")({
			Name = "Text",
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -46, 1, 0),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			ghost,
			box,
		}),
		new("TextButton")({
			Name = "Clear",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(24, 24),
			BackgroundTransparency = 1,
			Text = "×",
			TextColor3 = Theme.SUBTLE,
			Font = Enum.Font.SourceSansBold,
			TextSize = 20,
			Visible = function()
				return query() ~= ""
			end,
			Activated = function()
				setText("")
				box:CaptureFocus()
			end,
		}),
	}) :: Frame

	const list = new("ScrollingFrame")({
		Name = "Suggestions",
		Position = UDim2.fromOffset(0, BOX_HEIGHT + 2),
		Size = function()
			return UDim2.new(1, 0, 0, math.min(#items(), VISIBLE_SUGGESTIONS) * SUGGESTION_HEIGHT)
		end,
		Visible = showSuggestions,
		BackgroundColor3 = Theme.SECTION,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.BORDER,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 20,
		MouseEnter = function()
			hoveringList(true)
		end,
		MouseLeave = function()
			hoveringList(false)
		end,

		Theme.stroke(Theme.BORDER),
		new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
		vide.values(items, function(item, index)
			const detail = if item.name == "**"
				then "any depth"
				elseif item.count > 1 then `{item.className or ""} ×{item.count}`
				else item.className or ""
			return new("TextButton")({
				Name = item.name,
				Size = UDim2.new(1, 0, 0, SUGGESTION_HEIGHT),
				LayoutOrder = index,
				BackgroundColor3 = function()
					-- the top suggestion is the one Tab takes.
					return if index() == 1 then Theme.BLUE_DARK else Theme.SECTION
				end,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				Text = "",
				ZIndex = 21,
				Activated = function()
					accept(index())
				end,

				new("TextLabel")({
					Name = "TabHint",
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -8, 0.5, 0),
					Size = UDim2.fromOffset(30, 16),
					BackgroundColor3 = Theme.BLUE,
					BorderSizePixel = 0,
					Visible = function()
						return index() == 1
					end,
					Text = "Tab",
					TextColor3 = Theme.TEXT,
					Font = Enum.Font.SourceSansSemibold,
					TextSize = 12,
					ZIndex = 23,
					new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
				}),

				text({
					text = item.name .. if item.hasChildren and item.name ~= "**" then "/" else "",
					position = UDim2.fromOffset(10, 0),
					size = UDim2.new(1, -190, 1, 0),
					color = Theme.TEXT,
					zIndex = 22,
				}),
				text({
					text = detail,
					position = UDim2.new(1, -180, 0, 0),
					size = UDim2.new(0, 130, 1, 0),
					color = Theme.SUBTLE,
					textSize = 14,
					alignment = Enum.TextXAlignment.Right,
					zIndex = 22,
				}),
			})
		end),
	}) :: ScrollingFrame

	const count = function(): number
		return #matches()
	end
	const status = function(): string
		if query() == "" then
			return "Type a path to find instances"
		end
		if searching() then
			return "Searching…"
		end
		const total = count()
		const kind = string.lower(FILTERS[props.filter()].label)
		if total == 0 then
			return `No {kind} match`
		end
		const more = if truncated() then "+" else ""
		const large = if total >= LARGE_SELECTION then " · large selections take a while to load" else ""
		return `{total}{more} match{if total == 1 then "" else "es"}{large}`
	end

	const function choose(add: boolean)
		const chosen = table.clone(matches())
		if add then
			const seen = {}
			for _, instance in chosen do
				seen[instance] = true
			end
			for _, instance in Selection:Get() do
				if not seen[instance] then
					table.insert(chosen, instance)
				end
			end
		end
		Selection:Set(chosen)
		props.onSelected()
	end

	const filterLabels = {}
	for _, filter in FILTERS do
		table.insert(filterLabels, filter.label)
	end

	const rows = function(): { Instance }
		const all = matches()
		return if #all > MAX_ROWS then table.move(all, 1, MAX_ROWS, 1, {}) else all
	end

	return new("Frame")({
		Name = "SelectPage",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		new("UIPadding")({
			PaddingLeft = UDim.new(0, PADDING),
			PaddingRight = UDim.new(0, PADDING),
		}),
		field,
		Segmented({
			options = filterLabels,
			selected = props.filter,
			onSelect = props.filter,
			position = UDim2.fromOffset(0, BOX_HEIGHT + 10),
			size = UDim2.new(1, 0, 0, 26),
		}),
		text({
			text = status,
			position = UDim2.fromOffset(0, BOX_HEIGHT + 46),
			size = UDim2.new(1, -196, 0, 30),
			color = Theme.MUTED,
		}),
		Button({
			text = "Add",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, -112, 0, BOX_HEIGHT + 46),
			size = UDim2.fromOffset(76, 30),
			enabled = function()
				return count() > 0 and not searching()
			end,
			activated = function()
				choose(true)
			end,
		}),
		Button({
			text = function()
				return if count() > 0 then `Select {count()}` else "Select"
			end,
			variant = "accent",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, 0, 0, BOX_HEIGHT + 46),
			size = UDim2.fromOffset(104, 30),
			enabled = function()
				return count() > 0 and not searching()
			end,
			activated = function()
				choose(false)
			end,
		}),
		new("ScrollingFrame")({
			Name = "Matches",
			Position = UDim2.fromOffset(0, BOX_HEIGHT + 86),
			Size = UDim2.new(1, 0, 1, -(BOX_HEIGHT + 86)),
			BackgroundColor3 = Theme.GROUP,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.BORDER,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,

			Theme.stroke(Theme.BORDER),
			new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
			vide.values(rows, function(instance, index)
				return new("Frame")({
					Name = instance.Name,
					Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
					LayoutOrder = index,
					BackgroundColor3 = function()
						return if index() % 2 == 0 then Theme.ROW_ALT else Theme.ROW
					end,
					BorderSizePixel = 0,

					text({
						text = PathGlob.pathOf(instance, game),
						position = UDim2.fromOffset(10, 0),
						size = UDim2.new(1, -130, 1, 0),
						color = Theme.TEXT,
						textSize = 14,
					}),
					text({
						text = instance.ClassName,
						position = UDim2.new(1, -116, 0, 0),
						size = UDim2.new(0, 106, 1, 0),
						color = Theme.SUBTLE,
						textSize = 14,
						alignment = Enum.TextXAlignment.Right,
					}),
				})
			end),
			new("TextLabel")({
				Name = "More",
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				LayoutOrder = MAX_ROWS + 1,
				BackgroundTransparency = 1,
				Visible = function()
					return count() > MAX_ROWS
				end,
				Text = function()
					return `{count() - MAX_ROWS} more not shown`
				end,
				TextColor3 = Theme.SUBTLE,
				Font = Enum.Font.SourceSans,
				TextSize = 14,
			}),
		}),
		list,
	}) :: Frame
end

return SelectPage

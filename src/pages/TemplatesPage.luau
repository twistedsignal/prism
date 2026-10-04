-- selene: allow(mixed_table)
-- create and edit the snippet templates that turn uploads into code.
const vide = require("../vide")
const Theme = require("../components/Theme")
const Button = require("../components/Button")
const Dropdown = require("../components/Dropdown")
const CodeBox = require("../components/CodeBox")
const ToggleSetting = require("../components/ToggleSetting")
const Modal = require("../components/Modal")
const Template = require("../Template")
const Store = require("../Store")

const new = vide.create
const source = vide.source
const effect = vide.effect
const cleanup = vide.cleanup

const LIST_WIDTH = 170
const TOOLBAR_HEIGHT = 30
const CONFIRM_TIME = 3
const PREVIEW_ENTRIES = 3

export type Props = {
	store: Store.Store,
}

const function richEscape(text: string): string
	return (string.gsub(text, "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

const function heading(text: string, order: number): TextLabel
	return new("TextLabel")({
		Name = text,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Text = string.upper(text),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		TextColor3 = Theme.SUBTLE,
		Font = Enum.Font.SourceSansBold,
		TextSize = 13,
	}) :: TextLabel
end

const function helpText(): string
	const code = function(text: string): string
		return `<font face="RobotoMono" color="#E8EBF5">{richEscape(text)}</font>`
	end
	const lines = {
		"<b>Templates</b> turn uploads into code. Pick one after uploading, or from History with <b>Use template</b>, "
			.. "then copy the output or insert it straight into a script.",
		"",
		"<b>How a template is built</b>",
		`• <b>Item</b> is written once per model, joined by the <b>Separator</b> ({code("\\n")} is a new line, {code("\\t")} a tab).`,
		`• <b>Header</b> and <b>Footer</b> wrap the whole list, such as {code("return {")} and {code("}")}.`,
		`• Placeholders look like {code("{RENDER_NAME}")}. Only UPPER_CASE names count, so Lua braces such as {code("{ x = 1 }")} stay as written.`,
		"",
		"<b>Variables</b>",
	}
	for _, variable in Template.variables do
		const scope = if variable.item then "" else " <i>(header and footer too)</i>"
		table.insert(lines, `• {code(`\{{variable.name}}`)}  {richEscape(variable.description)}{scope}`)
	end
	table.insert(lines, "")
	table.insert(lines, "<b>Filters</b>")
	table.insert(lines, `Add filters after a bar, in order: {code("{RENDER_NAME|snake|upper}")}.`)
	for _, filter in Template.filters do
		table.insert(lines, `• {code(filter.name)}  {richEscape(filter.description)}, e.g. {code(filter.example)}`)
	end
	table.insert(lines, "")
	table.insert(lines, "<b>Inserting into scripts</b>")
	table.insert(lines, "• <b>Insert into script</b> writes the items into the script set as <b>Target script</b>, "
		.. "or the script selected in Studio when it's empty. Header and footer are left out.")
	table.insert(lines, `• Items go above a {code("-- @prism")} line when the script has one, otherwise before the closing `
		.. `{code("}")} of {code("return {")}, otherwise at the end. They take the surrounding indentation.`)
	table.insert(lines, "• <b>Replace matching entries</b> rewrites an entry that already has the model's name instead of adding "
		.. "a duplicate, so uploading an icon again updates its ID. The entry must have the template's shape.")
	table.insert(lines, "• Ctrl+Z undoes an insert.")
	table.insert(lines, "")
	table.insert(lines, "<b>Copying</b>")
	table.insert(lines, "Studio doesn't let plugins use the clipboard. Click an output box to select all of it, then press Ctrl+C.")
	table.insert(lines, "")
	table.insert(lines, "<b>Example</b>")
	table.insert(lines, code('{RENDER_NAME|key} = "{ASSET_URI}",'))
	table.insert(lines, `becomes {code('["Fire Sword"] = "rbxassetid://123",')}`)
	return table.concat(lines, "\n")
end

const function openHelp()
	Modal.open({
		title = "Templates help",
		width = 600,
		height = 540,
		buttons = {
			{
				text = "Close",
				variant = "accent",
				activated = function(close)
					close()
				end,
			},
		},
		body = function()
			return new("ScrollingFrame")({
				Name = "Help",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = Theme.BORDER,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ZIndex = Theme.OVERLAY_Z + 1,

				new("TextLabel")({
					Size = UDim2.new(1, -10, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					RichText = true,
					TextWrapped = true,
					Text = helpText(),
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextColor3 = Theme.MUTED,
					Font = Enum.Font.SourceSans,
					TextSize = 15,
					LineHeight = 1.1,
					ZIndex = Theme.OVERLAY_Z + 1,
				}),
			}) :: ScrollingFrame
		end,
	})
end

const function TemplatesPage(props: Props): Frame
	const store = props.store
	const selected = source(nil :: Template.Template?)
	const confirmingDelete = source(false)

	-- keep a valid template selected as the list changes.
	effect(function()
		const list = store.templates()
		const current = vide.untrack(selected)
		if current == nil or not table.find(list, current) then
			selected(vide.untrack(store.currentTemplate) or list[1])
		end
	end)

	const previewEntries = function(): ({ Template.Entry }, boolean)
		const uploads = {}
		for _, entry in store.history() do
			if entry.kind == "upload" then
				table.insert(uploads, entry)
				if #uploads >= PREVIEW_ENTRIES then
					break
				end
			end
		end
		if #uploads > 0 then
			return uploads, true
		end
		return Template.samples, false
	end

	const function editor(template: Template.Template): ScrollingFrame
		local lastBox: TextBox? = nil
		local lastCursor = 0
		local order = 0
		const function nextOrder(): number
			order += 1
			return order
		end
		const function track(box: TextBox)
			cleanup(box:GetPropertyChangedSignal("CursorPosition"):Connect(function()
				if box.CursorPosition > 0 then
					lastBox = box
					lastCursor = box.CursorPosition
				end
			end))
		end
		const function field(key: string, height: number, placeholder: string?, multiLine: boolean?): CodeBox.CodeBox
			const result = CodeBox({
				name = key,
				text = (template :: any)[key] or "",
				placeholder = placeholder,
				multiLine = multiLine,
				size = UDim2.new(1, 0, 0, height),
				layoutOrder = nextOrder(),
				onChange = function(text)
					if ((template :: any)[key] or "") ~= text then
						store.updateTemplate(template, { [key] = text })
					end
				end,
			})
			track(result.box)
			return result
		end

		const nameBox = new("TextBox")({
			Name = "NameBox",
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundColor3 = Theme.INPUT,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Text = template.name,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.TEXT,
			Font = Enum.Font.SourceSans,
			TextSize = 15,

			Theme.stroke(Theme.BORDER),
			new("UIPadding")({ PaddingLeft = UDim.new(0, 8) }),
		}) :: TextBox
		cleanup(nameBox.FocusLost:Connect(function()
			const name = string.match(nameBox.Text, "^%s*(.-)%s*$") or ""
			if name ~= "" and name ~= template.name then
				store.updateTemplate(template, { name = name })
			end
			nameBox.Text = template.name
		end))

		const nameTitle = heading("Name", nextOrder())
		const nameOrder = nextOrder()
		const itemHeading = nextOrder()
		const item = field("item", 130, "Written once per model, e.g. {RENDER_NAME} = {UPLOAD_ASSET_ID},")
		const headerTitle = heading("Header", nextOrder())
		const header = field("header", 52, "Optional, written once before the items")
		const footerTitle = heading("Footer", nextOrder())
		const footer = field("footer", 52, "Optional, written once after the items")
		const separatorTitle = heading("Separator", nextOrder())
		const separator = field("separator", 28, "\\n", false)
		const targetTitle = heading("Target script", nextOrder())
		const target = field("target", 28, "Empty uses the script selected in Studio", false)
		const replaceOrder = nextOrder()
		const previewOrder = nextOrder()

		const preview = function(): (string, { string })
			store.templatesVersion()
			return Template.render(template, (previewEntries()), os.time())
		end

		return new("ScrollingFrame")({
			Name = "Editor",
			Position = UDim2.fromOffset(LIST_WIDTH + 12, TOOLBAR_HEIGHT + 10),
			Size = UDim2.new(1, -(LIST_WIDTH + 12), 1, -(TOOLBAR_HEIGHT + 10)),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.BORDER,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,

			new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
			new("UIPadding")({ PaddingRight = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8) }),
			nameTitle,
			new("Frame")({
				Name = "NameRow",
				Size = UDim2.new(1, 0, 0, 28),
				LayoutOrder = nameOrder,
				BackgroundTransparency = 1,
				nameBox,
			}),
			new("Frame")({
				Name = "ItemHeading",
				Size = UDim2.new(1, 0, 0, 26),
				LayoutOrder = itemHeading,
				BackgroundTransparency = 1,

				new("TextLabel")({
					Size = UDim2.new(1, -160, 1, 0),
					BackgroundTransparency = 1,
					Text = "ITEM",
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Bottom,
					TextColor3 = Theme.SUBTLE,
					Font = Enum.Font.SourceSansBold,
					TextSize = 13,
				}),
				Dropdown({
					anchorPoint = Vector2.new(1, 0),
					position = UDim2.fromScale(1, 0),
					size = UDim2.fromOffset(150, 24),
					text = function()
						return "+ Variable"
					end,
					options = function()
						const list = {}
						for _, variable in Template.variables do
							table.insert(list, { label = `\{{variable.name}}`, value = variable.name })
						end
						return list
					end,
					onSelect = function(name: string)
						const box = lastBox or item.box
						const text = box.Text
						const at = if box == lastBox then math.clamp(lastCursor, 1, #text + 1) else #text + 1
						const placeholder = `\{{name}}`
						box.Text = string.sub(text, 1, at - 1) .. placeholder .. string.sub(text, at)
						lastBox = box
						lastCursor = at + #placeholder
					end,
				}),
			}),
			item.frame,
			headerTitle,
			header.frame,
			footerTitle,
			footer.frame,
			separatorTitle,
			separator.frame,
			targetTitle,
			target.frame,
			(function()
				const toggle = ToggleSetting({
					name = "Replace matching entries",
					index = replaceOrder,
					labelWidth = 0.6,
					description = "When inserting, rewrite an entry that already has the model's name instead of adding a duplicate.",
					value = function()
						store.templatesVersion()
						return template.replace == true
					end,
					onChange = function(value)
						store.updateTemplate(template, { replace = value })
					end,
				})
				toggle.LayoutOrder = replaceOrder
				return toggle
			end)(),
			new("Frame")({
				Name = "Preview",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = previewOrder,
				BackgroundTransparency = 1,

				new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
				new("TextLabel")({
					Size = UDim2.new(1, 0, 0, 24),
					LayoutOrder = 1,
					BackgroundTransparency = 1,
					Text = function()
						const _, real = previewEntries()
						return if real then "PREVIEW · YOUR LATEST UPLOADS" else "PREVIEW · SAMPLE DATA"
					end,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Bottom,
					TextColor3 = Theme.SUBTLE,
					Font = Enum.Font.SourceSansBold,
					TextSize = 13,
				}),
				CodeBox({
					name = "PreviewCode",
					text = function()
						return (preview())
					end,
					size = UDim2.new(1, 0, 0, 170),
					layoutOrder = 2,
				}).frame,
				new("TextLabel")({
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					LayoutOrder = 3,
					BackgroundTransparency = 1,
					Text = function()
						const _, warnings = preview()
						return table.concat(warnings, "\n")
					end,
					TextWrapped = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Theme.YELLOW,
					Font = Enum.Font.SourceSans,
					TextSize = 14,
				}),
			}),
		}) :: ScrollingFrame
	end

	local confirmToken = 0
	return new("Frame")({
		Name = "TemplatesPage",
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		BackgroundTransparency = 1,

		new("TextLabel")({
			Size = UDim2.new(1, -40, 0, TOOLBAR_HEIGHT),
			BackgroundTransparency = 1,
			Text = "Fill in code with your uploads, then copy it or insert it into a script.",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.SUBTLE,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
		}),
		Button({
			name = "Help",
			text = "?",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.fromScale(1, 0),
			size = UDim2.fromOffset(TOOLBAR_HEIGHT, TOOLBAR_HEIGHT),
			activated = openHelp,
		}),
		new("ScrollingFrame")({
			Name = "List",
			Position = UDim2.fromOffset(0, TOOLBAR_HEIGHT + 10),
			Size = UDim2.new(0, LIST_WIDTH, 1, -(TOOLBAR_HEIGHT + 10 + 4 * 34)),
			BackgroundColor3 = Theme.GROUP,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.BORDER,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,

			Theme.stroke(Theme.BORDER),
			new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
			vide.values(store.templates, function(template, index)
				return new("TextButton")({
					Name = "Template",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = index,
					BackgroundColor3 = function()
						if selected() == template then
							return Theme.BLUE_DARK
						end
						return if index() % 2 == 0 then Theme.ROW_ALT else Theme.ROW
					end,
					BorderSizePixel = 0,
					AutoButtonColor = true,
					Text = function()
						store.templatesVersion()
						return `  {template.name}`
					end,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextColor3 = Theme.TEXT,
					Font = Enum.Font.SourceSans,
					TextSize = 15,
					Activated = function()
						selected(template)
						confirmingDelete(false)
					end,
				})
			end),
		}),
		new("Frame")({
			Name = "ListActions",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromOffset(LIST_WIDTH, 4 * 34 - 6),
			BackgroundTransparency = 1,

			new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
			Button({
				text = "New",
				variant = "accent",
				size = UDim2.new(1, 0, 0, 28),
				layoutOrder = 1,
				activated = function()
					selected(store.addTemplate({ name = "New template", item = "{RENDER_NAME} = {UPLOAD_ASSET_ID},", separator = "\\n" }))
				end,
			}),
			Button({
				text = "Duplicate",
				size = UDim2.new(1, 0, 0, 28),
				layoutOrder = 2,
				enabled = function()
					return selected() ~= nil
				end,
				activated = function()
					const current = selected()
					if current then
						const copy = table.clone(current)
						copy.name = `{current.name} copy`
						selected(store.addTemplate(copy))
					end
				end,
			}),
			Button({
				text = function()
					return if confirmingDelete() then "Confirm delete" else "Delete"
				end,
				variant = "danger",
				size = UDim2.new(1, 0, 0, 28),
				layoutOrder = 3,
				enabled = function()
					return selected() ~= nil
				end,
				activated = function()
					confirmToken += 1
					const current = selected()
					if confirmingDelete() and current then
						confirmingDelete(false)
						store.deleteTemplate(current)
						return
					end
					confirmingDelete(true)
					const token = confirmToken
					task.delay(CONFIRM_TIME, function()
						if token == confirmToken then
							confirmingDelete(false)
						end
					end)
				end,
			}),
			Button({
				text = "Restore defaults",
				size = UDim2.new(1, 0, 0, 28),
				layoutOrder = 4,
				activated = function()
					store.restoreTemplates()
					-- restored templates change in place, so rebuild the editor.
					const current = selected()
					selected(nil)
					selected(current)
					store.setNotice("Restored the built-in templates.", "success")
				end,
			}),
		}),
		vide.values(function()
			const current = selected()
			return if current then { current } else {}
		end, editor),
		new("TextLabel")({
			Name = "Empty",
			Position = UDim2.fromOffset(LIST_WIDTH + 12, TOOLBAR_HEIGHT + 10),
			Size = UDim2.new(1, -(LIST_WIDTH + 12), 0, 60),
			BackgroundTransparency = 1,
			Visible = function()
				return selected() == nil
			end,
			Text = "No templates. Click New, or Restore defaults.",
			TextColor3 = Theme.SUBTLE,
			Font = Enum.Font.SourceSans,
			TextSize = 15,
		}),
	}) :: Frame
end

return TemplatesPage

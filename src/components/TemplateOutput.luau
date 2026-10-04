-- selene: allow(mixed_table)
-- picks a template and shows it filled in with uploads, ready to copy or insert into a script.
const vide = require("../vide")
const Theme = require("./Theme")
const Button = require("./Button")
const Dropdown = require("./Dropdown")
const CodeBox = require("./CodeBox")
const Template = require("../Template")
const Store = require("../Store")

const new = vide.create
const source = vide.source

const COPIED_TIME = 1.5

export type Props = {
	store: Store.Store,
	entries: { Template.Entry },
	size: UDim2?,
	position: UDim2?,
	layoutOrder: number?,
}

const function TemplateOutput(props: Props): Frame
	const store = props.store
	const copied = source(false)
	local copyToken = 0
	const output = function(): (string, { string })
		const template = store.currentTemplate()
		if template == nil then
			return "", {}
		end
		return Template.render(template, props.entries, os.time())
	end

	return new("Frame")({
		Name = "TemplateOutput",
		Size = props.size or UDim2.new(1, 0, 0, 240),
		Position = props.position,
		LayoutOrder = props.layoutOrder or 0,
		BackgroundTransparency = 1,

		new("TextLabel")({
			Size = UDim2.fromOffset(70, 28),
			BackgroundTransparency = 1,
			Text = "Template",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.MUTED,
			Font = Enum.Font.SourceSans,
			TextSize = 15,
		}),
		Dropdown({
			position = UDim2.fromOffset(72, 0),
			size = UDim2.new(1, -72, 0, 28),
			text = function()
				const template = store.currentTemplate()
				return if template then template.name else "No templates"
			end,
			options = function()
				const list = {}
				for _, template in store.templates() do
					table.insert(list, { label = template.name, value = template.name })
				end
				return list
			end,
			emptyText = "Create one in the Templates tab",
			onSelect = store.useTemplate,
		}),
		CodeBox({
			text = function()
				return (output())
			end,
			position = UDim2.fromOffset(0, 36),
			size = UDim2.new(1, 0, 1, -76),
		}).frame,
		new("TextLabel")({
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, -252, 0, 30),
			BackgroundTransparency = 1,
			Text = function()
				const _, warnings = output()
				if #warnings > 0 then
					return warnings[1]
				end
				const template = store.currentTemplate()
				const target = if template and template.target and template.target ~= "" then template.target else nil
				return if target then `Insert writes to {target}.` else "Insert writes to the selected script."
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = function()
				const _, warnings = output()
				return if #warnings > 0 then Theme.YELLOW else Theme.SUBTLE
			end,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
		}),
		Button({
			text = function()
				return if copied() then "Copied" else "Copy"
			end,
			anchorPoint = Vector2.new(1, 1),
			position = UDim2.new(1, -148, 1, 0),
			size = UDim2.fromOffset(94, 30),
			enabled = function()
				return store.currentTemplate() ~= nil and #props.entries > 0
			end,
			activated = function()
				const text = output()
				store.copyText(text, function(ok)
					if not ok then
						return
					end
					copyToken += 1
					const token = copyToken
					copied(true)
					task.delay(COPIED_TIME, function()
						if token == copyToken then
							copied(false)
						end
					end)
				end)
			end,
		}),
		Button({
			text = "Insert into script",
			anchorPoint = Vector2.new(1, 1),
			position = UDim2.fromScale(1, 1),
			size = UDim2.fromOffset(140, 30),
			enabled = function()
				return store.currentTemplate() ~= nil and #props.entries > 0
			end,
			activated = function()
				const template = store.currentTemplate()
				if template then
					store.insertTemplate(template, props.entries)
				end
			end,
		}),
	}) :: Frame
end

return TemplateOutput

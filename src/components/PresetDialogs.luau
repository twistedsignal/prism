-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const Modal = require("./Modal")
const Dropdown = require("./Dropdown")
const CodeBox = require("./CodeBox")
const Store = require("../Store")
const new = vide.create
const source = vide.source

const PresetDialogs = {}

const function label(text: string | () -> string, y: number, height: number, color: Color3?): TextLabel
	return new("TextLabel")({
		Size = UDim2.new(1, 0, 0, height), Position = UDim2.fromOffset(0, y),
		BackgroundTransparency = 1, Text = text, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = color or Theme.TEXT, Font = Enum.Font.SourceSans, TextSize = 15,
		ZIndex = Theme.OVERLAY_Z + 1,
	}) :: TextLabel
end

const function names(store: Store.Store): { Dropdown.Option }
	const list = {}
	for name in store.presets() do
		table.insert(list, name)
	end
	table.sort(list)
	const options = {}
	for _, name in list do
		table.insert(options, { label = name, value = name })
	end
	return options
end

function PresetDialogs.import(store: Store.Store)
	const code = source("")
	const name = source("")
	const validated = source(false)
	const busy = source(false)
	const errorText = source("")
	local alive = true
	Modal.open({
		title = "Import preset", height = 260,
		buttons = {
			{ text = "Cancel", activated = function(close) close() end },
			{
				text = function() return if busy() then "Working…" elseif validated() then "Save" else "Next" end,
				variant = "accent", enabled = function() return not busy() end,
				activated = function(close)
					errorText("")
					busy(true)
					if validated() then
						store.importPreset(code(), name(), function(result, message)
							if not alive then return end
							busy(false)
							if result then
								close()
							else
								errorText(message or "Could not import preset")
							end
						end)
					else
						store.decodePreset(code(), function(result, message)
							if not alive then return end
							busy(false)
							if result then
								validated(true)
							else
								errorText(message or "Invalid preset code")
							end
						end)
					end
				end,
			},
		},
		body = function()
			vide.cleanup(function()
				alive = false
			end)
			const input = CodeBox({ text = "", placeholder = "Paste a preset code", multiLine = false,
				size = UDim2.new(1, 0, 0, 32), position = UDim2.fromOffset(0, 30),
				onChange = function(value)
					if not busy() then
						code(value)
					end
				end,
			})
			input.frame.Visible = false
			vide.effect(function()
				input.frame.Visible = not validated()
				input.box.TextEditable = not busy()
			end)
			const nameBox = new("TextBox")({
				Size = UDim2.new(1, 0, 0, 32), Position = UDim2.fromOffset(0, 30),
				BackgroundColor3 = Theme.INPUT, BorderSizePixel = 0, ClearTextOnFocus = false,
				Text = "", PlaceholderText = "Your preset name", PlaceholderColor3 = Theme.SUBTLE,
				TextColor3 = Theme.TEXT, Font = Enum.Font.SourceSans, TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left, ZIndex = Theme.OVERLAY_Z + 1,
				Visible = validated, TextEditable = function() return not busy() end,
				vide.changed("Text", name), Theme.stroke(Theme.BORDER),
				new("UIPadding")({ PaddingLeft = UDim.new(0, 8) }),
			}) :: TextBox
			vide.effect(function()
				if validated() then
					task.defer(function()
						if alive then
							nameBox:CaptureFocus()
						end
					end)
				end
			end)
			return new("Frame")({ BackgroundTransparency = 1,
				label(function() return if validated() then "Valid code. Choose a name to save it." else "Paste someone's code to add their preset." end, 0, 28),
				input.frame, nameBox,
				label("Saving adds it to your list. Select it later to apply it.", 72, 36),
				label(errorText, 112, 62, Theme.DANGER),
			}) :: Frame
		end,
	})
end

function PresetDialogs.saved(store: Store.Store, action: string)
	const options = names(store)
	if #options == 0 then return end
	const active = store.activePreset()
	const selected = source(if active and store.presets()[active] then active else options[1].value)
	const code = source("")
	const busy = source(false)
	const errorText = source("")
	const confirming = source(false)
	const copied = source(false)
	const revision = source(0)
	local alive = true
	local generation = 0
	const exporting = action == "export"
	Modal.open({
		title = if exporting then "Export preset" else "Delete preset", height = 270,
		buttons = {
			{ text = if exporting then "Close" else "Cancel", activated = function(close) close() end },
			{
				text = function()
					return if busy() then "Working…" elseif exporting then (if copied() then "Copied" else "Copy")
						elseif confirming() then "Confirm delete" else "Delete"
				end,
				variant = if exporting then "accent" else "danger",
				enabled = function() return not busy() and (not exporting or code() ~= "") end,
				activated = function(close)
					if not exporting and not confirming() then
						confirming(true)
						return
					end
					busy(true)
					errorText("")
					if exporting then
						const token = generation
						store.copyText(code(), function(ok)
							if not alive or generation ~= token then return end
							busy(false)
							copied(ok)
							if not ok then
								errorText("Copy failed. Select the code and press Ctrl+C or Cmd+C.")
							end
						end)
					else
						store.deletePreset(selected(), function(ok, message)
							if not alive then return end
							busy(false)
							if ok then
								close()
							else
								errorText(message or "Could not delete preset")
							end
						end)
					end
				end,
			},
		},
		body = function()
			vide.cleanup(function()
				alive = false
			end)
			const children = {
				Dropdown({ text = selected, options = function() return options end,
					onSelect = function(value)
						if busy() then return end
						confirming(false)
						copied(false)
						vide.batch(function()
							selected(value)
							revision(revision() + 1)
						end)
					end, size = UDim2.new(1, 0, 0, 28),
				}),
				label(errorText, 124, 58, Theme.DANGER),
			}
			if exporting then
				const output = CodeBox({ text = code, multiLine = false,
					size = UDim2.new(1, 0, 0, 36), position = UDim2.fromOffset(0, 40),
				})
				table.insert(children, output.frame)
				table.insert(children, label(function()
					return if code() ~= "" then `{#code()} characters. Share this code with anyone using Prism.`
						elseif busy() then "Generating code…" else "Could not generate a code. Try choosing the preset again."
				end, 86, 36))
				vide.effect(function()
					const name = selected()
					revision()
					generation += 1
					const token = generation
					code("")
					errorText("")
					busy(true)
					store.exportPreset(name, function(result, message)
						if not alive or token ~= generation then return end
						busy(false)
						if result then
							code(result.code)
						else
							errorText(message or "Could not export preset")
						end
					end)
				end)
			else
				table.insert(children, label(function()
					return if confirming() then `Delete "{selected()}"? This cannot be undone.`
						else "Choose the preset to delete. Your model's current settings will stay the same."
				end, 42, 70))
			end
			return new("Frame")({ BackgroundTransparency = 1, children }) :: Frame
		end,
	})
end

return PresetDialogs

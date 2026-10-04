-- the per-place choice between Roblox's 2022 and pre-2022 built-in materials.
-- plugins usually cannot read MaterialService.Use2022Materials, so places that turn
-- it off need this setting; it is saved per place on this Studio account.
const Data = require("./Data")
const Serializer = require("./Serializer")

export type Style = Serializer.MaterialStyle

const STYLES = { auto = true, ["2022"] = true, legacy = true }

const function key(): string
	return `PrismMaterialStyle:{if game.PlaceId ~= 0 then game.PlaceId else "local"}`
end

-- reads the saved style and applies it to serialization.
const function load(plugin: Plugin): Style
	const ok, saved = pcall(Data.load, plugin, key(), "auto")
	const style: Style = if ok and STYLES[saved] then saved else "auto"
	Serializer.setMaterialStyle(style)
	return style
end

const function save(plugin: Plugin, style: Style)
	Serializer.setMaterialStyle(style)
	task.spawn(pcall, Data.save, plugin, key(), style)
end

return { load = load, save = save }

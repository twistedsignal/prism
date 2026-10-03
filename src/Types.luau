export type Status = {
	version: string,
	blender: string,
	busy: boolean,
	platform: string,
}

export type SettingType = "number" | "bool" | "color" | "rgba" | "text" | "select"

-- robloxFont: a Roblox font family for previewing a font option in its own typeface.
export type SelectOption = { value: string, label: string, robloxFont: string? }

export type SettingSchema = {
	key: string,
	label: string,
	type: SettingType,
	min: number?,
	max: number?,
	step: number?,
	default: any,
	auto: string?,
	hidden: boolean?,
	description: string?,
	options: { SelectOption }?,
	-- "fonts": options come from the backend's installed fonts.
	optionsSource: string?,
	maxLength: number?,
	-- hide unless this setting is on, non-zero or non-empty; "!key" inverts it.
	requires: string?,
}

-- a collapsible sub-section inside a section; groups can nest.
export type GroupSchema = {
	type: "group",
	id: string,
	label: string,
	collapsed: boolean?,
	requires: string?,
	settings: { SettingSchema | GroupSchema },
}

export type SectionSchema = {
	id: string,
	label: string,
	collapsed: boolean?,
	settings: { SettingSchema | GroupSchema },
}

export type Schema = {
	sections: { SectionSchema },
	defaults: Settings,
}

export type Settings = { [string]: any }
export type TextBounds = { x: number, y: number, width: number, height: number }

export type Config = {
	outputFolder: string,
	previewSize: number,
	renderSize: number,
	previewAA: string,
	renderAA: string,
	filenamePattern: string,
	overwrite: boolean,
	blenderPath: string,
	ravenPath: string,
	defaultCreator: string,
	port: number,
	emojiProvider: string,
}

export type ModelState = "serializing" | "sending" | "ready" | "error"

export type Model = {
	id: string,
	name: string,
	instance: Instance,
	sceneId: (string?) -> string?,
	state: (ModelState?) -> ModelState,
	warning: (string?) -> string?,
	settings: (Settings?) -> Settings,
	assetId: (string?) -> string?,
	thumbnail: EditableImage?,
	thumbnailVersion: (number?) -> number,
	visualVersion: (number?) -> number,
}

return nil

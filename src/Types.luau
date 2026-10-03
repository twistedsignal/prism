export type Status = {
	version: string,
	blender: string,
	busy: boolean,
	platform: string,
}

export type SettingType = "number" | "bool" | "color" | "rgba" | "text" | "select"

export type SelectOption = { value: string, label: string }

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
}

export type SectionSchema = {
	id: string,
	label: string,
	collapsed: boolean?,
	settings: { SettingSchema },
}

export type Schema = {
	sections: { SectionSchema },
	defaults: Settings,
}

export type Settings = { [string]: any }

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
}

return nil

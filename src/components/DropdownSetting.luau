-- selene: allow(mixed_table)
const BaseSetting = require("./BaseSetting")
const Dropdown = require("./Dropdown")

export type Props = {
	name: string,
	index: number,
	description: string?,
	text: () -> string,
	options: () -> { Dropdown.Option },
	onSelect: (any) -> (),
}

const function DropdownSetting(props: Props): Frame
	const row = BaseSetting({
		name = props.name,
		index = props.index,
		description = props.description,
	})
	const dropdown = Dropdown({
		text = props.text,
		options = props.options,
		onSelect = props.onSelect,
		size = UDim2.new(0.5, -6, 1, -6),
		position = UDim2.new(0.5, 3, 0, 3),
	})
	dropdown.Parent = row
	return row
end

return DropdownSetting

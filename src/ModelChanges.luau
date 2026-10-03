-- Watch properties consumed by the serializer, without reacting to physics or editor metadata.
const PROPERTIES = {
	BasePart = { "Name", "CFrame", "Size", "Color", "Transparency", "Material", "MaterialVariant", "PivotOffset" },
	Part = { "Shape" },
	MeshPart = { "MeshId", "MeshContent", "MeshSize", "TextureID", "TextureContent" },
	PartOperation = { "UsePartColor", "MeshData", "AssetId" },
	DataModelMesh = { "Scale", "Offset", "VertexColor" },
	SpecialMesh = { "MeshType", "MeshId", "MeshContent", "TextureId", "TextureContent" },
	SurfaceAppearance = { "ColorMap", "ColorMapContent", "AlphaMode", "Color" },
	Decal = { "Texture", "TextureContent", "ColorMapContent", "Color3", "Transparency", "Face", "ZIndex" },
	Texture = { "StudsPerTileU", "StudsPerTileV", "OffsetStudsU", "OffsetStudsV" },
	Shirt = { "ShirtTemplate", "ShirtTemplateContent", "Color3" },
	Pants = { "PantsTemplate", "PantsTemplateContent", "Color3" },
	ShirtGraphic = { "Graphic", "GraphicContent", "Color3" },
	Model = { "WorldPivot", "PrimaryPart" },
	MaterialVariant = { "Name", "BaseMaterial", "ColorMap", "ColorMapContent", "StudsPerTile" },
}

const function watch(root: Instance, onChange: () -> ()): () -> ()
	const connections: { [Instance]: RBXScriptConnection } = {}
	const function observe(instance: Instance)
		if connections[instance] then
			return
		end
		const properties = {}
		for class, names in PROPERTIES do
			if instance:IsA(class) then
				for _, name in names do
					properties[name] = true
				end
			end
		end
		connections[instance] = instance.Changed:Connect(function(property)
			if properties[property] or instance:IsA("MaterialService") then
				onChange()
			end
		end)
	end
	observe(root)
	for _, descendant in root:GetDescendants() do
		observe(descendant)
	end
	const added = root.DescendantAdded:Connect(function(instance)
		observe(instance)
		onChange()
	end)
	const removing = root.DescendantRemoving:Connect(function(instance)
		const connection = connections[instance]
		if connection then
			connection:Disconnect()
			connections[instance] = nil
		end
		onChange()
	end)
	return function()
		added:Disconnect()
		removing:Disconnect()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
end

return { watch = watch }

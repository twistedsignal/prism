`head.mesh` is Roblox Studio's built-in classic head mesh from
`content/avatar/heads/head.mesh`. It preserves the original triangle geometry,
normals and UVs for `SpecialMesh.MeshType.Head`, without a network request.

The serializer sends scale relative to the classic 2 x 1 x 1 head part, multiplied
by `SpecialMesh.Scale`. The backend keeps the mesh's original origin. Mesh offsets
are applied through the serialized part transform.

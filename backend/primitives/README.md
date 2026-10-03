`head.mesh` is Roblox Studio's built-in classic head mesh from
`content/avatar/heads/head.mesh`. It preserves the original triangle geometry,
normals and UVs for `SpecialMesh.MeshType.Head`, without a network request.

The serializer multiplies part size by `SpecialMesh.Scale`, constrains X and Z to
their smaller value, and divides all axes by the built-in 1.25 scale. This follows
the Head-to-FileMesh conversion in
[ToMeshPart.lua](https://gist.github.com/MaximumADHD/831bc3ab4b4f8cad3c174fcb7d99884b).
The backend keeps the mesh's original origin. Mesh offsets are applied through the
serialized part transform.

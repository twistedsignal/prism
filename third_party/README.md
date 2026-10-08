UnionMesh.luau adapts the RBXM shared-string and CSG mesh formats implemented in
[EgoMoose's CSG-to-mesh plugin](https://github.com/EgoMoose/rbx-csg-to-mesh-plugin),
which builds on [krakow10's rbx_mesh](https://github.com/krakow10/rbx_mesh).
Their MIT notices are retained in this directory.

Prism reads the triangle attributes directly rather than constructing an EditableMesh.
It validates counts, indices and buffer lengths and falls back when a format is unsupported.

The navigation and history icons come from [Lucide](https://lucide.dev/). Their ISC and applicable MIT notices are included in [lucide-LICENSE](lucide-LICENSE). Original SVGs and the uploaded PNGs are kept in `assets/lucide`.

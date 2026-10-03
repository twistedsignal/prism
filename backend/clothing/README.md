These meshes come from Roblox Studio's `content/avatar/compositing` directory:

- `right.mesh`: `R15CompositRightArmBase.mesh`
- `left.mesh`: `R15CompositLeftArmBase.mesh`
- `torso.mesh`: `R15CompositTorsoBase.mesh`

They map classic clothing into the 264 x 284 limb and 388 x 272 torso atlases.
Arms and legs share each side's UV layout. Mesh positions are atlas pixels with
Y pointing up; source UVs use the original 585 x 559 clothing template.
Keeping each body mesh's original UVs preserves the separate joint islands and
the fixed 64/48/16-pixel upper/lower/end segment mapping.

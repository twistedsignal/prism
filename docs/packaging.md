# Packaging

Prism packages the Qt application with PyInstaller. Blender remains an external dependency in this first release. On a clean machine, install Blender and make `blender` available on `PATH` before launching Prism.

Build a local executable after installing development dependencies:

```sh
python -m PyInstaller prism.spec
```

The output is `dist/Prism`. Test model import, preview, export, and application shutdown on the target operating system before distributing a release.

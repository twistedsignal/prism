# PyInstaller build recipe for local desktop release builds.
from PyInstaller.utils.hooks import collect_data_files

datas = collect_data_files("prism") + [("src/prism/blender_worker/main.py", "prism/blender_worker")]

a = Analysis(
    ["src/prism/app/main.py"],
    pathex=["src"],
    datas=datas,
    hiddenimports=["PySide6"],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, a.binaries, a.datas, name="Prism", console=False)

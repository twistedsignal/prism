"""Lightweight backend entry point, also callable through Blender for installation:

    blender --background --factory-startup --python backend/main.py -- [serve|install|uninstall] [options]
"""

import argparse
import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config  # noqa: E402


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    parser = argparse.ArgumentParser(prog="blender --background --python main.py --")
    parser.add_argument("command", nargs="?", default="serve", choices=("serve", "install", "uninstall"))
    parser.add_argument("--port", type=int, help="Port to listen on (default: from config)")
    parser.add_argument("--log", type=Path, help="Append output to this file")
    parser.add_argument("--blender", help="Blender executable for the startup entry")
    parser.add_argument("--raven", help="raven executable to record in the config")
    parser.add_argument("--creator", help="Default upload creator (user:<id> or group:<id>)")
    parser.add_argument("--managed", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main():
    args = parse_args()
    import runtime

    # Old startup entries launch main.py through Blender. Replace that process
    # with plain Python and rewrite the startup entry for subsequent launches.
    if args.command == "serve" and "bpy" in sys.modules:
        value = runtime.configure(args.blender)
        import autostart
        installed = not (Path(__file__).resolve().parent.parent / "wally.toml").exists()
        if installed:
            autostart.install(start=False)
        command = [value["python"], str(Path(__file__).resolve()), "serve"]
        if args.port:
            command += ["--port", str(args.port)]
        if args.log:
            command += ["--log", str(args.log)]
        if sys.platform == "win32":
            if installed:
                runtime.restart_windows_task()
            else:
                subprocess.Popen(command, creationflags=subprocess.CREATE_NO_WINDOW, close_fds=True)
            os._exit(0)
        os.execv(command[0], command)
    if args.blender or (args.command == "install" and "bpy" in sys.modules):
        runtime.configure(args.blender)
    if args.managed:
        os.environ["PRISM_MANAGED"] = "1"
    if args.log is not None:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        log = args.log.open("a", buffering=1, encoding="utf-8")
        sys.stdout = sys.stderr = log

    if args.command == "install":
        import autostart

        autostart.install(args.blender, args.raven, args.creator)
        return
    if args.command == "uninstall":
        import autostart

        autostart.uninstall()
        return

    import server

    def stop(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)

    store = config.Store()
    port = args.port or store.get_config()["port"]
    try:
        server.serve(store, port)
    except OSError as error:
        print(f"[prism] Could not listen on 127.0.0.1:{port}: {error}")
        sys.stdout.flush()
        sys.exit(1)


if __name__ == "__main__":
    main()

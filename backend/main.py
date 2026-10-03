"""Prism backend entry point. Runs inside Blender:

    blender --background --factory-startup --python backend/main.py -- [serve|install|uninstall] [options]
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config  # noqa: E402


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser(prog="blender --background --python main.py --")
    parser.add_argument("command", nargs="?", default="serve", choices=("serve", "install", "uninstall"))
    parser.add_argument("--port", type=int, help="Port to listen on (default: from config)")
    parser.add_argument("--log", type=Path, help="Append output to this file")
    parser.add_argument("--blender", help="Blender executable for the startup entry")
    parser.add_argument("--raven", help="raven executable to record in the config")
    parser.add_argument("--creator", help="Default upload creator (user:<id> or group:<id>)")
    return parser.parse_args(argv)


def main():
    args = parse_args()
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

    store = config.Store()
    port = args.port or store.get_config()["port"]
    try:
        server.serve(store, port)
    except OSError as error:
        print(f"[prism] Could not listen on 127.0.0.1:{port}: {error}")
        sys.stdout.flush()
        sys.exit(1)


main()

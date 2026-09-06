import { spawn } from "node:child_process";
import { createRequire } from "node:module";

/*
  Luar's AppImage exposes its private GTK/WebKit libraries through the parent
  shell. A Tauri child launched from Luar would inherit those paths and WebKit
  would look for WebKitNetworkProcess inside the AppImage instead of the host.
*/
const environment = { ...process.env };
delete environment.LD_LIBRARY_PATH;
delete environment.GIO_EXTRA_MODULES;

if (environment.XDG_DATA_DIRS) {
  environment.XDG_DATA_DIRS = environment.XDG_DATA_DIRS
    .split(":")
    .filter((entry) => !entry.includes(".mount_Luar_"))
    .join(":");
}

const require = createRequire(import.meta.url);
const tauriCli = require.resolve("@tauri-apps/cli/tauri.js");
const child = spawn(process.execPath, [tauriCli, "dev"], { env: environment, stdio: "inherit" });
child.on("exit", (code) => process.exit(code ?? 1));

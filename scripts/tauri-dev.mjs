import { spawn } from "node:child_process";

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

const executable = process.env.npm_execpath ? process.execPath : process.platform === "win32" ? "pnpm.cmd" : "pnpm";
const args = process.env.npm_execpath ? [process.env.npm_execpath, "exec", "tauri", "dev"] : ["exec", "tauri", "dev"];
const child = spawn(executable, args, { env: environment, stdio: "inherit" });
child.on("exit", (code) => process.exit(code ?? 1));

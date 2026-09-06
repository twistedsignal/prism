import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

/*
  Luar's AppImage exposes its private GTK/WebKit libraries through the parent
  shell. A Tauri child launched from Luar would inherit those paths and WebKit
  would look for WebKitNetworkProcess inside the AppImage instead of the host.
*/
const environment = { ...process.env };
delete environment.LD_LIBRARY_PATH;
delete environment.GIO_EXTRA_MODULES;
environment.WEBKIT_DISABLE_DMABUF_RENDERER = "1";

const stableRustBin = join(homedir(), ".rustup", "toolchains", "stable-x86_64-unknown-linux-gnu", "bin");
if (existsSync(join(stableRustBin, "cargo"))) {
  environment.PATH = `${stableRustBin}${delimiter}${environment.PATH ?? ""}`;
}

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

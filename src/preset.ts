import { strFromU8, strToU8, unzlibSync, zlibSync } from "fflate";
import type { RenderSettings } from "./types";

const prefix = "P1.";
const toBase64Url = (bytes: Uint8Array): string => {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
};
const fromBase64Url = (value: string): Uint8Array => {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/") + "===".slice((value.length + 3) % 4);
  const text = atob(padded);
  return Uint8Array.from(text, (character) => character.charCodeAt(0));
};

export const encodePreset = (settings: RenderSettings): string => prefix + toBase64Url(zlibSync(strToU8(JSON.stringify(settings)), { level: 9 }));
export const decodePreset = (code: string): RenderSettings => {
  if (!code.startsWith(prefix)) throw new Error("That is not a Prism P1 preset code.");
  const value: unknown = JSON.parse(strFromU8(unzlibSync(fromBase64Url(code.slice(prefix.length)))));
  if (!value || typeof value !== "object") throw new Error("The preset has no settings.");
  return value as RenderSettings;
};

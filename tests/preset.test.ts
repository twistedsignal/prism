import { describe, expect, it } from "vitest";
import { decodePreset, encodePreset } from "../src/preset";
import { defaultSettings } from "../src/types";

describe("Prism preset codes", () => {
  it("round trips render settings through a compact P1 code", () => {
    const settings = { ...defaultSettings(), width: 2048, transparent: true };
    const code = encodePreset(settings);
    expect(code.startsWith("P1.")).toBe(true);
    expect(decodePreset(code)).toEqual(settings);
  });

  it("rejects non-Prism codes", () => expect(() => decodePreset("hello")).toThrow("Prism P1"));
});

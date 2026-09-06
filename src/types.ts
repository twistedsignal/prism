export type RenderSettings = {
  width: number; height: number; format: string; transparent: boolean; background: [number, number, number];
  orbit: [number, number]; focalLength: number; framing: number; keyStrength: number; fillStrength: number;
  worldStrength: number; cavity: boolean; cavityStrength: number;
};

export type PrismModel = { id: string; name: string; folder: string; sourcePath: string; previewPath: string | null; settings: RenderSettings };
export type Project = { id: string; name: string; folders: string[]; models: PrismModel[] };

export const defaultSettings = (): RenderSettings => ({
  width: 1024, height: 1024, format: "PNG", transparent: false, background: [0.055, 0.063, 0.086],
  orbit: [35, 25], focalLength: 55, framing: 1.45, keyStrength: 1100, fillStrength: 260, worldStrength: 1, cavity: true, cavityStrength: 0.65,
});

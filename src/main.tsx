import React from "react";
import { createRoot } from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { open, save } from "@tauri-apps/plugin-dialog";
import { convertFileSrc } from "@tauri-apps/api/core";
import { Camera, ChevronDown, ChevronRight, Copy, Folder, FolderPlus, ImageDown, Import, LoaderCircle, Moon, PackagePlus, PanelRight, Play, Settings2, SlidersHorizontal, Sparkles, Sun, X } from "lucide-react";
import { decodePreset, encodePreset } from "./preset";
import { defaultSettings, type PrismModel, type Project, type RenderSettings } from "./types";
import "./styles.css";

type Toast = { tone: "error" | "notice"; text: string } | null;
const formatChoices = ["PNG", "JPEG", "WEBP", "OPEN_EXR"];

function App(): React.JSX.Element {
  const [projects, setProjects] = React.useState<Project[]>([]);
  const [activeProjectId, setActiveProjectId] = React.useState<string | null>(null);
  const [activeModelId, setActiveModelId] = React.useState<string | null>(null);
  const [dockOpen, setDockOpen] = React.useState(true);
  const [settingsOpen, setSettingsOpen] = React.useState(false);
  const [rendering, setRendering] = React.useState(false);
  const [toast, setToast] = React.useState<Toast>(null);
  const [blender, setBlender] = React.useState("Checking Blender…");

  const activeProject = projects.find((project) => project.id === activeProjectId) ?? null;
  const activeModel = activeProject?.models.find((model) => model.id === activeModelId) ?? null;
  const refresh = React.useCallback(async () => {
    try {
      const next = await invoke<Project[]>("list_projects"); setProjects(next);
      if (!activeProjectId && next[0]) setActiveProjectId(next[0].id);
    } catch (error) { setToast({ tone: "error", text: String(error) }); }
  }, [activeProjectId]);
  React.useEffect(() => { void refresh(); void invoke<string>("blender_status").then(setBlender).catch((error) => setBlender(String(error))); }, [refresh]);
  React.useEffect(() => { if (activeProject && !activeModel && activeProject.models[0]) setActiveModelId(activeProject.models[0].id); }, [activeModel, activeProject]);

  const createProject = async (): Promise<void> => {
    const name = window.prompt("Project name", "Untitled render project")?.trim(); if (!name) return;
    try { const project = await invoke<Project>("create_project", { name }); setProjects((current) => [...current, project]); setActiveProjectId(project.id); setActiveModelId(null); } catch (error) { setToast({ tone: "error", text: String(error) }); }
  };
  const importModel = async (): Promise<void> => {
    if (!activeProject) return setToast({ tone: "error", text: "Create or select a project first." });
    const input = await open({ multiple: false, filters: [{ name: "3D models", extensions: ["blend", "fbx", "obj", "glb", "gltf", "stl", "dae", "ply", "abc", "usd", "usda", "usdc", "usdz"] }] });
    if (typeof input !== "string") return;
    try { const model = await invoke<PrismModel>("import_model", { projectId: activeProject.id, input }); await refresh(); setActiveModelId(model.id); } catch (error) { setToast({ tone: "error", text: String(error) }); }
  };
  const updateSettings = (patch: Partial<RenderSettings>): void => {
    if (!activeModel || !activeProject) return;
    const settings = { ...activeModel.settings, ...patch };
    setProjects((current) => current.map((project) => project.id !== activeProject.id ? project : { ...project, models: project.models.map((model) => model.id === activeModel.id ? { ...model, settings } : model) }));
  };
  const persist = async (): Promise<void> => { if (activeProject && activeModel) await invoke("save_model_settings", { projectId: activeProject.id, modelId: activeModel.id, settings: activeModel.settings }); };
  const render = async (preview: boolean): Promise<void> => {
    if (!activeModel || !activeProject) return;
    setRendering(true); setToast(null);
    try { await persist(); const previewPath = await invoke<string>("render_model", { projectId: activeProject.id, modelId: activeModel.id, preview }); setProjects((current) => current.map((project) => project.id !== activeProject.id ? project : { ...project, models: project.models.map((model) => model.id === activeModel.id ? { ...model, previewPath } : model) })); setToast({ tone: "notice", text: preview ? "Preview rendered." : "Export rendered. The output path is in the project render folder." }); } catch (error) { setToast({ tone: "error", text: String(error) }); } finally { setRendering(false); }
  };
  const copyPreset = async (): Promise<void> => { if (!activeModel) return; await navigator.clipboard.writeText(encodePreset(activeModel.settings)); setToast({ tone: "notice", text: "Compact preset code copied." }); };
  const importPreset = async (): Promise<void> => { const code = window.prompt("Paste a Prism preset code")?.trim(); if (!code) return; try { updateSettings(decodePreset(code)); setToast({ tone: "notice", text: "Preset applied. Render or save to keep it." }); } catch (error) { setToast({ tone: "error", text: error instanceof Error ? error.message : String(error) }); } };

  return <div className="app">
    <header className="titlebar"><div className="brand"><Sparkles size={16} /> Prism <span>local model rendering</span></div><div className="window-actions"><button onClick={() => document.documentElement.classList.toggle("light")} title="Toggle theme"><Sun size={15}/></button><button onClick={() => setDockOpen((value) => !value)} title="Toggle settings dock"><PanelRight size={15}/></button></div></header>
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-top"><button className="project-switcher"><span>{activeProject?.name ?? "No project"}</span><ChevronDown size={14}/></button><button className="icon-button" onClick={() => void createProject()} title="New project"><FolderPlus size={16}/></button></div>
        <button className="import-button" onClick={() => void importModel()}><Import size={15}/> Import model</button>
        <div className="tree">{projects.length === 0 && <EmptySidebar onCreate={createProject}/>} {projects.map((project) => <ProjectTree key={project.id} project={project} activeProjectId={activeProjectId} activeModelId={activeModelId} onSelectProject={() => { setActiveProjectId(project.id); setActiveModelId(project.models[0]?.id ?? null); }} onSelectModel={(id) => { setActiveProjectId(project.id); setActiveModelId(id); }}/>)}</div>
        <div className="sidebar-foot"><button onClick={() => setSettingsOpen(true)}><Settings2 size={15}/> App settings</button><p>{blender}</p></div>
      </aside>
      <main className="workspace">{activeModel ? <Viewport model={activeModel} rendering={rendering} onPreview={() => void render(true)} /> : <Welcome onImport={importModel} onCreate={createProject}/>}</main>
      {dockOpen && <SettingsDock model={activeModel} disabled={rendering} onUpdate={updateSettings} onPersist={() => void persist()} onPreview={() => void render(true)} onExport={() => void render(false)} onCopyPreset={() => void copyPreset()} onImportPreset={() => void importPreset()}/>} 
    </div>
    {settingsOpen && <AppSettings blender={blender} onClose={() => setSettingsOpen(false)}/>} {toast && <div className={`toast ${toast.tone}`}><span>{toast.text}</span><button onClick={() => setToast(null)}><X size={14}/></button></div>}
  </div>;
}

function EmptySidebar({ onCreate }: { onCreate: () => void }): React.JSX.Element { return <div className="empty-side"><Folder size={24}/><p>No render projects yet.</p><button onClick={onCreate}>Create project</button></div>; }
function ProjectTree({ project, activeProjectId, activeModelId, onSelectProject, onSelectModel }: { project: Project; activeProjectId: string | null; activeModelId: string | null; onSelectProject: () => void; onSelectModel: (id: string) => void }): React.JSX.Element { const [open, setOpen] = React.useState(true); return <section className="project-tree"><button className={`tree-project ${project.id === activeProjectId ? "selected" : ""}`} onClick={() => { setOpen(!open); onSelectProject(); }}>{open ? <ChevronDown size={14}/> : <ChevronRight size={14}/>}<Folder size={14}/><span>{project.name}</span><small>{project.models.length}</small></button>{open && <div className="tree-models">{project.models.map((model) => <button key={model.id} className={model.id === activeModelId ? "active-model" : ""} onClick={() => onSelectModel(model.id)}><PackagePlus size={14}/><span>{model.name}</span></button>)}{project.models.length === 0 && <p>Import a model to begin.</p>}</div>}</section>; }
function Welcome({ onImport, onCreate }: { onImport: () => void; onCreate: () => void }): React.JSX.Element { return <section className="welcome"><div className="prism-mark"><Sparkles size={48}/></div><h1>Make a clean render of any model.</h1><p>Prism imports with Blender, gives you a simple studio setup, then exports the image locally.</p><div><button className="primary" onClick={onCreate}><FolderPlus size={16}/> New project</button><button className="secondary" onClick={onImport}><Import size={16}/> Import model</button></div><small>`.blend`, `.fbx`, `.obj`, `.glb`, `.gltf`, `.stl`, USD, and Blender-enabled import formats.</small></section>; }
function Viewport({ model, rendering, onPreview }: { model: PrismModel; rendering: boolean; onPreview: () => void }): React.JSX.Element { const source = model.previewPath ? `${convertFileSrc(model.previewPath)}?v=${encodeURIComponent(model.previewPath)}` : null; return <><div className="viewport-toolbar"><div><Camera size={15}/><span>{model.name}</span><small>{model.settings.width} × {model.settings.height}</small></div><button className="primary small" disabled={rendering} onClick={onPreview}>{rendering ? <LoaderCircle className="spin" size={15}/> : <Play size={15}/>} {rendering ? "Rendering" : "Render preview"}</button></div><div className="viewport">{source ? <img src={source} alt={`Rendered ${model.name}`}/> : <div className="empty-preview"><Sparkles size={34}/><p>Your model preview will appear here.</p><button className="primary" disabled={rendering} onClick={onPreview}>Render preview</button></div>}</div></>; }
function Field({ label, value, min, max, step = 1, onChange }: { label: string; value: number; min: number; max: number; step?: number; onChange: (value: number) => void }): React.JSX.Element { return <label className="field"><span>{label}<output>{Number(value.toFixed(2))}</output></span><input type="range" min={min} max={max} step={step} value={value} onChange={(event) => onChange(Number(event.target.value))}/></label>; }
function SettingsDock({ model, disabled, onUpdate, onPersist, onPreview, onExport, onCopyPreset, onImportPreset }: { model: PrismModel | null; disabled: boolean; onUpdate: (patch: Partial<RenderSettings>) => void; onPersist: () => void; onPreview: () => void; onExport: () => void; onCopyPreset: () => void; onImportPreset: () => void }): React.JSX.Element { if (!model) return <aside className="dock"><div className="dock-heading"><SlidersHorizontal size={16}/><span>Render settings</span></div><p className="dock-empty">Select a model to edit its studio settings.</p></aside>; const s = model.settings; return <aside className="dock"><div className="dock-heading"><SlidersHorizontal size={16}/><span>Render settings</span><button onClick={onPersist} title="Save settings"><Copy size={14}/></button></div><div className="settings-scroll"><Section title="Output"><div className="form-row"><label>Width<input type="number" value={s.width} min="64" max="8192" onChange={(e) => onUpdate({ width: Number(e.target.value) })}/></label><label>Height<input type="number" value={s.height} min="64" max="8192" onChange={(e) => onUpdate({ height: Number(e.target.value) })}/></label></div><label className="select-label">Format<select value={s.format} onChange={(e) => onUpdate({ format: e.target.value })}>{formatChoices.map((format) => <option key={format}>{format}</option>)}</select></label><Toggle label="Transparent background" checked={s.transparent} onChange={(transparent) => onUpdate({ transparent })}/></Section><Section title="Camera"><Field label="Orbit" value={s.orbit[0]} min={-180} max={180} onChange={(yaw) => onUpdate({ orbit: [yaw, s.orbit[1]] })}/><Field label="Elevation" value={s.orbit[1]} min={-80} max={80} onChange={(pitch) => onUpdate({ orbit: [s.orbit[0], pitch] })}/><Field label="Focal length" value={s.focalLength} min={18} max={120} onChange={(focalLength) => onUpdate({ focalLength })}/><Field label="Framing" value={s.framing} min={0.7} max={3} step={0.05} onChange={(framing) => onUpdate({ framing })}/></Section><Section title="Lighting"><Field label="Key light" value={s.keyStrength} min={0} max={4000} step={25} onChange={(keyStrength) => onUpdate({ keyStrength })}/><Field label="Fill light" value={s.fillStrength} min={0} max={2000} step={25} onChange={(fillStrength) => onUpdate({ fillStrength })}/><Field label="World light" value={s.worldStrength} min={0} max={3} step={0.05} onChange={(worldStrength) => onUpdate({ worldStrength })}/><Toggle label="Cavity / ambient occlusion" checked={s.cavity} onChange={(cavity) => onUpdate({ cavity })}/>{s.cavity && <Field label="Cavity strength" value={s.cavityStrength} min={0} max={1} step={0.05} onChange={(cavityStrength) => onUpdate({ cavityStrength })}/>}</Section><Section title="Presets"><div className="preset-buttons"><button onClick={onCopyPreset}><Copy size={14}/> Copy code</button><button onClick={onImportPreset}><Import size={14}/> Import code</button></div></Section></div><div className="dock-actions"><button className="secondary" disabled={disabled} onClick={onPreview}><Play size={15}/> Preview</button><button className="primary" disabled={disabled} onClick={onExport}><ImageDown size={15}/> Export</button></div></aside>; }
function Section({ title, children }: { title: string; children: React.ReactNode }): React.JSX.Element { const [open, setOpen] = React.useState(true); return <section className="setting-section"><button className="section-title" onClick={() => setOpen(!open)}>{open ? <ChevronDown size={14}/> : <ChevronRight size={14}/>} {title}</button>{open && <div className="section-body">{children}</div>}</section>; }
function Toggle({ label, checked, onChange }: { label: string; checked: boolean; onChange: (checked: boolean) => void }): React.JSX.Element { return <label className="toggle"><span>{label}</span><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)}/><i/></label>; }
function AppSettings({ blender, onClose }: { blender: string; onClose: () => void }): React.JSX.Element { return <div className="modal-backdrop"><section className="settings-modal"><header><div><Settings2 size={18}/><h2>Prism settings</h2></div><button onClick={onClose}><X size={17}/></button></header><div className="settings-modal-content"><h3>Rendering backend</h3><p>Prism uses Blender installed on this computer. Model files and renders stay local.</p><code>{blender}</code><h3>Theme</h3><p>Prism starts with the Luar dark theme. Use the sun icon in the title bar to switch to its light counterpart.</p><h3>About</h3><p>Prism is GPL-3.0-or-later and includes an adapted Blender workflow based on modelrender by OttoHatt.</p></div></section></div>; }

createRoot(document.getElementById("root")!).render(<React.StrictMode><App/></React.StrictMode>);

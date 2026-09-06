use serde::{Deserialize, Serialize};
use std::{fs, path::{Path, PathBuf}, process::Command};
use tauri::{AppHandle, Manager};
use uuid::Uuid;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RenderSettings {
    width: u32, height: u32, format: String, transparent: bool, background: [f32; 3],
    orbit: [f32; 2], focal_length: f32, framing: f32, key_strength: f32,
    fill_strength: f32, world_strength: f32, cavity: bool, cavity_strength: f32,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Model { id: String, name: String, folder: String, source_path: String, preview_path: Option<String>, settings: RenderSettings }

#[derive(Clone, Serialize, Deserialize)]
struct NamedPreset { name: String, settings: RenderSettings }

#[derive(Clone, Serialize, Deserialize)]
struct Project { id: String, name: String, folders: Vec<String>, models: Vec<Model>, #[serde(default)] presets: Vec<NamedPreset> }

fn defaults() -> RenderSettings { RenderSettings { width: 1024, height: 1024, format: "PNG".into(), transparent: false, background: [0.055, 0.063, 0.086], orbit: [35.0, 25.0], focal_length: 55.0, framing: 1.45, key_strength: 1100.0, fill_strength: 260.0, world_strength: 1.0, cavity: true, cavity_strength: 0.65 } }
fn root(app: &AppHandle) -> Result<PathBuf, String> { let path = app.path().app_data_dir().map_err(|e| e.to_string())?.join("projects"); fs::create_dir_all(&path).map_err(|e| e.to_string())?; Ok(path) }
fn manifest(app: &AppHandle, id: &str) -> Result<PathBuf, String> { Ok(root(app)?.join(id).join("prism.json")) }
fn load(app: &AppHandle, id: &str) -> Result<Project, String> { serde_json::from_str(&fs::read_to_string(manifest(app, id)?).map_err(|e| e.to_string())?).map_err(|e| e.to_string()) }
fn save(app: &AppHandle, project: &Project) -> Result<(), String> { let path = manifest(app, &project.id)?; fs::write(path, serde_json::to_string_pretty(project).map_err(|e| e.to_string())?).map_err(|e| e.to_string()) }
fn global_presets(app: &AppHandle) -> Result<PathBuf, String> { Ok(app.path().app_data_dir().map_err(|e| e.to_string())?.join("global-presets.json")) }

#[tauri::command]
fn list_projects(app: AppHandle) -> Result<Vec<Project>, String> {
    let mut projects = Vec::new();
    for entry in fs::read_dir(root(&app)?).map_err(|e| e.to_string())? { let path = entry.map_err(|e| e.to_string())?.path().join("prism.json"); if path.exists() { if let Ok(project) = serde_json::from_str::<Project>(&fs::read_to_string(path).map_err(|e| e.to_string())?) { projects.push(project); } } }
    Ok(projects)
}

#[tauri::command]
fn create_project(app: AppHandle, name: String) -> Result<Project, String> {
    let project = Project { id: Uuid::new_v4().to_string(), name, folders: vec!["Models".into()], models: vec![], presets: vec![] };
    fs::create_dir_all(root(&app)?.join(&project.id).join("models")).map_err(|e| e.to_string())?; save(&app, &project)?; Ok(project)
}

#[tauri::command]
fn import_model(app: AppHandle, project_id: String, input: String) -> Result<Model, String> {
    let mut project = load(&app, &project_id)?; let source = PathBuf::from(input); if !source.is_file() { return Err("The selected model file no longer exists.".into()); }
    let name = source.file_stem().and_then(|value| value.to_str()).unwrap_or("Model").to_string(); let extension = source.extension().and_then(|value| value.to_str()).unwrap_or("");
    let id = Uuid::new_v4().to_string(); let copied = root(&app)?.join(&project_id).join("models").join(format!("{id}.{extension}")); fs::copy(&source, &copied).map_err(|e| e.to_string())?;
    let model = Model { id, name, folder: "Models".into(), source_path: copied.to_string_lossy().to_string(), preview_path: None, settings: defaults() }; project.models.push(model.clone()); save(&app, &project)?; Ok(model)
}

#[tauri::command]
fn save_model_settings(app: AppHandle, project_id: String, model_id: String, settings: RenderSettings) -> Result<Model, String> {
    let mut project = load(&app, &project_id)?; let model = project.models.iter_mut().find(|entry| entry.id == model_id).ok_or("Model not found.")?; model.settings = settings; let value = model.clone(); save(&app, &project)?; Ok(value)
}

#[tauri::command]
fn save_preset(app: AppHandle, project_id: String, name: String, settings: RenderSettings, global: bool) -> Result<(), String> {
    let preset = NamedPreset { name, settings };
    if global {
        let path = global_presets(&app)?;
        let mut presets: Vec<NamedPreset> = if path.exists() { serde_json::from_str(&fs::read_to_string(&path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())? } else { vec![] };
        presets.retain(|entry| entry.name != preset.name);
        presets.push(preset);
        fs::write(path, serde_json::to_string_pretty(&presets).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    } else {
        let mut project = load(&app, &project_id)?;
        project.presets.retain(|entry| entry.name != preset.name);
        project.presets.push(preset);
        save(&app, &project)?;
    }
    Ok(())
}

#[tauri::command]
fn blender_status() -> Result<String, String> { Command::new("blender").arg("--version").output().map(|output| String::from_utf8_lossy(&output.stdout).lines().next().unwrap_or("Blender found").to_string()).map_err(|_| "Blender was not found on PATH. Set it up in Prism settings, then restart the app.".into()) }

#[tauri::command]
fn render_model(app: AppHandle, project_id: String, model_id: String, preview: bool) -> Result<String, String> {
    let mut project = load(&app, &project_id)?; let model = project.models.iter_mut().find(|entry| entry.id == model_id).ok_or("Model not found.")?; let dir = root(&app)?.join(&project_id).join("renders"); fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut settings = model.settings.clone(); if preview { settings.width = 640; settings.height = 640; settings.format = "PNG".into(); }
    let settings_path = dir.join(format!("{}.json", model.id)); fs::write(&settings_path, serde_json::to_string(&settings).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let suffix = match settings.format.as_str() { "JPEG" => "jpg", "WEBP" => "webp", "OPEN_EXR" => "exr", _ => "png" }; let output = dir.join(format!("{}-{}.{}", model.id, Uuid::new_v4(), suffix));
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().join("backend/prism_render.py");
    let result = Command::new("blender").args(["--background", "--python", script.to_str().ok_or("Invalid script path")?, "--", "--input", &model.source_path, "--output", output.to_str().ok_or("Invalid output path")?, "--settings", settings_path.to_str().ok_or("Invalid settings path")?]).output().map_err(|_| "Could not start Blender. Install Blender or add it to PATH.".to_string())?;
    if !result.status.success() { return Err(String::from_utf8_lossy(&result.stderr).lines().last().unwrap_or("Blender render failed.").to_string()); }
    model.preview_path = Some(output.to_string_lossy().to_string()); save(&app, &project)?; Ok(output.to_string_lossy().to_string())
}

pub fn run() { tauri::Builder::default().plugin(tauri_plugin_dialog::init()).invoke_handler(tauri::generate_handler![list_projects, create_project, import_model, save_model_settings, save_preset, blender_status, render_model]).run(tauri::generate_context!()).expect("Prism failed to start"); }

#!/usr/bin/env bash
set -euo pipefail

: "${WORKSPACE:=/workspace}"
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"
: "${RUN_JUPYTER:=0}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_TOKEN:?HF_TOKEN ist Pflicht (als Env in Runpod setzen)}"

LOG_DIR="$WORKSPACE/logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/entrypoint.log") 2>&1
echo "[ENTRY] $(date -u '+%F %T') UTC | WORKSPACE=$WORKSPACE | HF_REPO_ID=$HF_REPO_ID"

# venv vorbereiten
if [ ! -d "$WORKSPACE/venv" ]; then
  python3 -m venv "$WORKSPACE/venv"
fi
source "$WORKSPACE/venv/bin/activate"
python -m pip install --no-cache-dir -U pip wheel setuptools

# ComfyUI holen (falls fehlt)
if [ ! -d "$WORKSPACE/ComfyUI/.git" ]; then
  echo "[SETUP] clone ComfyUI …"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$WORKSPACE/ComfyUI"
fi

# Requirements ohne Torch (spart mehrere GB + vermeidet Konflikte)
REQ="$WORKSPACE/ComfyUI/requirements.txt"
REQ_F="$WORKSPACE/ComfyUI/requirements.filtered.txt"
if [ ! -f "$REQ_F" ]; then
  grep -viE '^(torch|torchvision|torchaudio|torchsde)\b' "$REQ" > "$REQ_F" || true
fi

# stabile libs + Restdeps
python -m pip install --no-cache-dir "huggingface_hub==0.35.3" "rich" "tqdm" "uvicorn[standard]" "fastapi"
python -m pip install --no-cache-dir -r "$REQ_F"
python -m pip install --no-cache-dir torchsde

# Modelle, Workflows, Custom Nodes von Hugging Face ziehen
echo "[PULL] HF-Bundle → ComfyUI-Struktur"
python - << 'PY'
import os, shutil
from pathlib import Path
from huggingface_hub import hf_hub_download, list_repo_files, login

hf_token = os.environ["HF_TOKEN"]
repo_id  = os.environ.get("HF_REPO_ID","Floorius/comfyui-model-bundle")
ws       = Path(os.environ.get("WORKSPACE","/workspace"))
croot    = ws/"ComfyUI"
models   = croot/"models"
paths = {
  "checkpoints": models/"checkpoints",
  "controlnet":  models/"controlnet",
  "loras":       models/"loras",
  "upscale":     models/"upscale_models",
  "faces":       models/"faces",
  "workflows":   croot/"workflows",
  "custom_nodes": croot/"custom_nodes",
}
for p in paths.values(): p.mkdir(parents=True, exist_ok=True)

login(token=hf_token, add_to_git_credential=False)

# Pflichtdateien (Modelle + Workflows)
required = [
  "checkpoints/sd_xl_base_1.0.safetensors",
  "checkpoints/sd_xl_refiner_1.0.safetensors",
  "checkpoints/RealVisXL_V4.0.safetensors",
  "checkpoints/juggernautXL_version2.safetensors",
  "checkpoints/diffusion_pytorch_model.safetensors",
  "checkpoints/ip-adapter-faceid-plusv2_sdxl.bin",
  "checkpoints/photomaker-v2.bin",
  "controlnet/control_v11p_sd15_openpose.pth",
  "upscale_models/4x-UltraSharp.pth",
  "faces/CodeFormer.pth",
  "loras/sdxl_photorealistic_slider_v1-0.safetensors",
  "loras/face_xl_v0_1.safetensors",
  "loras/pytorch_lora_weights.safetensors",
  "workflows/sdxl_ultrasharp_base.json",
  "workflows/sdxl_ultrasharp_extended.json",
  "workflows/sdxl_base_refiner_ultrasharp.json",
  "workflows/sdxl_extended_refiner_ultrasharp.json",
  "workflows/sdxl_refiner_only.json",
  "workflows/sdxl_base_refiner_ultrasharp_with_lora.json",
  "workflows/sdxl_extended_refiner_ultrasharp_with_lora.json",
]

def ensure(rel: str, dst: Path):
    if dst.exists(): return
    try:
        local = hf_hub_download(repo_id=repo_id, filename=rel, repo_type="model", token=hf_token)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(local, dst)
        print(f"[OK] {rel} -> {dst}")
    except Exception as e:
        print(f"[WARN] {rel} -> {e}")

# Pflichtdateien in passende Ordner legen
from pathlib import Path as P
for rel in required:
    base = P(rel).name
    if rel.startswith("checkpoints/"):    ensure(rel, paths["checkpoints"]/base)
    elif rel.startswith("controlnet/"):   ensure(rel, paths["controlnet"]/base)
    elif rel.startswith("loras/"):        ensure(rel, paths["loras"]/base)
    elif rel.startswith("upscale_models/"): ensure(rel, paths["upscale"]/base)
    elif rel.startswith("faces/"):        ensure(rel, paths["faces"]/base)
    elif rel.startswith("workflows/"):    ensure(rel, paths["workflows"]/P(rel).name)

# Alle custom_nodes/ aus HF (falls vorhanden) übernehmen (rekursiv)
files = list_repo_files(repo_id=repo_id, repo_type="model")
for f in files:
    if f.startswith("custom_nodes/") and not f.endswith("/"):
        rel = f
        dst = paths["custom_nodes"]/("/".join(f.split("/")[1:]))
        ensure(rel, dst)
PY

# ComfyUI starten
cd "$WORKSPACE/ComfyUI"
echo "[RUN] ComfyUI → 0.0.0.0:${COMFYUI_PORT}"
nohup bash -lc "python main.py --listen 0.0.0.0 --port ${COMFYUI_PORT} --enable-cors-header '*'" > "$LOG_DIR/comfyui.log" 2>&1 &

# Optional Jupyter
if [ "${RUN_JUPYTER}" = "1" ]; then
  echo "[RUN] Jupyter → 0.0.0.0:${JUPYTER_PORT}"
  python -m pip install --no-cache-dir jupyterlab
  nohup jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --NotebookApp.token='' > "$LOG_DIR/jupyter.log" 2>&1 &
fi

echo "[READY] Logs in $LOG_DIR"
tail -n +1 -f "$LOG_DIR"/comfyui.log

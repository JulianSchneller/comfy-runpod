#!/usr/bin/env bash
set -euo pipefail

: "${WORKSPACE:=/workspace}"
: "${COMFY_DIR:=${WORKSPACE}/ComfyUI}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"
: "${RUN_JUPYTER:=1}"                       # Jupyter default: AN (1)
: "${JUPYTER_TOKEN:=}"                      # leer = ohne Token
: "${HF_TOKEN:?Bitte HF_TOKEN als Env setzen}"

mkdir -p "${WORKSPACE}/logs"
LOG_DIR="${WORKSPACE}/logs"
exec > >(tee -a "$LOG_DIR/entrypoint.log") 2>&1
echo "[ENTRY] $(date -u '+%F %T') UTC | WS=${WORKSPACE} | HF_REPO_ID=${HF_REPO_ID} | RUN_JUPYTER=${RUN_JUPYTER}"

# ---------- venv: nutzt System-Site-Packages (kein Torch-Reinstall) ----------
if [ ! -d "${WORKSPACE}/venv" ]; then
  python3 -m venv --system-site-packages "${WORKSPACE}/venv"
fi
source "${WORKSPACE}/venv/bin/activate"
python -m pip install --no-cache-dir -U pip wheel setuptools

# ---------- ComfyUI holen/aktualisieren ----------
if [ ! -d "${COMFY_DIR}/.git" ]; then
  echo "[SETUP] clone ComfyUI …"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI "${COMFY_DIR}"
else
  echo "[SETUP] update ComfyUI …"
  git -C "${COMFY_DIR}" pull --ff-only || true
fi

# ---------- Requirements (Torch & Co. rausfiltern) ----------
REQ="${COMFY_DIR}/requirements.txt"
REQ_NOTORCH="${COMFY_DIR}/requirements_notorch.txt"
grep -viE '^(torch|torchaudio|torchvision|torchsde)\\b' "${REQ}" > "${REQ_NOTORCH}" || true

python - <<'PY'
import subprocess, sys
def pip(*args): subprocess.check_call([sys.executable,"-m","pip",*args])
# bewährte Versionen, um Resolver-Probleme zu vermeiden
pip("install","--no-cache-dir","huggingface_hub==0.35.3","rich","tqdm","uvicorn[standard]","fastapi")
# rest (ohne Torch), plus Jupyter & gradio
pip("install","--no-cache-dir","-r","/workspace/ComfyUI/requirements_notorch.txt")
pip("install","--no-cache-dir","jupyterlab==4.*","ipywidgets","gradio<5.47","tqdm","torchsde")
PY

# ---------- sicherstellen: Torch aus Base-Image vorhanden ----------
python - <<'PY'
import sys
import torch
print(f"[Torch] OK (kommt aus System-Site-Packages): {torch.__version__}")
PY

# ---------- HF-Assets -> symlinks (keine Duplikate) ----------
python - <<'PY'
import os, shutil
from pathlib import Path
from huggingface_hub import snapshot_download, login

ws = Path(os.environ.get("WORKSPACE","/workspace"))
repo_id = os.environ.get("HF_REPO_ID","Floorius/comfyui-model-bundle")
token = os.environ["HF_TOKEN"]

root  = ws/"hf_bundle"          # echter Download-Ordner
cui   = ws/"ComfyUI"
models = cui/"models"

mapping = {
  "checkpoints":    models/"checkpoints",
  "controlnet":     models/"controlnet",
  "faces":          models/"faces",
  "loras":          models/"loras",
  "upscale_models": models/"upscale_models",
  "workflows":      cui/"workflows",
  "custom_nodes":   cui/"custom_nodes",
}

for d in mapping.values():
    d.parent.mkdir(parents=True, exist_ok=True)

login(token=token, add_to_git_credential=False)
print(f"[HF] snapshot_download: {repo_id}")
snapshot_download(repo_id=repo_id, repo_type="model",
                  local_dir=str(root), local_dir_use_symlinks=True, token=token)

def ensure_link(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink() and dst.resolve() == src.resolve():
        return
    if dst.exists() and not dst.is_symlink():
        # vorhandene Dateien in Zielordner – nicht löschen; Einzeldateien verlinken
        return
    if dst.exists(): dst.unlink()
    if not dst.exists():
        dst.symlink_to(src, target_is_directory=True)
        print(f"[LINK] {dst} -> {src}")

for k, dst in mapping.items():
    src = root/k
    src.mkdir(parents=True, exist_ok=True)
    ensure_link(src, dst)

print("[HF] Links bereit.")
PY

# ---------- Services starten ----------
COMFY_LOG="${LOG_DIR}/comfyui.log"
JUPY_LOG="${LOG_DIR}/jupyter.log"
cd "${COMFY_DIR}"

echo "[RUN] ComfyUI -> 0.0.0.0:${COMFYUI_PORT}"
nohup python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" --enable-cors-header '*' >"${COMFY_LOG}" 2>&1 &

if [ "${RUN_JUPYTER}" = "1" ]; then
  if [ -n "${JUPYTER_TOKEN}" ]; then
    AUTH="--ServerApp.token=${JUPYTER_TOKEN}"
  else
    AUTH="--ServerApp.token=''"
  fi
  echo "[RUN] Jupyter -> 0.0.0.0:${JUPYTER_PORT}"
  nohup jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser ${AUTH} >"${JUPY_LOG}" 2>&1 &
fi

echo "[READY] Logs:"
echo "  ${COMFY_LOG}"
echo "  ${JUPY_LOG}"
tail -n +200 -f "${COMFY_LOG}"

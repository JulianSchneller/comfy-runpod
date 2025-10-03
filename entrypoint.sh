#!/usr/bin/env bash
set -euo pipefail

# ---------- ENV ----------
: "${WORKSPACE:=/workspace}"
: "${COMFY_DIR:=${WORKSPACE}/ComfyUI}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"   # HF nur als Asset-Storage
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"
: "${RUN_JUPYTER:=0}"                               # 1 = Jupyter mitstarten
: "${HF_TOKEN:?Bitte HF_TOKEN als Env mitgeben!}"

mkdir -p "${WORKSPACE}/logs"
LOG_DIR="${WORKSPACE}/logs"
exec > >(tee -a "$LOG_DIR/entrypoint.log") 2>&1
echo "[ENTRY] $(date -u '+%F %T') UTC | WORKSPACE=${WORKSPACE} | HF_REPO_ID=${HF_REPO_ID}"

# ---------- venv ----------
if [ ! -d "${WORKSPACE}/venv" ]; then
  python3 -m venv "${WORKSPACE}/venv"
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

# ---------- Requirements (ohne torch/vision/audio/torchsde) ----------
REQ="${COMFY_DIR}/requirements.txt"
REQ_NOTORCH="${COMFY_DIR}/requirements_notorch.txt"
grep -viE '^(torch|torchaudio|torchvision|torchsde)\b' "${REQ}" > "${REQ_NOTORCH}" || true

# ---------- Stabile Libs (kein Torch-Reinstall!) ----------
python - <<'PY'
import subprocess, sys
def pip(*args): subprocess.check_call([sys.executable,"-m","pip",*args])
pip("install","--no-cache-dir","-U","pip","setuptools","wheel")
# Bewährte Hub-Version – vermeidet >=0.39-Resolver-Probleme
pip("install","--no-cache-dir","huggingface_hub==0.35.3","rich","tqdm","uvicorn[standard]","fastapi")
PY

# ---------- Restabhängigkeiten + torchsde separat ----------
CONSTRAINTS="${WORKSPACE}/constraints.txt"
cat > "${CONSTRAINTS}" <<'TXT'
huggingface_hub==0.35.3
numpy<2.4
TXT

for i in 1 2 3; do
  if pip install --no-cache-dir -r "${REQ_NOTORCH}" -c "${CONSTRAINTS}" && \
     pip install --no-cache-dir "jupyterlab==4.*" "ipywidgets" "gradio<5.47" "tqdm" && \
     pip install --no-cache-dir torchsde; then
    break
  fi
  echo "   [pip] Versuch ${i} fehlgeschlagen – retry in 5s …"; sleep 5
done

# ---------- Torch aus Base-Image prüfen ----------
python - <<'PY'
import sys
try:
    import torch
    print(f"[Torch] OK: {torch.__version__}")
except Exception as e:
    print("[Torch] FEHLT – bitte Base-Image mit torch 2.4.0 CUDA12.1 nutzen!", file=sys.stderr)
    sys.exit(1)
PY

# ---------- HF-Assets → korrekte ComfyUI-Ordner ----------
HF_DST="${WORKSPACE}/hf_bundle"
python - <<'PY'
import os, shutil
from pathlib import Path
from huggingface_hub import snapshot_download, login, list_repo_files

repo_id = os.environ.get("HF_REPO_ID","Floorius/comfyui-model-bundle")
hf_token = os.environ["HF_TOKEN"]
ws   = Path(os.environ.get("WORKSPACE","/workspace"))
root = ws/"hf_bundle"
cui  = ws/"ComfyUI"
models = cui/"models"

paths = {
  "checkpoints":    models/"checkpoints",
  "controlnet":     models/"controlnet",
  "faces":          models/"faces",
  "loras":          models/"loras",
  "upscale_models": models/"upscale_models",
  "workflows":      cui/"workflows",
  "custom_nodes":   cui/"custom_nodes",
}
for p in paths.values(): p.mkdir(parents=True, exist_ok=True)

login(token=hf_token, add_to_git_credential=False)
print(f"[HF] snapshot_download: {repo_id} …")
snapshot_download(repo_id=repo_id, repo_type="model", local_dir=str(root), local_dir_use_symlinks=False, token=hf_token)

def copytree(src: Path, dst: Path):
    if not src.exists(): return
    for r, _, files in os.walk(src):
        r = Path(r)
        rel = r.relative_to(src)
        out = dst/rel
        out.mkdir(parents=True, exist_ok=True)
        for f in files:
            s = r/f; t = out/f
            if not t.exists():
                shutil.copy2(s, t); print(f"[OK] {s.relative_to(src)}")

for k, d in paths.items():
    copytree(root/k, d)
print("[HF] Deploy done.")
PY

# ---------- Start Services ----------
COMFY_LOG="${LOG_DIR}/comfyui.log"
JUPY_LOG="${LOG_DIR}/jupyter.log"

cd "${COMFY_DIR}"
echo "[RUN] ComfyUI → 0.0.0.0:${COMFYUI_PORT}"
nohup python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" --enable-cors-header '*' >"${COMFY_LOG}" 2>&1 &

if [ "${RUN_JUPYTER}" = "1" ]; then
  echo "[RUN] Jupyter → 0.0.0.0:${JUPYTER_PORT}"
  nohup jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser --NotebookApp.token='' >"${JUPY_LOG}" 2>&1 &
fi

echo "[READY] Logs:"
echo "  ${COMFY_LOG}"
echo "  ${JUPY_LOG}"
tail -n +200 -f "${COMFY_LOG}"

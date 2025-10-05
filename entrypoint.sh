#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# ---- ENV / Defaults ----
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="$WORKSPACE/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
LOG_DIR="$WORKSPACE/logs"

HF_REPO_ID="${HF_REPO_ID:-}"                         # z.B. Floorius/comfyui-model-bundle
HF_TOKEN="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"   # Token auch aus HUGGINGFACE_HUB_TOKEN lesen
HF_BRANCH="${HF_BRANCH:-main}"

COMFYUI_PORT="${COMFYUI_PORT:-8188}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
RUN_JUPYTER="${RUN_JUPYTER:-1}"                      # 1 = Jupyter an
JUPYTER_TOKEN="${JUPYTER_TOKEN:-${JUPYTER_PASSWORD:-}}"

NSFW_BYPASS="${NSFW_BYPASS:-1}"                      # 1 = optionaler Bypass aktiv

# HF Cache in Workspace, nicht in /root
export HF_HOME="${WORKSPACE}/.cache/huggingface"
export HUGGINGFACE_HUB_CACHE="${HF_HOME}"
mkdir -p "$HF_HOME" "$LOG_DIR"

# ---- ComfyUI klonen (idempotent) ----
if [[ ! -d "$COMFY_DIR/.git" ]]; then
  log "Cloning ComfyUI …"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  log "ComfyUI vorhanden – kein Clone."
fi

# ---- requirements.txt säubern (keine Beispiel-Workflows) ----
if [[ -f "$COMFY_DIR/requirements.txt" ]] && grep -q "comfyui-workflow-templates" "$COMFY_DIR/requirements.txt"; then
  log "Patch requirements.txt → entferne comfyui-workflow-templates"
  sed -i '/comfyui-workflow-templates/d' "$COMFY_DIR/requirements.txt"
fi

# ---- Python-Requirements (best effort) ----
log "Install Python packages …"
python - <<'PY' || true
import subprocess, sys, os
# pip tooling + aktuelles huggingface_hub
subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","--upgrade",
                "pip","wheel","setuptools","huggingface_hub>=0.35.0"], check=False)
req = os.path.join(os.environ.get("COMFY_DIR","/workspace/ComfyUI"), "requirements.txt")
if os.path.exists(req):
    subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","-r", req], check=False)
# manche KSampler erwarten torchsde
try:
    import importlib; importlib.import_module("torchsde")
except Exception:
    subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","torchsde"], check=False)
PY

# ---- Zielordner in ComfyUI (idempotent) ----
mkdir -p "$MODELS_DIR"/{checkpoints,loras,controlnet,upscale_models,faces,vae,clip_vision,style_models,embeddings,diffusers,vae_approx}
mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/custom_nodes" "$COMFY_DIR/web/extensions"

# ---- Optionaler NSFW-Bypass (defensiv, no-op wenn Muster nicht existieren) ----
if [[ "$NSFW_BYPASS" == "1" ]]; then
  log "NSFW bypass aktiv."
  set +e
  mapfile -t _BN < <(grep -RIl --include="*.py" "block_nsfw" "$COMFY_DIR" 2>/dev/null || true)
  [[ ${#_BN[@]} -gt 0 ]] && sed -i 's/block_nsfw[[:space:]]*:[[:space:]]*Optional\[bool\][[:space:]]*=[[:space:]]*None/block_nsfw: Optional[bool] = False/g' "${_BN[@]}" 2>/dev/null
  [[ ${#_BN[@]} -gt 0 ]] && sed -i 's/block_nsfw=None/block_nsfw=False/g' "${_BN[@]}" 2>/dev/null
  mapfile -t _SC < <(grep -RIl --include="*.py" "safety_checker[[:space:]]*=" "$COMFY_DIR" 2>/dev/null || true)
  [[ ${#_SC[@]} -gt 0 ]] && sed -i 's/safety_checker[[:space:]]*=[[:space:]]*safety_checker/safety_checker=None/g' "${_SC[@]}" 2>/dev/null
  set -e
else
  log "NSFW bypass deaktiviert (NSFW_BYPASS!=1)."
fi

# ==== HF Direct Download – pro Datei (robust & idempotent) ====
download_all_from_hf() {
  if [[ -z "${HF_REPO_ID}" || -z "${HF_TOKEN}" ]]; then
    log "HF-Download übersprungen (HF_REPO_ID/HF_TOKEN fehlen)."
    return
  fi

  python - <<'PY'
import os, shutil
from huggingface_hub import HfApi, hf_hub_download, login

def human(n):
    u=["B","KB","MB","GB","TB"]; i=0
    while n>=1024 and i<len(u)-1: n/=1024; i+=1
    return f"{n:.2f} {u[i]}"

repo   = os.environ.get("HF_REPO_ID","")
token  = os.environ.get("HF_TOKEN","")
work   = os.environ.get("WORKSPACE","/workspace")
comfy  = os.path.join(work,"ComfyUI")
models = os.path.join(comfy,"models")
login(token=token, add_to_git_credential=False)
api = HfApi()

MAP = {
  "checkpoints":    os.path.join(models,"checkpoints"),
  "loras":          os.path.join(models,"loras"),
  "controlnet":     os.path.join(models,"controlnet"),
  "upscale_models": os.path.join(models,"upscale_models"),
  "faces":          os.path.join(models,"faces"),
  "vae":            os.path.join(models,"vae"),
}
files = api.list_repo_files(repo_id=repo, repo_type="model")
print(f"[INFO] Dateien im Repo: {len(files)}")

cache = "/tmp/hf_cache_full"; os.makedirs(cache, exist_ok=True)
total_bytes = 0; m_cnt = 0; w_cnt = 0

def copy_to(dst, src):
    os.makedirs(dst, exist_ok=True)
    out = os.path.join(dst, os.path.basename(src))
    if os.path.exists(out) and os.path.getsize(out) == os.path.getsize(src):
        print(f"[SKIP] {os.path.basename(src)}")
        return 0
    shutil.copy2(src, out)
    return os.path.getsize(out)

# Modelle
for f in files:
    sub = f.split("/",1)[0] if "/" in f else ""
    if sub in MAP and not f.endswith("/"):
        try:
            p = hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                                local_dir=cache, local_dir_use_symlinks=False)
            total_bytes += copy_to(MAP[sub], p); m_cnt += 1
            print(f"[OK]  {f}")
        except Exception as e:
            print(f"[ERR] {f} -> {e}")

# Workflows
w_dst = os.path.join(comfy,"user","default","workflows")
os.makedirs(w_dst, exist_ok=True)
for f in files:
    if f.startswith("workflows/") and f.lower().endswith(".json"):
        try:
            p = hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                                local_dir=cache, local_dir_use_symlinks=False)
            total_bytes += copy_to(w_dst, p); w_cnt += 1
            print(f"[WF]  {f}")
        except Exception as e:
            print(f"[ERR] {f} -> {e}")

print(f"[SUMMARY] Geladen: {m_cnt} Modelle, {w_cnt} Workflows, Gesamt: {human(total_bytes)}")
PY
}

# Laden (falls Token & Repo gesetzt)
download_all_from_hf

# Web-Extensions VOR dem Exec aktualisieren
if [[ -n "${HF_REPO_ID}" && -n "${HF_TOKEN}" ]]; then
  log "Aktualisiere web_extensions …"
  python - <<'PY' || true
import os, shutil
from huggingface_hub import HfApi, hf_hub_download, login
repo=os.environ.get("HF_REPO_ID","")
token=os.environ.get("HF_TOKEN","")
base=os.environ.get("WORKSPACE","/workspace")
dst=os.path.join(base,"ComfyUI","web","extensions")
os.makedirs(dst, exist_ok=True)
login(token=token, add_to_git_credential=False)
api=HfApi()
files=api.list_repo_files(repo_id=repo, repo_type="model")
cache="/tmp/hf_cache_webext"; os.makedirs(cache, exist_ok=True)
n=0
for f in files:
    if f.startswith("web_extensions/") and not f.endswith("/"):
        p=hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                          local_dir=cache, local_dir_use_symlinks=False)
        rel=f.split("/",1)[1]
        out=os.path.join(dst, rel)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        if not os.path.exists(out) or os.path.getsize(out)!=os.path.getsize(p):
            shutil.copy2(p,out); n+=1
print(f"[entrypoint] web_extensions aktualisiert: {n} Dateien")
PY
else
  log "web_extensions: skip (HF_REPO_ID/HF_TOKEN fehlen)."
fi

# ---- Services starten ----
# Jupyter zuerst (optional, Hintergrund)
if [[ "${RUN_JUPYTER}" == "1" ]]; then
  log "Starte JupyterLab auf :${JUPYTER_PORT}"
  if [[ -n "$JUPYTER_TOKEN" ]]; then
    jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
      --ServerApp.token="$JUPYTER_TOKEN" --ServerApp.open_browser=False >"$LOG_DIR/jupyter.log" 2>&1 &
  else
    jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
      --ServerApp.token="" --ServerApp.password="" --ServerApp.open_browser=False >"$LOG_DIR/jupyter.log" 2>&1 &
  fi
else
  log "RUN_JUPYTER=0 – Jupyter deaktiviert."
fi

# ComfyUI im Vordergrund (saubere PID via exec)
log "Starte ComfyUI auf :${COMFYUI_PORT}"
cd "$COMFY_DIR"
# ==== ControlNet-Aux: BEGIN (install & ckpts & workflow patch) ====
set -e

: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=${WORKSPACE}/ComfyUI}"

CUSTOM_NODES="${COMFYUI_BASE}/custom_nodes"
AUX_DIR="${CUSTOM_NODES}/comfyui_controlnet_aux"
CKPT_DIR="${WORKSPACE}/annotators/ckpts"
ALT_CKPT_DIR_A="${WORKSPACE}/annotators/models"
ALT_CKPT_DIR_B="${WORKSPACE}/models/annotators/ckpts"
WF_DIR="${COMFYUI_BASE}/user/default/workflows"

echo "[entrypoint] controlnet_aux: setup…"
mkdir -p "${CUSTOM_NODES}"

if [ -d "${AUX_DIR}/.git" ]; then
  git -C "${AUX_DIR}" pull --ff-only || true
elif [ -d "${AUX_DIR}" ]; then
  echo "[entrypoint] controlnet_aux: exists (no git)."
else
  git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux.git "${AUX_DIR}"
fi

# Requirements
if [ -f "${AUX_DIR}/requirements.txt" ]; then
  python3 -m pip install --no-cache-dir -r "${AUX_DIR}/requirements.txt" || true
fi
# ONNXRuntime CPU/GPU (optional via CONTROLNET_AUX_USE_GPU=1)
if [ "${CONTROLNET_AUX_USE_GPU:-0}" = "1" ]; then
  python3 -m pip install --no-cache-dir onnxruntime-gpu==1.18.1 opencv-python==4.10.0.84 numpy einops timm || true
else
  python3 -m pip install --no-cache-dir onnxruntime==1.18.1       opencv-python==4.10.0.84 numpy einops timm || true
fi

# CKPT-Verlinkung
if [ ! -d "${CKPT_DIR}" ]; then
  if   [ -d "${ALT_CKPT_DIR_A}" ]; then
    mkdir -p "$(dirname "${CKPT_DIR}")"; ln -s "${ALT_CKPT_DIR_A}" "${CKPT_DIR}" 2>/dev/null || true
  elif [ -d "${ALT_CKPT_DIR_B}" ]; then
    mkdir -p "$(dirname "${CKPT_DIR}")"; ln -s "${ALT_CKPT_DIR_B}" "${CKPT_DIR}" 2>/dev/null || true
  else
    echo "[entrypoint] ⚠️ keine Annotator-CKPTs gefunden (optional)."
  fi
fi

if [ -d "${CKPT_DIR}" ]; then
  echo "[entrypoint] controlnet_aux: CKPTs unter ${CKPT_DIR}:"
  (ls -1 "${CKPT_DIR}" 2>/dev/null || true) | sed 's/^/  - /'
fi

# Workflows patchen: neue Klassennamen
if [ -d "${WF_DIR}" ]; then
  echo "[entrypoint] controlnet_aux: patch workflows in ${WF_DIR}…"
  grep -RIl 'controlnet_aux\.OpenPosePreprocessor\|controlnet_aux\.DwposePreprocessor' "${WF_DIR}" 2>/dev/null \
  | xargs -r sed -i \
      -e 's/controlnet_aux\.OpenPosePreprocessor/controlnet_aux.OpenposePreprocessor/g' \
      -e 's/controlnet_aux\.DwposePreprocessor/controlnet_aux.DWPosePreprocessor/g'
fi

echo "[entrypoint] controlnet_aux: OK."
# ==== ControlNet-Aux: END ====
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >"$LOG_DIR/comfyui.log" 2>&1






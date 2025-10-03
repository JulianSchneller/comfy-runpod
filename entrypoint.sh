#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# ---- ENV / Defaults ----
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="$WORKSPACE/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
LOG_DIR="$WORKSPACE/logs"

HF_REPO_ID="${HF_REPO_ID:-}"     # z.B. Floorius/comfyui-model-bundle
HF_TOKEN="${HF_TOKEN:-}"

COMFYUI_PORT="${COMFYUI_PORT:-8188}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
RUN_JUPYTER="${RUN_JUPYTER:-1}"        # 1 = Jupyter an
JUPYTER_TOKEN="${JUPYTER_TOKEN:-${JUPYTER_PASSWORD:-}}"  # optional

mkdir -p "$LOG_DIR"

# ---- ComfyUI klonen (idempotent) ----
if [[ ! -d "$COMFY_DIR/.git" ]]; then
  log "Cloning ComfyUI …"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  log "ComfyUI vorhanden – kein Clone."
fi

# ---- requirements.txt säubern (keine Beispiel-Workflows) ----
if grep -q "comfyui-workflow-templates" "$COMFY_DIR/requirements.txt"; then
  log "Patch requirements.txt → entferne comfyui-workflow-templates"
  sed -i '/comfyui-workflow-templates/d' "$COMFY_DIR/requirements.txt"
fi

# ---- Python-Requirements (best effort) ----
log "Install ComfyUI requirements …"
python -m pip install --no-cache-dir --upgrade pip wheel setuptools >>"$LOG_DIR/pip.log" 2>&1 || true
python -m pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
# Falls torchsde fehlt (manche KSampler brauchen es)
python - <<'PY' || true
import importlib, sys
try:
    importlib.import_module("torchsde")
except Exception:
    import subprocess
    subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","torchsde"], check=False)
PY

# ---- Zielordner in ComfyUI (idempotent) ----
mkdir -p "$MODELS_DIR"/{checkpoints,loras,controlnet,upscale_models,faces,vae,clip_vision,style_models,embeddings,diffusers,vae_approx}
mkdir -p "$COMFY_DIR/user/default/workflows"
mkdir -p "$COMFY_DIR/custom_nodes"

# ---- HF-Sync: nur vorhandene Ordner kopieren ----
sync_dir(){
  local SRC="$1" DST="$2"
  if [[ -d "$SRC" ]]; then
    mkdir -p "$DST"
    # --delete verhindert Ansammlungen; --whole-file vermeidet tmp-Duplikate; --prune-empty-dirs hält sauber
    rsync -a --delete --prune-empty-dirs "$SRC"/ "$DST"/
    log "Synced $(basename "$SRC") → $DST"
  fi
}

if [[ -n "$HF_REPO_ID" ]]; then
  HF_DST="$WORKSPACE/hf_sync"
  if [[ ! -d "$HF_DST/.git" ]]; then
    log "Clone HF repo: $HF_REPO_ID"
    if [[ -n "$HF_TOKEN" ]]; then
      GIT_LFS_SKIP_SMUDGE=1 git clone --depth=1 "https://user:${HF_TOKEN}@huggingface.co/${HF_REPO_ID}" "$HF_DST" || log "WARN: HF clone failed."
    else
      GIT_LFS_SKIP_SMUDGE=1 git clone --depth=1 "https://huggingface.co/${HF_REPO_ID}" "$HF_DST" || log "WARN: HF clone failed."
    fi
  else
    log "Update HF repo …"
    git -C "$HF_DST" pull --ff-only || true
  fi

  if [[ -d "$HF_DST" ]]; then
    sync_dir "$HF_DST/checkpoints"    "$MODELS_DIR/checkpoints"
    sync_dir "$HF_DST/loras"          "$MODELS_DIR/loras"
    sync_dir "$HF_DST/controlnet"     "$MODELS_DIR/controlnet"
    sync_dir "$HF_DST/upscale_models" "$MODELS_DIR/upscale_models"
    sync_dir "$HF_DST/faces"          "$MODELS_DIR/faces"
    sync_dir "$HF_DST/vae"            "$MODELS_DIR/vae"
    # Custom Nodes + Workflows (nur .json) – keine Dubletten
    if [[ -d "$HF_DST/custom_nodes" ]]; then
      rsync -a "$HF_DST/custom_nodes"/ "$COMFY_DIR/custom_nodes"/
      log "Synced custom_nodes"
    fi
    if [[ -d "$HF_DST/workflows" ]]; then
      mkdir -p "$COMFY_DIR/user/default/workflows"
      rsync -a --include='*/' --include='*.json' --exclude='*' "$HF_DST/workflows"/ "$COMFY_DIR/user/default/workflows"/
      log "Synced workflows → user/default/workflows"
    fi
  fi
else
  log "HF_REPO_ID leer – HF-Sync übersprungen."
fi

# ---- Services starten ----
# Jupyter zuerst (optional, Hintergrund)
if [[ "${RUN_JUPYTER}" == "1" ]]; then
  log "Starte JupyterLab auf :${JUPYTER_PORT}"
  if [[ -n "$JUPYTER_TOKEN" ]]; then
    jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root           --ServerApp.token="$JUPYTER_TOKEN" --ServerApp.open_browser=False >"$LOG_DIR/jupyter.log" 2>&1 &
  else
    jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root           --ServerApp.token="" --ServerApp.password="" --ServerApp.open_browser=False >"$LOG_DIR/jupyter.log" 2>&1 &
  fi
else
  log "RUN_JUPYTER=0 – Jupyter deaktiviert."
fi

# ComfyUI (Vordergrund, via exec = saubere PID)
log "Starte ComfyUI auf :${COMFYUI_PORT}"
cd "$COMFY_DIR"
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >"$LOG_DIR/comfyui.log" 2>&1

#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[$(date -u +'%F %T')] $*"; }

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="$WORKSPACE/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"

HF_REPO_ID="${HF_REPO_ID:-}"     # z.B. Floorius/comfyui-model-bundle
HF_TOKEN="${HF_TOKEN:-}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_TOKEN="${JUPYTER_TOKEN:-${JUPYTER_PASSWORD:-}}"

log "== Setup =="

# Verzeichnisstruktur für Modelle sicherstellen
mkdir -p "$MODELS_DIR"/{checkpoints,loras,controlnet,upscale_models,faces,vae,clip_vision,style_models,embeddings,diffusers,vae_approx}

# ComfyUI klonen (falls fehlt)
if [ ! -d "$COMFY_DIR/.git" ]; then
  log "Cloning ComfyUI …"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
fi

# Unerwünschtes Workflow-Paket entfernen (sonst kommen viele Beispiel-Workflows rein)
if grep -q "comfyui-workflow-templates" "$COMFY_DIR/requirements.txt"; then
  log "Patching requirements.txt (remove comfyui-workflow-templates) …"
  sed -i '/comfyui-workflow-templates/d' "$COMFY_DIR/requirements.txt"
fi

# Python-Abhängigkeiten installieren (best effort)
log "Install ComfyUI requirements …"
python -m pip install --upgrade pip wheel setuptools
python -m pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt" || true

# HuggingFace-Sync (nur vorhandene Ordner)
if [ -n "$HF_REPO_ID" ] && [ -n "$HF_TOKEN" ]; then
  HF_TMP="$WORKSPACE/hf_sync"
  if [ ! -d "$HF_TMP/.git" ]; then
    log "Clone HF repo: $HF_REPO_ID"
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth=1 "https://user:${HF_TOKEN}@huggingface.co/${HF_REPO_ID}" "$HF_TMP" || { log "WARN: HF clone failed."; HF_TMP=""; }
  else
    log "Pull HF repo updates …"
    git -C "$HF_TMP" pull --ff-only || true
  fi

  if [ -n "${HF_TMP:-}" ] && [ -d "$HF_TMP" ]; then
    copy_dir(){ local src="$1"; local dst="$2"; if [ -d "$HF_TMP/$src" ]; then
        mkdir -p "$dst"; log "Sync $src  →  $dst"
        rsync -a --delete "$HF_TMP/$src"/ "$dst"/ 2>/dev/null || true
      fi
    }
    copy_dir "checkpoints"     "$MODELS_DIR/checkpoints"
    copy_dir "loras"           "$MODELS_DIR/loras"
    copy_dir "controlnet"      "$MODELS_DIR/controlnet"
    copy_dir "upscale_models"  "$MODELS_DIR/upscale_models"
    copy_dir "faces"           "$MODELS_DIR/faces"
    copy_dir "vae"             "$MODELS_DIR/vae"

    # custom_nodes
    if [ -d "$HF_TMP/custom_nodes" ]; then
      mkdir -p "$COMFY_DIR/custom_nodes"
      log "Sync custom_nodes …"
      rsync -a "$HF_TMP/custom_nodes"/ "$COMFY_DIR/custom_nodes"/ || true
    fi

    # workflows (nur .json)
    if [ -d "$HF_TMP/workflows" ]; then
      mkdir -p "$COMFY_DIR/workflows"
      log "Sync workflows (.json) …"
      rsync -a --include='*/' --include='*.json' --exclude='*' "$HF_TMP/workflows"/ "$COMFY_DIR/workflows"/ || true
    fi
  fi
else
  log "HF sync skipped (HF_TOKEN/HF_REPO_ID fehlen)."
fi

# JupyterLab starten (optional)
if [ -n "$JUPYTER_PORT" ]; then
  log "Start JupyterLab :$JUPYTER_PORT"
  jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    ${JUPYTER_TOKEN:+--ServerApp.token="$JUPYTER_TOKEN"} \
    --ServerApp.open_browser=False > /var/log/jupyter.log 2>&1 &
fi

# ComfyUI starten
log "Start ComfyUI :$COMFYUI_PORT"
cd "$COMFY_DIR"
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT"

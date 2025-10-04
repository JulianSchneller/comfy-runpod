#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo -e "[entrypoint] $*"; }
warn(){ echo -e "[entrypoint][WARN] $*" >&2; }
err() { echo -e "[entrypoint][ERROR] $*" >&2; }

# ---------------------- Konfiguration über ENV --------------------------------
PORT="${PORT:-8188}"
HF_SYNC="${HF_SYNC:-1}"
HF_DELETE_EXTRAS="${HF_DELETE_EXTRAS:-0}"     # 1 = rsync --delete
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"   # requirements.txt der Custom-Nodes
ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}"         # 1 = optionales Jupyter
DISABLE_NSFW="${DISABLE_NSFW:-1}"             # 1 = NSFW-Bypass best-effort

# ---------------------- ComfyUI Basispfad finden ------------------------------
BASE="/workspace/ComfyUI"
[[ -d "$BASE" ]] || BASE="/content/ComfyUI"
[[ -d "$BASE" ]] || BASE="/app/ComfyUI"
mkdir -p "$BASE"
cd "$BASE"

MODELS="$BASE/models"
CHECKPOINTS="$MODELS/checkpoints"
LORAS="$MODELS/loras"
CONTROLNET="$MODELS/controlnet"
FACES="$MODELS/faces"
UPSCALE="$MODELS/upscale_models"
ANNOTATORS="$MODELS/annotators"
CUSTOM_NODES="$BASE/custom_nodes"
WORKFLOWS="$BASE/user/workflows"
WEB_USER="$BASE/web/extensions/user"
AUX_CKPTS="$CUSTOM_NODES/comfyui_controlnet_aux/ckpts"

mkdir -p "$CHECKPOINTS" "$LORAS" "$CONTROLNET" "$FACES" "$UPSCALE" \
         "$CUSTOM_NODES" "$WORKFLOWS" "$WEB_USER" "$AUX_CKPTS" "$ANNOTATORS"

# ---------------------- NSFW-Bypass (best-effort) -----------------------------
if [[ "${DISABLE_NSFW}" == "1" ]]; then
  python3 - <<'PY' || true
import importlib
mods = [
  "diffusers.pipelines.stable_diffusion.safety_checker",
  "diffusers.pipelines.stable_diffusion_xl.safety_checker",
]
for mname in mods:
    try:
        m = importlib.import_module(mname)
        if hasattr(m, "StableDiffusionSafetyChecker"):
            def _forward(self, clip_input, images):
                # gibt Bilder unverändert zurück, Score=0 (keine NSFW)
                try:
                    n = len(images)
                except Exception:
                    n = 1
                return images, [0.0]*n
            m.StableDiffusionSafetyChecker.forward = _forward
    except Exception:
        pass
PY
  log "NSFW bypass aktiviert (Diffusers-Patch, falls vorhanden)."
fi

# ---------------------- Node-Requirements installieren ------------------------
if [[ "${INSTALL_NODE_REQS}" == "1" ]]; then
  if ! command -v pip >/dev/null 2>&1; then
    log "pip nicht gefunden – installiere python3-pip"
    apt-get update -y && apt-get install -y python3-pip >/dev/null
  fi
  for R in "$CUSTOM_NODES"/*/requirements.txt; do
    [[ -f "$R" ]] || continue
    log "pip install -r $R"
    pip install --no-input -r "$R" || true
  done
fi

# ---------------------- HF Bundle Sync ----------------------------------------
sync_hf_bundle() {
  if [[ "${HF_SYNC}" != "1" ]]; then
    log "[HF] Sync deaktiviert (HF_SYNC!=1)"; return 0
  fi
  if [[ -z "${HF_REPO_ID:-}" ]]; then
    warn "[HF] HF_REPO_ID nicht gesetzt – Sync übersprungen."
    return 0
  fi

  command -v rsync >/dev/null 2>&1 || { apt-get update -y && apt-get install -y rsync >/dev/null; }
  python3 - <<'PY' >/dev/null 2>&1 || pip install -U huggingface_hub >/dev/null
import sys
PY

  STAGE="/tmp/hf_stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"

  log "[HF] Lade Snapshot: $HF_REPO_ID"
  python3 - <<PY
from huggingface_hub import snapshot_download
import os
repo   = os.environ["HF_REPO_ID"]
token  = os.environ.get("HF_TOKEN")
stage  = os.environ["STAGE"]
allow  = [
  "checkpoints/**","loras/**","controlnet/**","faces/**","upscale_models/**",
  "gehobene_Modelle/**","custom_nodes/**","workflows/**","Arbeitsabläufe/**",
  "web_extensions/**","annotators/ckpts/**"
]
snapshot_download(repo_id=repo, local_dir=stage, local_dir_use_symlinks=True,
                  allow_patterns=allow, token=token)
PY

  RSDEL=""
  [[ "${HF_DELETE_EXTRAS}" == "1" ]] && RSDEL="--delete"
  rsync_copy() {
    local src="$1"; local dst="$2"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dst"
    rsync -a $RSDEL "$src/""$dst/" 2>/dev/null || true
  }

  rsync_copy "$STAGE/checkpoints"     "$CHECKPOINTS"
  rsync_copy "$STAGE/loras"           "$LORAS"
  rsync_copy "$STAGE/controlnet"      "$CONTROLNET"
  rsync_copy "$STAGE/faces"           "$FACES"
  rsync_copy "$STAGE/upscale_models"  "$UPSCALE"
  rsync_copy "$STAGE/gehobene_Modelle" "$UPSCALE"   # alias

  rsync_copy "$STAGE/custom_nodes"    "$CUSTOM_NODES"
  rsync_copy "$STAGE/workflows"       "$WORKFLOWS"
  rsync_copy "$STAGE/Arbeitsabläufe"  "$WORKFLOWS"  # alias

  if [[ -d "$STAGE/web_extensions" ]]; then
    rsync -a $RSDEL "$STAGE/web_extensions/" "$WEB_USER/"
  fi

  rsync_copy "$STAGE/annotators/ckpts" "$AUX_CKPTS"

  # Symlink der Annotator-CKPTs in das globale models/annotators
  if [[ -e "$ANNOTATORS/ckpts" && ! -L "$ANNOTATORS/ckpts" ]]; then
    warn "[HF] $ANNOTATORS/ckpts existiert (kein Symlink) – lasse unverändert."
  else
    rm -f "$ANNOTATORS/ckpts"
    ln -s "$AUX_CKPTS" "$ANNOTATORS/ckpts"
    log "[HF] Symlink: $ANNOTATORS/ckpts -> $AUX_CKPTS"
  fi

  # Aufräumen
  find "$BASE" -type f -name '*.part' -delete 2>/dev/null || true
  rm -rf ~/.cache/huggingface/hub ~/.cache/torch 2>/dev/null || true
  pip cache purge -y >/dev/null 2>&1 || true
  rm -rf "$STAGE"

  log "[HF] Sync abgeschlossen."
}

# ---------------------- Optional: Jupyter -------------------------------------
start_jupyter() {
  if [[ "${ENABLE_JUPYTER}" != "1" ]]; then return 0; fi
  if ! command -v jupyter >/dev/null 2>&1; then
    pip install -U notebook >/dev/null
  fi
  log "Starte Jupyter (Port 8888)…"
  jupyter notebook --NotebookApp.token='' --NotebookApp.password='' \
    --ip=0.0.0.0 --port=8888 --no-browser --allow-root >/tmp/jupyter.log 2>&1 &
}

# ---------------------- Ablauf ------------------------------------------------
log "ComfyUI Base: $BASE"
start_jupyter
sync_hf_bundle

log "Starte ComfyUI (Port ${PORT}) …"
exec python3 main.py --listen 0.0.0.0 --port "${PORT}"

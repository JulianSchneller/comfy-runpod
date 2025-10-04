#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo -e "[entrypoint] $*"; }
warn(){ echo -e "[entrypoint][WARN] $*" >&2; }

PORT="${PORT:-8188}"
HF_SYNC="${HF_SYNC:-1}"
HF_DELETE_EXTRAS="${HF_DELETE_EXTRAS:-0}"
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"
ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}"
DISABLE_NSFW="${DISABLE_NSFW:-1}"

BASE="/workspace/ComfyUI"; [[ -d "$BASE" ]] || BASE="/content/ComfyUI"; [[ -d "$BASE" ]] || BASE="/app/ComfyUI"
mkdir -p "$BASE"; cd "$BASE"

MODELS="$BASE/models"
CHECKPOINTS="$MODELS/checkpoints"; LORAS="$MODELS/loras"; CONTROLNET="$MODELS/controlnet"
FACES="$MODELS/faces"; UPSCALE="$MODELS/upscale_models"; ANNOTATORS="$MODELS/annotators"
CUSTOM_NODES="$BASE/custom_nodes"; WORKFLOWS="$BASE/user/workflows"; WEB_USER="$BASE/web/extensions/user"
AUX_CKPTS="$CUSTOM_NODES/comfyui_controlnet_aux/ckpts"
mkdir -p "$CHECKPOINTS" "$LORAS" "$CONTROLNET" "$FACES" "$UPSCALE" "$CUSTOM_NODES" "$WORKFLOWS" "$WEB_USER" "$AUX_CKPTS" "$ANNOTATORS"

# NSFW-Bypass (Diffusers SafetyChecker)
if [[ "$DISABLE_NSFW" == "1" ]]; then
python3 - <<'PY' || true
import importlib
mods=["diffusers.pipelines.stable_diffusion.safety_checker","diffusers.pipelines.stable_diffusion_xl.safety_checker"]
for m in mods:
    try:
        x=importlib.import_module(m)
        if hasattr(x,"StableDiffusionSafetyChecker"):
            def _f(self,clip_input,images):
                try: n=len(images)
                except Exception: n=1
                return images,[0.0]*n
            x.StableDiffusionSafetyChecker.forward=_f
    except Exception: pass
PY
log "NSFW bypass aktiv."
fi

# requirements.txt der Custom-Nodes
if [[ "$INSTALL_NODE_REQS" == "1" ]]; then
  command -v pip >/dev/null 2>&1 || { apt-get update -y && apt-get install -y python3-pip >/dev/null; }
  for R in "$CUSTOM_NODES"/*/requirements.txt; do [[ -f "$R" ]] || continue; log "pip install -r $R"; pip install --no-input -r "$R" || true; done
fi

sync_hf_bundle(){
  if [[ "$HF_SYNC" != "1" ]]; then log "[HF] Sync aus"; return 0; fi
  if [[ -z "${HF_REPO_ID:-}" ]]; then warn "[HF] HF_REPO_ID fehlt"; return 0; fi
  command -v rsync >/dev/null 2>&1 || { apt-get update -y && apt-get install -y rsync >/dev/null; }
  python3 - <<'PY' >/dev/null 2>&1 || pip install -U huggingface_hub >/dev/null
import sys
PY
  STAGE="/tmp/hf_stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  log "[HF] snapshot_download $HF_REPO_ID"
  python3 - <<PY
from huggingface_hub import snapshot_download
import os
repo=os.environ["HF_REPO_ID"]; token=os.environ.get("HF_TOKEN"); stage=os.environ["STAGE"]
allow=["checkpoints/**","loras/**","controlnet/**","faces/**","upscale_models/**","gehobene_Modelle/**","custom_nodes/**","workflows/**","Arbeitsabläufe/**","web_extensions/**","annotators/ckpts/**"]
snapshot_download(repo_id=repo, local_dir=stage, local_dir_use_symlinks=True, allow_patterns=allow, token=token)
PY
  RSDEL=""; [[ "$HF_DELETE_EXTRAS" == "1" ]] && RSDEL="--delete"
  rs(){ src="$1"; dst="$2"; [[ -d "$src" ]] || return 0; mkdir -p "$dst"; rsync -a $RSDEL "$src/""$dst/" 2>/dev/null || true; }
  rs "$STAGE/checkpoints" "$CHECKPOINTS"; rs "$STAGE/loras" "$LORAS"; rs "$STAGE/controlnet" "$CONTROLNET"
  rs "$STAGE/faces" "$FACES"; rs "$STAGE/upscale_models" "$UPSCALE"; rs "$STAGE/gehobene_Modelle" "$UPSCALE"
  rs "$STAGE/custom_nodes" "$CUSTOM_NODES"; rs "$STAGE/workflows" "$WORKFLOWS"; rs "$STAGE/Arbeitsabläufe" "$WORKFLOWS"
  if [[ -d "$STAGE/web_extensions" ]]; then rsync -a $RSDEL "$STAGE/web_extensions/" "$WEB_USER/"; fi
  rs "$STAGE/annotators/ckpts" "$AUX_CKPTS"
  if [[ -e "$ANNOTATORS/ckpts" && ! -L "$ANNOTATORS/ckpts" ]]; then :
  else rm -f "$ANNOTATORS/ckpts"; ln -s "$AUX_CKPTS" "$ANNOTATORS/ckpts"; log "[HF] Symlink annotators/ckpts -> aux/ckpts"; fi
  find "$BASE" -type f -name '*.part' -delete 2>/dev/null || true
  rm -rf ~/.cache/huggingface/hub ~/.cache/torch 2>/dev/null || true; pip cache purge -y >/dev/null 2>&1 || true
  rm -rf "$STAGE"; log "[HF] Sync ok."
}

start_jupyter(){ if [[ "$ENABLE_JUPYTER" != "1" ]]; then return 0; fi; command -v jupyter >/dev/null 2>&1 || pip install -U notebook >/dev/null; jupyter notebook --NotebookApp.token='' --NotebookApp.password='' --ip=0.0.0.0 --port=8888 --no-browser --allow-root >/tmp/jupyter.log 2>&1 &; }

log "ComfyUI Base: $BASE"
start_jupyter
sync_hf_bundle
log "Starte ComfyUI auf Port $PORT …"
exec python3 main.py --listen 0.0.0.0 --port "$PORT"

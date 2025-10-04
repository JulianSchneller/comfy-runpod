#!/bin/bash
set -euo pipefail

# ========= config =========
export WORKSPACE="{{WORKSPACE:-/workspace}}"
export COMFY_DIR="{{COMFY_DIR:-$WORKSPACE/ComfyUI}}"
export LOG_DIR="{{LOG_DIR:-$WORKSPACE/logs}}"
export COMFYUI_PORT="{{COMFYUI_PORT:-8188}}"
export JUPYTER_PORT="{{JUPYTER_PORT:-8888}}"
export ENABLE_JUPYTER="{{ENABLE_JUPYTER:-1}}"

# Hugging Face Bundle (für Sync beim Start)
export HF_REPO="{HF_REPO}"
export HF_BRANCH="{HF_BRANCH}"
# Optional: HF_TOKEN als Umgebungsvariable setzen, wenn Repo privat ist.

# ========= helpers =========
log()  { echo -e "[\033[1;36m$(date +%H:%M:%S)\033[0m] $*"; }
warn() { echo -e "[\033[1;33mWARN\033[0m] $*" >&2; }
err()  { echo -e "[\033[1;31mERR \033[0m] $*" >&2; }

mkdir -p "$LOG_DIR"

# ========= ensure ComfyUI & models layout =========
if [[ ! -d "$COMFY_DIR" ]]; then
  log "ComfyUI fehlt unter $COMFY_DIR – klone ComfyUI (Fallback)…"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
fi

for d in checkpoints clip clip_vision controlnet embeddings loras upscale_models vae; do
  mkdir -p "$COMFY_DIR/models/$d"
done
mkdir -p "$COMFY_DIR/user/workflows" "$COMFY_DIR/web/extensions/user"

# ========= HF Sync (custom_nodes, annotators/ckpts, web_extensions, workflows) =========
PYBIN="$(command -v python3 || command -v python)"
if [[ -n "$Floorius/comfyui-model-bundle" ]]; then
  log "HF Sync: $HF_REPO@$HF_BRANCH"
  "$PYBIN" - <<'PY'
import os, sys, shutil
from pathlib import Path

def ensure_hub():
    try:
        import huggingface_hub  # noqa
    except Exception:
        import subprocess
        subprocess.check_call([sys.executable,"-m","pip","install","-q","huggingface_hub==0.35.3"])
ensure_hub()
from huggingface_hub import snapshot_download, login

hf_token = os.environ.get("HF_TOKEN","").strip()
if hf_token:
    try:
        login(token=hf_token, add_to_git_credential=False)
    except Exception as e:
        print("HF login warning:", e, file=sys.stderr)

repo   = os.environ.get("HF_REPO","Floorius/comfyui-model-bundle")
branch = os.environ.get("HF_BRANCH","main")
dst    = "/tmp/hf_sync"
allow  = ["custom_nodes/**","annotators/ckpts/**","web_extensions/**","workflows/*.json"]

p = snapshot_download(repo_id=repo, revision=branch, local_dir=dst,
                      local_dir_use_symlinks=False, allow_patterns=allow)
print("HF downloaded to", p)
PY

  # Kopieren in Zielstruktur
  if [[ -d "/tmp/hf_sync/custom_nodes" ]]; then
    rsync -a --delete "/tmp/hf_sync/custom_nodes/" "$COMFY_DIR/custom_nodes/"
  fi
  if [[ -d "/tmp/hf_sync/web_extensions" ]]; then
    rsync -a "/tmp/hf_sync/web_extensions/" "$COMFY_DIR/web/extensions/user/"
  fi
  if [[ -d "/tmp/hf_sync/workflows" ]]; then
    rsync -a "/tmp/hf_sync/workflows/" "$COMFY_DIR/user/workflows/"
  fi
  if [[ -d "/tmp/hf_sync/annotators/ckpts" ]]; then
    mkdir -p "$COMFY_DIR/custom_nodes/comfyui_controlnet_aux/ckpts"
    rsync -a "/tmp/hf_sync/annotators/ckpts/" "$COMFY_DIR/custom_nodes/comfyui_controlnet_aux/ckpts/"
    mkdir -p "$COMFY_DIR/annotators"
    ln -sf "$COMFY_DIR/custom_nodes/comfyui_controlnet_aux/ckpts" "$COMFY_DIR/annotators/ckpts"
  fi
fi

# ========= NSFW-Bypass (nicht blockieren) =========
log "Patching NSFW-Checks (setze block_nsfw/safety_checker -> False, wo vorhanden)…"
"$PYBIN" - <<'PY'
import os, re
base = os.environ.get("COMFY_DIR","/workspace/ComfyUI")
targets = []
for root, _, files in os.walk(base):
    if "site-packages" in root:
        continue
    for f in files:
        if f.endswith(".py"):
            targets.append(os.path.join(root,f))

patched = 0
patterns = [
    (r'block_nsfw\s*:\s*Optional\[bool\]\s*=\s*None', 'block_nsfw: Optional[bool] = False'),
    (r'block_nsfw\s*=\s*True', 'block_nsfw = False'),
    (r'safety[_ ]?checker\s*=\s*True', 'safety_checker = False'),
    (r'["\']nsfw["\']\s*:\s*True', '"nsfw": False'),
]
for p in targets:
    try:
        with open(p, 'r', encoding='utf-8', errors='ignore') as fh:
            txt = fh.read()
        orig = txt
        for a,b in patterns:
            txt = re.sub(a,b,txt)
        if txt != orig:
            with open(p,'w',encoding='utf-8') as fw:
                fw.write(txt)
            patched += 1
    except Exception:
        pass
print("Patched files:", patched)
PY

# ========= Jupyter =========
if [[ "${ENABLE_JUPYTER}" != "0" ]]; then
  log "Starte JupyterLab :$JUPYTER_PORT"
  nohup jupyter lab --ip=0.0.0.0 --no-browser --port="$JUPYTER_PORT" \
       --LabApp.token="" --LabApp.password="" > "$LOG_DIR/jupyter.log" 2>&1 &
fi

# ========= ComfyUI =========
log "Starte ComfyUI :$COMFYUI_PORT"
cd "$COMFY_DIR"
exec python3 main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" > "$LOG_DIR/comfyui.log" 2>&1

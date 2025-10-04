#!/usr/bin/env bash
set -euo pipefail
set -Eeuo pipefail

# ====== Basispfade ======
export WORKSPACE="${WORKSPACE:-/workspace}"
export COMFY_DIR="$WORKSPACE/ComfyUI"
export MODELS_DIR="$COMFY_DIR/models"
export LOG_DIR="$WORKSPACE/logs"
export CNODES="$COMFY_DIR/custom_nodes"
export CKPTS="$MODELS_DIR/annotators/ckpts"
export HF_DIR="${HF_DIR:-$WORKSPACE/hf_bundle}"   # lokaler HF-Stage/Snapshot

mkdir -p "$LOG_DIR" "$CNODES" "$CKPTS"
mkdir -p "$MODELS_DIR"/{checkpoints,loras,controlnet,upscale_models,faces,vae,clip_vision,style_models,embeddings,diffusers,vae_approx}
mkdir -p "$COMFY_DIR/user/default/workflows"
mkdir -p "$COMFY_DIR/web/extensions"

log(){ printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# ====== ENV / Ports ======
export HF_REPO_ID="${HF_REPO_ID:-}"      # z.B. Floorius/comfyui-model-bundle
export HF_TOKEN="${HF_TOKEN:-}"          # hf_*
export COMFYUI_PORT="${COMFYUI_PORT:-8188}"
export JUPYTER_ENABLE="${JUPYTER_ENABLE:-0}"
export JUPYTER_PORT="${JUPYTER_PORT:-8888}"

# ====== Hilfsfunktionen ======
dl_if_missing() {
  local url="$1"; local out="$2"
  if [[ -f "$out" ]]; then
    echo "✔️  vorhanden: $out"
    return 0
  fi
  echo "⬇️  $out"
  curl -L --fail --retry 5 --connect-timeout 15 "$url" -o "$out"
}

# ====== Custom Nodes: ControlNet + Aux ======
echo "== 🧩 Custom Nodes (ControlNet/Aux) =="
clone_or_update() {
  local url="$1"; local dir="$2"
  if [[ ! -d "$dir/.git" ]]; then
    echo "⬇️  $url → $dir"
    git clone --depth=1 "$url" "$dir" || true
  else
    echo "↻  pull $dir"
    (cd "$dir" && git pull --ff-only || true)
  fi
}
clone_or_update "https://github.com/Kosinkadink/ComfyUI-Advanced-ControlNet.git"   "$CNODES/ComfyUI-Advanced-ControlNet"
clone_or_update "https://github.com/Fannovel16/comfyui_controlnet_aux.git"         "$CNODES/comfyui_controlnet_aux"

# Requirements der Nodes (nicht hart failen, Log sammeln)
if command -v pip >/dev/null 2>&1; then
  pip install --no-cache-dir -r "$CNODES/comfyui_controlnet_aux/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
  pip install --no-cache-dir -r "$CNODES/ComfyUI-Advanced-ControlNet/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
fi

# ====== OpenPose/DWPose CKPTs (Best Effort) ======
echo "== 🧠 OpenPose/DWPose CKPTs =="
mkdir -p "$CKPTS"
dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/body_pose_model.pth" "$CKPTS/body_pose_model.pth" || true
dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/hand_pose_model.pth" "$CKPTS/hand_pose_model.pth" || true
curl -L --fail --retry 3 "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/facenet.pth" -o "$CKPTS/facenet.pth" || true

dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth" "$CKPTS/dw-ll_ucoco_384.pth" || true
dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"        "$CKPTS/yolox_l.onnx" || true
curl -L --fail --retry 3 "https://huggingface.co/monster-labs/controlnet_aux_models/resolve/main/yolox_l.torchscript" -o "$CKPTS/yolox_l.torchscript" || true

# ====== HF-Bundle: kompletter Sync (Modelle + Workflows + web_extensions) ======
download_all_from_hf() {
  if [[ -z "${HF_REPO_ID:-}" || -z "${HF_TOKEN:-}" ]]; then
    log "HF Direct Download übersprungen (HF_REPO_ID/HF_TOKEN fehlen)."
    return 0
  fi
  python - <<'PY'
import os, sys
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download, login

repo   = os.environ.get("HF_REPO_ID","")
token  = os.environ.get("HF_TOKEN","")
work   = os.environ.get("WORKSPACE","/workspace")
comfy  = os.path.join(work,"ComfyUI")
stage  = os.environ.get("HF_DIR", os.path.join(work,"hf_bundle"))

login(token=token, add_to_git_credential=False)
api = HfApi()

Path(stage).mkdir(parents=True, exist_ok=True)
# Ordnerstruktur im Stage
for p in ["checkpoints","loras","controlnet","upscale_models","faces","vae","clip_vision","style_models","embeddings","diffusers","vae_approx"]:
    (Path(stage)/"models"/p).mkdir(parents=True, exist_ok=True)
(Path(stage)/"web_extensions").mkdir(parents=True, exist_ok=True)
(Path(stage)/"workflows").mkdir(parents=True, exist_ok=True)

def sync_dir(prefix, dest, allow_ext=None):
    files = api.list_repo_files(repo_id=repo, repo_type="model")
    hit = False
    for f in files:
        if f.startswith(prefix + "/"):
            if allow_ext and not any(f.lower().endswith(ext) for ext in allow_ext):
                continue
            hf_hub_download(repo_id=repo, filename=f, local_dir=dest, local_dir_use_symlinks=False)
            hit = True
    return hit

base = str(Path(stage)/"models")
sync_dir("checkpoints"   , base+"/checkpoints")
sync_dir("loras"         , base+"/loras")
sync_dir("controlnet"    , base+"/controlnet")
sync_dir("upscale_models", base+"/upscale_models")
sync_dir("faces"         , base+"/faces")
sync_dir("vae"           , base+"/vae")
sync_dir("clip_vision"   , base+"/clip_vision")
sync_dir("style_models"  , base+"/style_models")
sync_dir("embeddings"    , base+"/embeddings")
sync_dir("diffusers"     , base+"/diffusers")
sync_dir("vae_approx"    , base+"/vae_approx")
sync_dir("workflows"     , str(Path(stage)/"workflows"), allow_ext=[".json"])
sync_dir("web_extensions", str(Path(stage)/"web_extensions"))

print("[HF] Sync abgeschlossen →", stage)
PY
}
download_all_from_hf

# ====== Web-Extensions JETZT kopieren (VOR exec) ======
echo "== 📦 Kopiere Web-Extensions (vor Start) =="
if [[ -d "$HF_DIR/web_extensions" ]]; then
  rsync -a "$HF_DIR/web_extensions/" "$COMFY_DIR/web/extensions/"
echo "== 📦 Sync HF models & workflows =="
if [[ -d "$HF_DIR/models" ]]; then
  mkdir -p "$MODELS_DIR"
  rsync -a --ignore-existing "$HF_DIR/models/" "$MODELS_DIR/"
  echo "   ✔ Modelle → $MODELS_DIR"
else
  echo "   (keine models im HF-Bundle gefunden)"
fi

if [[ -d "$HF_DIR/workflows" ]]; then
  mkdir -p "$COMFY_DIR/user/default/workflows"
  rsync -a --include="*/" --include="*.json" --exclude="*" \
        "$HF_DIR/workflows/" "$COMFY_DIR/user/default/workflows/"
  echo "   ✔ Workflows → $COMFY_DIR/user/default/workflows"
else
  echo "   (keine workflows im HF-Bundle gefunden)"
fi
  echo "   ✔ Web-Extensions aktualisiert."
else
  echo "   (keine web_extensions im HF-Bundle gefunden)"
fi

# ====== Jupyter (optional) ======
if [[ "${JUPYTER_ENABLE}" == "1" ]]; then
  echo "== 🧪 Starte JupyterLab (Port ${JUPYTER_PORT}) =="
  nohup jupyter-lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser >"$LOG_DIR/jupyter.log" 2>&1 &
fi

# ====== ComfyUI starten (im Vordergrund) ======
cd "$COMFY_DIR"
echo "== 🚀 Starte ComfyUI (Port ${COMFYUI_PORT}) =="
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >"$LOG_DIR/comfyui.log" 2>&1
mkdir -p "$HF_DIR"

hf_get() { # hf_get <url> <out>
  local url="$1"; local out="$2"
  if [[ -f "$out" ]]; then echo "✔️  vorhanden: $out"; return 0; fi
  echo "⬇️  $out"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    curl -L --fail --retry 5 -H "Authorization: Bearer $HF_TOKEN" "$url" -o "$out"
  else
    curl -L --fail --retry 5 "$url" -o "$out"
  fi
}

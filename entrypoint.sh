#!/usr/bin/env bash
set -euo pipefail

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
export HF_TOKEN="${HF_TOKEN:-}"          # hf_* (für private Repos nötig)
export COMFYUI_PORT="${COMFYUI_PORT:-8188}"
export JUPYTER_ENABLE="${JUPYTER_ENABLE:-0}"
export JUPYTER_PORT="${JUPYTER_PORT:-8888}"

need_cmd(){ command -v "$1" >/dev/null 2>&1 || return 1; }

dl_if_missing() {
  local url="$1"; local out="$2"
  if [[ -f "$out" ]]; then
    echo "✔️  vorhanden: $out"
    return 0
  fi
  echo "⬇️  $out"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    curl -L --fail --retry 5 -H "Authorization: Bearer $HF_TOKEN" "$url" -o "$out"
  else
    curl -L --fail --retry 5 "$url" -o "$out"
  fi
}

copy_tree() {  # copy_tree <src/> <dst/>
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  if need_cmd rsync; then
    rsync -a --ignore-existing "$src" "$dst/"
  else
    cp -rn "$src"/* "$dst/" 2>/dev/null || true
  fi
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

# Node-Requirements (best effort)
if need_cmd pip; then
  pip install --no-cache-dir -r "$CNODES/comfyui_controlnet_aux/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
  pip install --no-cache-dir -r "$CNODES/ComfyUI-Advanced-ControlNet/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
fi

# ====== OpenPose/DWPose CKPTs (Best Effort) ======
echo "== 🧠 OpenPose/DWPose CKPTs =="
mkdir -p "$CKPTS"
dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/body_pose_model.pth" "$CKPTS/body_pose_model.pth" || true
dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/hand_pose_model.pth" "$CKPTS/hand_pose_model.pth" || true
dl_if_missing "https://huggingface.co/monster-labs/controlnet_aux_models/resolve/main/yolox_l.torchscript"   "$CKPTS/yolox_l.torchscript" || true
dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth" "$CKPTS/dw-ll_ucoco_384.pth" || true
dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"        "$CKPTS/yolox_l.onnx" || true
# facenet.pth ist oft 404/entfernt → bewusst optional:
curl -L --fail --retry 3 -o "$CKPTS/facenet.pth" \
  ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} \
  "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/facenet.pth" || true

# ====== HF-Bundle (Modelle/Workflows/Web-Extensions) ======
download_all_from_hf() {
  if [[ -z "${HF_REPO_ID:-}" ]]; then
    log "HF Sync übersprungen (HF_REPO_ID leer)."
    return 0
  fi
  python - <<'PY'
import os
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download, login

repo   = os.environ.get("HF_REPO_ID","")
token  = os.environ.get("HF_TOKEN","")
work   = os.environ.get("WORKSPACE","/workspace")
stage  = os.environ.get("HF_DIR", os.path.join(work,"hf_bundle"))

if token:
  try:
    login(token=token, add_to_git_credential=False)
  except Exception:
    pass

api = HfApi()
Path(stage).mkdir(parents=True, exist_ok=True)

# Zielordner vorbereiten
for p in ["checkpoints","loras","controlnet","upscale_models","faces","vae","clip_vision","style_models","embeddings","diffusers","vae_approx"]:
    (Path(stage)/"models"/p).mkdir(parents=True, exist_ok=True)
(Path(stage)/"web_extensions").mkdir(parents=True, exist_ok=True)
(Path(stage)/"workflows").mkdir(parents=True, exist_ok=True)

files = api.list_repo_files(repo_id=repo, repo_type="model")
def pull(prefix, dest, allow_ext=None):
    hit = False
    for f in files:
        if f.startswith(prefix + "/"):
            if allow_ext and not any(f.lower().endswith(ext) for ext in allow_ext):
                continue
            hf_hub_download(repo_id=repo, filename=f, local_dir=dest, local_dir_use_symlinks=False)
            hit = True
    return hit

base = Path(stage)/"models"
pull("checkpoints"   , base/"checkpoints")
pull("loras"         , base/"loras")
pull("controlnet"    , base/"controlnet")
pull("upscale_models", base/"upscale_models")
pull("faces"         , base/"faces")
pull("vae"           , base/"vae")
pull("clip_vision"   , base/"clip_vision")
pull("style_models"  , base/"style_models")
pull("embeddings"    , base/"embeddings")
pull("diffusers"     , base/"diffusers")
pull("vae_approx"    , base/"vae_approx")
pull("workflows"     , str(Path(stage)/"workflows"), allow_ext=[".json"])
pull("web_extensions", str(Path(stage)/"web_extensions"))

print(f"[HF] Sync abgeschlossen → {stage}")
PY
}

echo "== 📦 HF Sync (falls konfiguriert) =="
download_all_from_hf

echo "== 🔁 Kopiere Modelle/Workflows/Web-Extensions =="
# Reihenfolge: Modelle → Workflows → Web-Extensions
copy_tree "$HF_DIR/models"         "$MODELS_DIR"
copy_tree "$HF_DIR/workflows"      "$COMFY_DIR/user/default/workflows"
copy_tree "$HF_DIR/web_extensions" "$COMFY_DIR/web/extensions"

# ====== Jupyter (optional) ======
if [[ "${JUPYTER_ENABLE}" == "1" ]]; then
  echo "== 🧪 Starte JupyterLab (Port ${JUPYTER_PORT}) =="
  nohup jupyter-lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser >"$LOG_DIR/jupyter.log" 2>&1 &
fi

# ====== ComfyUI starten (im Vordergrund) ======
cd "$COMFY_DIR"
echo "== 🚀 Starte ComfyUI (Port ${COMFYUI_PORT}) =="
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >"$LOG_DIR/comfyui.log" 2>&1

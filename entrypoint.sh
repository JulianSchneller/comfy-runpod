#!/usr/bin/env bash
set -Eeuo pipefail

log(){ printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# ===== ENV / Defaults =====
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=/workspace/ComfyUI}"
: "${COMFYUI_PORT:=8188}"

# Hugging Face (optional)
: "${HF_REPO_ID:=}"                          # z.B. Floorius/comfyui-model-bundle
: "${HF_BRANCH:=main}"
: "${HF_TOKEN:=${HUGGINGFACE_HUB_TOKEN:-}}"  # Token auch aus HUGGINGFACE_HUB_TOKEN ziehen

# Jupyter (optional)
: "${RUN_JUPYTER:=1}"
: "${JUPYTER_PORT:=8888}"
: "${JUPYTER_TOKEN:=${JUPYTER_PASSWORD:-}}"

# NSFW Bypass
: "${NSFW_BYPASS:=1}"

# Caches
export HF_HOME="${WORKSPACE}/.cache/huggingface"
export HUGGINGFACE_HUB_CACHE="${HF_HOME}"
mkdir -p "$HF_HOME" "${WORKSPACE}/logs"

# ===== ComfyUI holen/aktualisieren =====
if [[ ! -d "${COMFYUI_BASE}/.git" ]]; then
  log "Cloning ComfyUI…"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_BASE}"
else
  log "ComfyUI vorhanden."
fi

# requirements.txt ggf. entschlacken (keine Template-Workflows)
if [[ -f "${COMFYUI_BASE}/requirements.txt" ]] && grep -q "comfyui-workflow-templates" "${COMFYUI_BASE}/requirements.txt"; then
  sed -i '/comfyui-workflow-templates/d' "${COMFYUI_BASE}/requirements.txt"
fi

log "Install Python deps… (best effort)"
python3 - <<'PY' || true
import subprocess, sys, os
subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","--upgrade",
                "pip","setuptools","wheel","huggingface_hub>=0.35.0"], check=False)
req = os.path.join(os.environ.get("COMFYUI_BASE","/workspace/ComfyUI"), "requirements.txt")
if os.path.exists(req):
    subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","-r", req], check=False)
# Häufig von KSampler gebraucht:
try:
    import importlib; importlib.import_module("torchsde")
except Exception:
    subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","torchsde"], check=False)
PY

# ===== NSFW-Bypass (defensiv) =====
if [[ "${NSFW_BYPASS}" == "1" ]]; then
  log "NSFW bypass aktiv."
  set +e
  mapfile -t _BN < <(grep -RIl --include="*.py" "block_nsfw" "${COMFYUI_BASE}" 2>/dev/null || true)
  [[ ${#_BN[@]} -gt 0 ]] && sed -i 's/block_nsfw[[:space:]]*:[[:space:]]*Optional\[bool\][[:space:]]*=[[:space:]]*None/block_nsfw: Optional[bool] = False/g' "${_BN[@]}" 2>/dev/null
  [[ ${#_BN[@]} -gt 0 ]] && sed -i 's/block_nsfw=None/block_nsfw=False/g' "${_BN[@]}" 2>/dev/null
  mapfile -t _SC < <(grep -RIl --include="*.py" "safety_checker[[:space:]]*=" "${COMFYUI_BASE}" 2>/dev/null || true)
  [[ ${#_SC[@]} -gt 0 ]] && sed -i 's/safety_checker[[:space:]]*=[[:space:]]*safety_checker/safety_checker=None/g' "${_SC[@]}" 2>/dev/null
  set -e
else
  log "NSFW bypass aus."
fi

# ===== HF Bundle laden (Modelle + Workflows) =====
if [[ -n "${HF_REPO_ID}" && -n "${HF_TOKEN}" ]]; then
  log "[HF] Sync aus ${HF_REPO_ID}@${HF_BRANCH} …"
  python3 - <<'PY'
import os, shutil
from huggingface_hub import HfApi, hf_hub_download, login

repo   = os.environ.get("HF_REPO_ID","")
token  = os.environ.get("HF_TOKEN","")
branch = os.environ.get("HF_BRANCH","main")
base   = os.environ.get("COMFYUI_BASE","/workspace/ComfyUI")
models = os.path.join(base,"models")
wflowd = os.path.join(base,"user","default","workflows")
os.makedirs(wflowd, exist_ok=True)
login(token=token, add_to_git_credential=False)
api = HfApi()
files = api.list_repo_files(repo_id=repo, repo_type="model", revision=branch)
cache="/tmp/hf_cache_full"; os.makedirs(cache, exist_ok=True)

MAP = {
 "checkpoints":    os.path.join(models,"checkpoints"),
 "loras":          os.path.join(models,"loras"),
 "controlnet":     os.path.join(models,"controlnet"),
 "upscale_models": os.path.join(models,"upscale_models"),
 "faces":          os.path.join(models,"faces"),
 "vae":            os.path.join(models,"vae"),
 "clip_vision":    os.path.join(models,"clip_vision"),
 "embeddings":     os.path.join(models,"embeddings"),
 "diffusers":      os.path.join(models,"diffusers"),
}
def copy_to(dst, src):
    os.makedirs(dst, exist_ok=True)
    out = os.path.join(dst, os.path.basename(src))
    if os.path.exists(out) and os.path.getsize(out)==os.path.getsize(src):
        return
    shutil.copy2(src, out)

for f in files:
    if f.startswith("workflows/") and f.lower().endswith(".json"):
        p = hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                            revision=branch, local_dir=cache, local_dir_use_symlinks=False)
        copy_to(wflowd, p)

for f in files:
    if "/" in f:
        top = f.split("/",1)[0]
        if top in MAP and not f.endswith("/"):
            p = hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                                revision=branch, local_dir=cache, local_dir_use_symlinks=False)
            copy_to(MAP[top], p)
PY
else
  log "[HF] Übersprungen (HF_REPO_ID/HF_TOKEN fehlen)."
fi

# ===== controlnet_aux (OpenPose/DWPose) installieren =====
CN_DIR="${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux"
mkdir -p "${COMFYUI_BASE}/custom_nodes" "${COMFYUI_BASE}/models/controlnet-aux"

if [[ ! -d "${CN_DIR}" ]]; then
  log "Install comfyui_controlnet_aux …"
  git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux "${CN_DIR}" || true
else
  log "Update comfyui_controlnet_aux …"
  (cd "${CN_DIR}" && git pull --ff-only || true)
fi

# Requirements (inkl. onnx/opencv/runtime)
if [[ -f "${CN_DIR}/requirements.txt" ]]; then
  python3 -m pip install --no-cache-dir -r "${CN_DIR}/requirements.txt" || true
fi
python3 -m pip install -U --no-cache-dir onnx opencv-python onnxruntime || true

# Modelle (OpenPose + DWPose)
fetch(){
  local url="$1" out="$2"
  [[ -s "$out" ]] && return 0
  mkdir -p "$(dirname "$out")"
  curl -L --retry 3 -o "$out" "$url" >/dev/null 2>&1 || wget -q -O "$out" "$url" || true
}
# OpenPose
fetch "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/body_pose_model.pth" "${CN_DIR}/models/body_pose_model.pth"
fetch "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/hand_pose_model.pth" "${CN_DIR}/models/hand_pose_model.pth"
fetch "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/face_pose_model.pth" "${CN_DIR}/models/face_pose_model.pth"
# DWPose
fetch "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"               "${CN_DIR}/models/yolox_l.onnx"
fetch "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.onnx"       "${CN_DIR}/models/dw-ll_ucoco_384.onnx"

# in ComfyUI/models/controlnet-aux spiegeln (nur wenn fehlt)
for f in body_pose_model.pth hand_pose_model.pth face_pose_model.pth yolox_l.onnx dw-ll_ucoco_384.onnx; do
  [[ -s "${CN_DIR}/models/$f" && ! -s "${COMFYUI_BASE}/models/controlnet-aux/$f" ]] \
    && cp -n "${CN_DIR}/models/$f" "${COMFYUI_BASE}/models/controlnet-aux/$f" || true
done

# Alias-Patch (Legacy-Namen -> aktuelle Klassen)
NW_INIT="${CN_DIR}/node_wrappers/__init__.py"
if [[ -f "${NW_INIT}" ]] && ! grep -q "BEGIN comfy-runpod legacy alias patch" "${NW_INIT}"; then
  cat >> "${NW_INIT}" <<'PY'
# --- BEGIN comfy-runpod legacy alias patch ---
try:
    _m = NODE_CLASS_MAPPINGS
    def _alias(dst, src):
        if (src in _m) and (dst not in _m):
            _m[dst] = _m[src]
    _alias("OpenposePreprocessor", "OpenPosePreprocessor")
    _alias("OpenposeDetector",     "OpenPoseDetector")
    _alias("DWposePreprocessor",   "DWPosePreprocessor")
    _alias("DWposeDetector",       "DWPoseDetector")
except Exception as _e:
    print("[controlnet_aux] alias patch warn:", _e)
# --- END comfy-runpod legacy alias patch ---
PY
fi

# Workflows normalisieren (alte Schreibweisen -> aktuelle)
WF_PATCH_DIRS=()
[[ -d "/workspace/workflows" ]] && WF_PATCH_DIRS+=("/workspace/workflows")
[[ -d "${COMFYUI_BASE}/workflows" ]] && WF_PATCH_DIRS+=("${COMFYUI_BASE}/workflows")
[[ -d "${COMFYUI_BASE}/user/default/workflows" ]] && WF_PATCH_DIRS+=("${COMFYUI_BASE}/user/default/workflows")

if [[ ${#WF_PATCH_DIRS[@]} -gt 0 ]]; then
  python3 - "$@" <<'PY2' "${WF_PATCH_DIRS[@]}"
import sys, os, re
dirs = sys.argv[1:]
subs = [
 (r'"controlnet_aux\.OpenposePreprocessor"', '"controlnet_aux.OpenPosePreprocessor"'),
 (r'"controlnet_aux\.OpenposeDetector"',     '"controlnet_aux.OpenPoseDetector"'),
 (r'"controlnet_aux\.[Dd][Ww]posePreprocessor"', '"controlnet_aux.DWPosePreprocessor"'),
 (r'"controlnet_aux\.[Dd][Ww]poseDetector"',     '"controlnet_aux.DWPoseDetector"'),
]
for base in dirs:
    if not os.path.isdir(base): continue
    for root, _, files in os.walk(base):
        for fn in files:
            if not fn.lower().endswith(".json"): continue
            p = os.path.join(root, fn)
            try:
                s = open(p, "r", encoding="utf-8").read()
                s2 = s
                for pat, rep in subs:
                    s2 = re.sub(pat, rep, s2)
                if s2 != s:
                    open(p, "w", encoding="utf-8").write(s2)
            except Exception as e:
                print("[workflow-normalizer] warn:", p, e)
PY2
fi

# ===== optional Jupyter =====
if [[ "${RUN_JUPYTER}" == "1" ]]; then
  log "Starte JupyterLab :${JUPYTER_PORT}"
  if [[ -n "${JUPYTER_TOKEN}" ]]; then
    jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser --allow-root \
      --ServerApp.token="${JUPYTER_TOKEN}" --ServerApp.open_browser=False >"${WORKSPACE}/logs/jupyter.log" 2>&1 &
  else
    jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser --allow-root \
      --ServerApp.token="" --ServerApp.password="" --ServerApp.open_browser=False >"${WORKSPACE}/logs/jupyter.log" 2>&1 &
  fi
fi

# ===== ComfyUI starten (im Vordergrund) =====
cd "${COMFYUI_BASE}"
log "Starte ComfyUI :${COMFYUI_PORT}"
exec python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" >"${WORKSPACE}/logs/comfyui.log" 2>&1

#!/usr/bin/env bash
set -euo pipefail

log(){ printf "[entrypoint] %s\n" "$*"; }

# ---------- ENV / Defaults ----------
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=}"
: "${COMFYUI_PORT:=8188}"
: "${ENABLE_JUPYTER:=1}"
: "${JUPYTER_PORT:=8888}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
: "${HF_TOKEN:=}"
: "${HF_SYNC:=1}"           # 1=ziehen, 0=skip
: "${ENTRYPOINT_DRY:=0}"    # 1=Netzwerkaktionen überspringen

# ---------- ComfyUI Base verorten ----------
if [[ -z "${COMFYUI_BASE}" ]]; then
  for c in "/workspace/ComfyUI" "/content/ComfyUI" "/ComfyUI" ; do
    [[ -d "$c" ]] && COMFYUI_BASE="$c" && break
  done
  [[ -z "${COMFYUI_BASE}" ]] && COMFYUI_BASE="/content/ComfyUI"
fi
mkdir -p "${COMFYUI_BASE}"
log "ComfyUI Base: ${COMFYUI_BASE}"

# ---------- NSFW CSS Bypass ----------
UEX="${COMFYUI_BASE}/web/extensions/userstyle"
mkdir -p "${UEX}"
cat > "${UEX}/nsfw_bypass.css" <<'CSS'
img.blur, .blur, [style*="filter: blur"] { filter: none !important; }
CSS
log "NSFW bypass CSS gesetzt."

# ---------- HF Snapshot Sync (optional) ----------
if [[ "${HF_SYNC}" = "1" && "${ENTRYPOINT_DRY}" = "0" && -n "${HF_REPO_ID}" ]]; then
  log "[HF] snapshot_download: ${HF_REPO_ID}@${HF_BRANCH}"
  python3 - <<PY
import os
from huggingface_hub import snapshot_download
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
snapshot_download(
    repo_id=os.environ["HF_REPO_ID"],
    repo_type="model",
    revision=os.environ.get("HF_BRANCH","main"),
    local_dir=os.environ.get("WORKSPACE","/workspace"),
    local_dir_use_symlinks=False,
    token=token
)
print("[entrypoint] [HF] OK.")
PY
else
  log "HF-Sync: skip"
fi

# ---------- controlnet_aux (OpenPose/DWPose) ----------
CN_DIR="${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux"
mkdir -p "$(dirname "${CN_DIR}")"

# fetch via git or zip (public)
fetch_cn_aux () {
  if command -v git >/dev/null 2>&1; then
    [[ -d "${CN_DIR}/.git" ]] || git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux "${CN_DIR}"
    (cd "${CN_DIR}" && git pull --ff-only || true)
  else
    TMP="/tmp/cnaux.zip"
    curl -L -o "$TMP" https://github.com/Fannovel16/comfyui_controlnet_aux/archive/refs/heads/master.zip
    unzip -q "$TMP" -d "$(dirname "${CN_DIR}")"
    src="$(dirname "${CN_DIR}")/comfyui_controlnet_aux-master"
    [[ -d "$src" ]] && rm -rf "${CN_DIR}" && mv "$src" "${CN_DIR}"
  fi
}

if [[ ! -d "${CN_DIR}" ]]; then
  [[ "${ENTRYPOINT_DRY}" = "1" ]] || fetch_cn_aux
fi

# Minimal-Dependencies (kein pycairo/cairo-build)
if [[ "${ENTRYPOINT_DRY}" = "0" ]]; then
  python3 -m pip install --no-cache-dir -U \
    opencv-python onnxruntime onnx scikit-image pillow "numpy<2.0" >/dev/null 2>&1 || true
fi

# ---------- Modelle für OpenPose/DWPose ----------
MNODE="${CN_DIR}/models"
MCOMFY="${COMFYUI_BASE}/models/controlnet-aux"
mkdir -p "${MNODE}" "${MCOMFY}"

dl() {
  # dl URL ZIEL
  url="$1"; dst="$2"
  [[ -s "$dst" ]] && return 0
  if command -v curl >/dev/null 2>&1; then
    curl -L --retry 3 -o "$dst" "$url" || true
  else
    python3 - <<PY || true
import urllib.request, sys, os
u=sys.argv[1]; d=sys.argv[2]
os.makedirs(os.path.dirname(d), exist_ok=True)
urllib.request.urlretrieve(u,d)
PY
  "$url" "$dst"
  fi
}

# OpenPose *.pth
[[ "${ENTRYPOINT_DRY}" = "1" ]] || dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/body_pose_model.pth" "${MNODE}/body_pose_model.pth"
[[ "${ENTRYPOINT_DRY}" = "1" ]] || dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/hand_pose_model.pth" "${MNODE}/hand_pose_model.pth"
[[ "${ENTRYPOINT_DRY}" = "1" ]] || dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/face_pose_model.pth" "${MNODE}/face_pose_model.pth"

# DWPose (ONNX + optional PTH)
[[ "${ENTRYPOINT_DRY}" = "1" ]] || dl "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx" "${MNODE}/yolox_l.onnx"
[[ "${ENTRYPOINT_DRY}" = "1" ]] || dl "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.onnx" "${MNODE}/dw-ll_ucoco_384.onnx"
[[ "${ENTRYPOINT_DRY}" = "1" ]] || dl "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth"  "${MNODE}/dw-ll_ucoco_384.pth"

# Spiegeln in ComfyUI/models/controlnet-aux (falls dort noch fehlt)
for f in body_pose_model.pth hand_pose_model.pth face_pose_model.pth yolox_l.onnx dw-ll_ucoco_384.onnx dw-ll_ucoco_384.pth; do
  [[ -s "${MNODE}/${f}" && ! -s "${MCOMFY}/${f}" ]] && cp -f "${MNODE}/${f}" "${MCOMFY}/${f}" || true
done

# ---------- Workflows-Normalisierung (Legacy Namen → aktuelle) ----------
WF_DIRS=(
  "/workspace/workflows"
  "${COMFYUI_BASE}/workflows"
)
norm_workflows(){
python3 - <<'PY'
import os, re, json, sys
dirs = [p for p in sys.argv[1:] if os.path.isdir(p)]
REPL = {
  r'"controlnet_aux\.OpenposePreprocessor"': '"controlnet_aux.OpenPosePreprocessor"',
  r'"controlnet_aux\.OpenposeDetector"'    : '"controlnet_aux.OpenPoseDetector"',
  r'"controlnet_aux\.DWposePreprocessor"'  : '"controlnet_aux.DWPosePreprocessor"',
  r'"controlnet_aux\.DWposeDetector"'      : '"controlnet_aux.DWPoseDetector"',
}
changed=0
for base in dirs:
  for root,_,files in os.walk(base):
    for fn in files:
      if not fn.lower().endswith(".json"): continue
      p=os.path.join(root,fn)
      try:
        s=open(p,"r",encoding="utf-8").read()
        s2=s
        for pat,rep in REPL.items():
          s2=re.sub(pat,rep,s2)
        if s2!=s:
          open(p,"w",encoding="utf-8").write(s2)
          changed+=1
      except Exception as e:
        print("[entrypoint] workflow patch warn:", p, e)
print(f"[entrypoint] workflow normalized: {changed}")
PY
}
norm_workflows "${WF_DIRS[@]}"

# ---------- Start Services ----------
if [[ "${ENTRYPOINT_DRY}" = "1" ]]; then
  log "DRY: Ende (keine Server gestartet)."; exit 0
fi

log "Starte ComfyUI auf :${COMFYUI_PORT}"
( cd "${COMFYUI_BASE}" && python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" ) &

if [[ "${ENABLE_JUPYTER}" = "1" ]]; then
  log "Starte Jupyter auf :${JUPYTER_PORT}"
  ( jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser --NotebookApp.token='' --NotebookApp.password='' ) &
fi

wait -n || true

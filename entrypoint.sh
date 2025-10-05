\
#!/bin/sh
set -eu

say(){ printf "%b\n" "$*"; }

# ---------- ENV Defaults ----------
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=}"                          # auto-detect below
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
: "${HF_SYNC:=1}"                              # 1 = pull from HF
: "${HF_DELETE_EXTRAS:=0}"                     # 1 = rsync --delete
: "${ENTRYPOINT_DRY:=0}"                       # 1 = dry-run (no network)
: "${COMFYUI_PORT:=8188}"
: "${ENABLE_JUPYTER:=0}"
: "${JUPYTER_PORT:=8888}"

# HF token fallbacks
[ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

# ---------- ComfyUI base discovery ----------
if [ -z "${COMFYUI_BASE}" ]; then
  for d in "/workspace/ComfyUI" "/root/ComfyUI" "/opt/ComfyUI" "/content/ComfyUI"; do
    if [ -d "$d" ]; then COMFYUI_BASE="$d"; break; fi
  done
  [ -n "${COMFYUI_BASE}" ] || COMFYUI_BASE="/content/ComfyUI"
fi
say "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"

# Common paths
MODELS="${WORKSPACE}/models"
CKPTS="${WORKSPACE}/annotators/ckpts"
CNODES="${WORKSPACE}/custom_nodes"
WFS="${WORKSPACE}/workflows"
UX="${WORKSPACE}/web_extensions/userstyle"
AUX_DIR="${CNODES}/comfyui_controlnet_aux"
AUX_MODELS="${AUX_DIR}/models"

mkdir -p "${MODELS}/checkpoints" "${MODELS}/loras" "${MODELS}/controlnet" \
         "${CKPTS}" "${CNODES}" "${WFS}" "${UX}" "${AUX_MODELS}"

# ---------- helpers ----------
safe_copy() {
  SRC="$1"; DST="$2"
  [ -d "$SRC" ] || return 0
  mkdir -p "$DST"
  if command -v rsync >/dev/null 2>&1; then
    if [ "${HF_DELETE_EXTRAS}" = "1" ]; then
      rsync -a --delete "${SRC}/" "${DST}/" || true
    else
      rsync -a          "${SRC}/" "${DST}/" || true
    fi
  else
    cp -a "${SRC}/." "${DST}/" || true
  fi
}

dl() {
  URL="$1"; OUT="$2"
  [ -s "${OUT}" ] && return 0
  mkdir -p "$(dirname "${OUT}")"
  say "[entrypoint] ↓ $(basename "${OUT}")"
  (curl -L --fail -o "${OUT}" "${URL}" >/dev/null 2>&1) || (wget -q -O "${OUT}" "${URL}") || true
}

# ---------- NSFW bypass (CSS) ----------
USERCSS="${UX}/user.css"
if [ ! -f "${USERCSS}" ]; then
  cat > "${USERCSS}" <<'CSS'
/* remove/override any moderation blur & warnings */
* [class*="moderation"], .moderation, .nsfw, .blur, .nsfw-blur { display: none !important; visibility: hidden !important; }
img, canvas, video { filter: none !important; }
CSS
  say "[entrypoint] NSFW bypass CSS gesetzt."
fi

# ---------- Ensure huggingface_hub before using it ----------
if [ "${ENTRYPOINT_DRY}" != "1" ] && [ "${HF_SYNC}" = "1" ]; then
  python3 -m pip install -q --no-cache-dir "huggingface_hub>=0.35.0" || true
fi

# ---------- Hugging Face snapshot (optional) ----------
STAGE="${WORKSPACE}/.hf_stage"
if [ "${ENTRYPOINT_DRY}" = "1" ]; then
  say "[entrypoint] DRY: HF-Sync übersprungen."
else
  if [ "${HF_SYNC}" = "1" ]; then
    mkdir -p "${STAGE}"
    python3 - "$@" <<'PY'
import os, sys
try:
    from huggingface_hub import snapshot_download
except Exception as e:
    print("[entrypoint] [HF] WARN: huggingface_hub fehlt oder ist defekt:", e)
    sys.exit(0)

repo_id = os.environ.get("HF_REPO_ID", "")
revision = os.environ.get("HF_BRANCH", "main")
local_dir = os.environ.get("STAGE", "/workspace/.hf_stage")
token = os.environ.get("HF_TOKEN") or None

print(f"[entrypoint] [HF] snapshot_download: {repo_id}@{revision}")
try:
    snapshot_download(
        repo_id=repo_id,
        revision=revision,
        local_dir=local_dir,
        local_dir_use_symlinks=False,
        token=token,
        repo_type="model",
    )
    print("[entrypoint] [HF] OK.")
except Exception as e:
    print("[entrypoint] [HF] WARN:", e)
    sys.exit(0)
PY
    # mirror to WORKSPACE layout
    safe_copy "${STAGE}/custom_nodes"             "${CNODES}"
    safe_copy "${STAGE}/annotators/ckpts"         "${CKPTS}"
    safe_copy "${STAGE}/models"                   "${MODELS}"
    safe_copy "${STAGE}/workflows"                "${WFS}"
    safe_copy "${STAGE}/web_extensions/userstyle" "${UX}"
  else
    say "[entrypoint] HF-Sync: skip."
  fi
fi

# ---------- controlnet_aux: ensure node ----------
if [ ! -d "${AUX_DIR}" ]; then
  say "[entrypoint] Clone controlnet_aux …"
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux "${AUX_DIR}" || true
  else
    TMP="/tmp/cnaux.zip"
    wget -q -O "$TMP" https://codeload.github.com/Fannovel16/comfyui_controlnet_aux/zip/refs/heads/master || true
    (cd "${CNODES}" && unzip -q "$TMP" && mv comfyui_controlnet_aux-* comfyui_controlnet_aux || true)
    rm -f "$TMP"
  fi
else
  (cd "${AUX_DIR}" && if [ -d .git ]; then git pull --ff-only || true; fi)
fi

# link into ComfyUI/custom_nodes so imports work
mkdir -p "${COMFYUI_BASE}/custom_nodes"
if [ ! -e "${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux" ]; then
  ln -s "${AUX_DIR}" "${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux" 2>/dev/null || cp -r "${AUX_DIR}" "${COMFYUI_BASE}/custom_nodes/"
fi

# ---------- controlnet_aux: dependencies ----------
python3 -m pip install -q --no-warn-script-location -U opencv-python onnx onnxruntime || true
REQ="${AUX_DIR}/requirements.txt"
if [ -f "${REQ}" ]; then
  python3 -m pip install -q --no-warn-script-location -r "${REQ}" || true
fi

# ---------- Models (OpenPose & DWPose) ----------
# OpenPose
dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/body_pose_model.pth" "${AUX_MODELS}/body_pose_model.pth"
dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/hand_pose_model.pth" "${AUX_MODELS}/hand_pose_model.pth"
dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/openpose/face_pose_model.pth" "${AUX_MODELS}/face_pose_model.pth"
# DWPose
dl "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"         "${AUX_MODELS}/yolox_l.onnx"
dl "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.onnx" "${AUX_MODELS}/dw-ll_ucoco_384.onnx"
dl "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth"  "${AUX_MODELS}/dw-ll_ucoco_384.pth"

# mirror models into ComfyUI/models/controlnet-aux (optional)
MCN="${COMFYUI_BASE}/models/controlnet-aux"
mkdir -p "${MCN}"
for f in body_pose_model.pth hand_pose_model.pth face_pose_model.pth yolox_l.onnx dw-ll_ucoco_384.onnx dw-ll_ucoco_384.pth; do
  [ -s "${AUX_MODELS}/${f}" ] && cp -n "${AUX_MODELS}/${f}" "${MCN}/${f}" || true
done

# ---------- Legacy alias patch ----------
NW_INIT="${AUX_DIR}/node_wrappers/__init__.py"
if [ -f "${NW_INIT}" ] && ! grep -q "BEGIN comfy-runpod legacy alias patch" "${NW_INIT}"; then
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
  say "[entrypoint] Alias-Patch gesetzt."
fi

# ---------- Normalize workflows (old → new class names) ----------
python3 - "$@" <<'PY'
import os, re, sys
def walk_jsons(base):
    if not os.path.isdir(base): return
    for r,_,fs in os.walk(base):
        for fn in fs:
            if fn.lower().endswith(".json"):
                yield os.path.join(r, fn)

bases = []
for k in ("WORKSPACE", "COMFYUI_BASE"):
    v = os.environ.get(k)
    if v:
        wf = os.path.join(v, "workflows")
        if os.path.isdir(wf): bases.append(wf)

REPL = {
    r'"controlnet_aux\.OpenposePreprocessor"': '"controlnet_aux.OpenPosePreprocessor"',
    r'"controlnet_aux\.DWposePreprocessor"'  : '"controlnet_aux.DWPosePreprocessor"',
    r'"controlnet_aux\.OpenposeDetector"'    : '"controlnet_aux.OpenPoseDetector"',
    r'"controlnet_aux\.DWposeDetector"'      : '"controlnet_aux.DWPoseDetector"',
}

fixed = 0
for base in set(bases):
    for p in walk_jsons(base):
        try:
            s = open(p, "r", encoding="utf-8").read()
            s2 = s
            for pat, rep in REPL.items():
                s2 = re.sub(pat, rep, s2)
            if s2 != s:
                open(p, "w", encoding="utf-8").write(s2)
                fixed += 1
        except Exception as e:
            print("[entrypoint] workflow patch warn:", p, e)
print(f"[entrypoint] workflow normalized: {fixed}")
PY

# ---------- Dry stop ----------
if [ "${ENTRYPOINT_DRY}" = "1" ]; then
  say "[entrypoint] DRY: Ende (keine Server gestartet)."
  exit 0
fi

# ---------- Start ComfyUI (+ optional Jupyter) ----------
export PYTHONPATH="${COMFYUI_BASE}/custom_nodes:${PYTHONPATH:-}"
cd "${COMFYUI_BASE}"
say "[entrypoint] Starte ComfyUI auf :${COMFYUI_PORT}"
python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" >/workspace/comfyui.log 2>&1 &

if [ "${ENABLE_JUPYTER}" = "1" ]; then
  say "[entrypoint] Starte Jupyter auf :${JUPYTER_PORT}"
  jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --NotebookApp.token='' --NotebookApp.password='' >/workspace/jupyter.log 2>&1 &
fi

wait

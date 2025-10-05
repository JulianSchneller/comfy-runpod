#!/bin/sh
set -eu

# ---------- ENV Defaults ----------
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=}"
: "${HF_REPO_ID:=}"          # z.B. Floorius/comfyui-model-bundle
: "${HF_BRANCH:=main}"
: "${HF_SYNC:=1}"            # 1 = HF-Bundle ziehen (wenn Token da), 0 = skip
: "${HF_DELETE_EXTRAS:=0}"   # 1 = rsync --delete beim Spiegeln
: "${ENTRYPOINT_DRY:=0}"     # 1 = keine Netz-Downloads (Test)
: "${COMFYUI_PORT:=8188}"

# HF Token Varianten akzeptieren
[ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

# ---------- ComfyUI-Basis finden ----------
if [ -z "${COMFYUI_BASE}" ]; then
  for d in "${WORKSPACE}/ComfyUI" "/opt/ComfyUI" "/workspace/ComfyUI" "/content/ComfyUI" "/ComfyUI"; do
    if [ -d "$d" ]; then COMFYUI_BASE="$d"; break; fi
  done
fi
if [ -z "${COMFYUI_BASE}" ]; then
  echo "[entrypoint] ❌ ComfyUI Basis nicht gefunden."; exit 1
fi
echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"
mkdir -p "${WORKSPACE}" \
         "${COMFYUI_BASE}/custom_nodes" \
         "${COMFYUI_BASE}/models" \
         "${COMFYUI_BASE}/workflows"

# ---------- (Optional) HF-Bundle spiegeln ----------
STAGE="${WORKSPACE}/hf_stage"
if [ "${HF_SYNC}" = "1" ] && [ -n "${HF_REPO_ID}" ] && [ -n "${HF_TOKEN:-}" ] && [ "${ENTRYPOINT_DRY}" != "1" ]; then
  mkdir -p "${STAGE}"
  echo "[entrypoint] [HF] snapshot_download: ${HF_REPO_ID}@${HF_BRANCH}"
  python3 - "$HF_REPO_ID" "$HF_BRANCH" "$STAGE" <<'PY'
import os, sys
from huggingface_hub import snapshot_download
repo_id, branch, dst = sys.argv[1:]
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
if not token:
    sys.exit(0)
snapshot_download(repo_id=repo_id, revision=branch, local_dir=dst, local_dir_use_symlinks=False, token=token)
print("[entrypoint] HF snapshot OK ->", dst)
PY

  # Helper rsync-Funktion
  rs() {
    SRC="$1"; DST="$2"
    [ -d "$SRC" ] || return 0
    mkdir -p "$DST"
    if [ "${HF_DELETE_EXTRAS}" = "1" ]; then
      rsync -a --delete "${SRC}/" "${DST}/" || true
    else
      rsync -a          "${SRC}/" "${DST}/" || true
    fi
  }

  # Spiegeln nach WORKSPACE
  rs "${STAGE}/custom_nodes"            "${WORKSPACE}/custom_nodes"
  rs "${STAGE}/annotators/ckpts"        "${WORKSPACE}/annotators/ckpts"
  rs "${STAGE}/models"                  "${WORKSPACE}/models"
  rs "${STAGE}/workflows"               "${WORKSPACE}/workflows"
  rs "${STAGE}/web_extensions/userstyle" "${WORKSPACE}/web_extensions/userstyle"
fi

# ---------- controlnet_aux (OpenPose/DWPose) – EIN Master-Block ----------
CN_DIR="${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux"

# Bevorzugt Version aus HF-Bundle verlinken
if [ ! -d "${CN_DIR}" ] && [ -d "${WORKSPACE}/custom_nodes/comfyui_controlnet_aux" ]; then
  ln -s "${WORKSPACE}/custom_nodes/comfyui_controlnet_aux" "${CN_DIR}"
fi

# Sonst von GitHub klonen (öffentl.)
if [ ! -d "${CN_DIR}" ]; then
  echo "[entrypoint] clone comfyui_controlnet_aux (public)…"
  git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux "${CN_DIR}" || true
fi

# Abhängigkeiten installieren (tolerant)
if [ -f "${CN_DIR}/requirements.txt" ]; then
  pip3 install --no-cache-dir -r "${CN_DIR}/requirements.txt" -q || true
fi
pip3 install --no-cache-dir opencv-python onnx onnxruntime -q || true

# Modelle bereitstellen
AUX_MODELS="${CN_DIR}/models"
mkdir -p "${AUX_MODELS}"

# Wenn HF annotators/ckpts existiert → Dateien verlinken (keine Duplikate)
CKPTS="${WORKSPACE}/annotators/ckpts"
if [ -d "${CKPTS}" ]; then
  for f in body_pose_model.pth hand_pose_model.pth facenet.pth yolox_l.onnx yolox_l.torchscript dw-ll_ucoco_384.pth dw-ll_ucoco_384.onnx; do
    [ -f "${CKPTS}/${f}" ] && ln -sf "${CKPTS}/${f}" "${AUX_MODELS}/${f}"
  done
fi

# Fallback-Download fehlender Dateien (nett + optional)
dl () { URL="$1"; OUT="$2"; [ -f "$OUT" ] && [ -s "$OUT" ] && return 0; echo "[entrypoint] dl $(basename "$OUT")"; curl -L --fail --retry 3 -o "$OUT" "$URL" || true; }
if [ "${ENTRYPOINT_DRY}" != "1" ]; then
  # OpenPose
  dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/body_pose_model.pth" "${AUX_MODELS}/body_pose_model.pth"
  dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/hand_pose_model.pth" "${AUX_MODELS}/hand_pose_model.pth"
  # Optional – nicht mehr immer vorhanden, daher tolerant
  dl "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/facenet.pth"         "${AUX_MODELS}/facenet.pth"
  # DWPose
  dl "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"            "${AUX_MODELS}/yolox_l.onnx"
  dl "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth"     "${AUX_MODELS}/dw-ll_ucoco_384.pth"
fi

# Legacy-Alias-Patch (einmalig)
INIT_PY="${CN_DIR}/node_wrappers/__init__.py"
if [ -f "${INIT_PY}" ] && ! grep -q "BEGIN comfy-runpod legacy alias patch" "${INIT_PY}" 2>/dev/null; then
  cat >> "${INIT_PY}" <<'PY'
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

# Workflow-Normalisierung (alte Klassennamen → neue)
python3 - <<'PY'
import os, re
dirs = [
    "/workspace/workflows",
    "/content/workspace/workflows",
    "/workspace/ComfyUI/workflows",
    "/content/ComfyUI/workflows",
]
repls = {
    r'"controlnet_aux\.OpenposePreprocessor"': '"controlnet_aux.OpenPosePreprocessor"',
    r'"controlnet_aux\.DWposePreprocessor"':   '"controlnet_aux.DWPosePreprocessor"',
    r'"controlnet_aux\.OpenposeDetector"':     '"controlnet_aux.OpenPoseDetector"',
    r'"controlnet_aux\.DWposeDetector"':       '"controlnet_aux.DWPoseDetector"',
}
n=0
for d in dirs:
    if not os.path.isdir(d): continue
    for root,_,files in os.walk(d):
        for fn in files:
            if fn.lower().endswith(".json"):
                p = os.path.join(root, fn)
                try:
                    s = open(p,"r",encoding="utf-8").read()
                    s2 = s
                    for k,v in repls.items():
                        s2 = re.sub(k, v, s2)
                    if s2 != s:
                        open(p,"w",encoding="utf-8").write(s2); n+=1
                except Exception:
                    pass
print("[entrypoint] workflow normalize:", n)
PY

# ---------- ComfyUI starten ----------
cd "${COMFYUI_BASE}"
export PYTHONPATH="${COMFYUI_BASE}:${COMFYUI_BASE}/custom_nodes:${PYTHONPATH:-}"
exec python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" --enable-cors-header "*"

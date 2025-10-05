\
#!/bin/sh
# minimal-stabile entrypoint ohne Pose (OpenPose/DWPose)
# Features: NSFW-CSS, optional HF-Sync (guarded), optional Jupyter, ComfyUI-Start

set -eu

# -------- Defaults / ENV --------
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=}"
: "${COMFYUI_PORT:=8188}"
: "${ENABLE_JUPYTER:=0}"
: "${JUPYTER_PORT:=8888}"

: "${HF_SYNC:=1}"                          # 1=Download versuchen, 0=skip
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
# HF_TOKEN optional über env (HF_TOKEN oder HUGGINGFACE_HUB_TOKEN)
[ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

# -------- ComfyUI Base ermitteln --------
if [ -z "${COMFYUI_BASE}" ]; then
  if [ -d "/workspace/ComfyUI" ]; then
    COMFYUI_BASE="/workspace/ComfyUI"
  elif [ -d "/content/ComfyUI" ]; then
    COMFYUI_BASE="/content/ComfyUI"
  else
    COMFYUI_BASE="/content/ComfyUI"
    mkdir -p "${COMFYUI_BASE}"
  fi
fi
echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"

# -------- Verzeichnisse anlegen --------
MODELS_BASE="${WORKSPACE}/models"
CHECKPOINTS="${MODELS_BASE}/checkpoints"
LORAS="${MODELS_BASE}/loras"
CONTROLNET="${MODELS_BASE}/controlnet"
AUX="${MODELS_BASE}/controlnet-aux"
ANNOTATORS="${WORKSPACE}/annotators/ckpts"
WEBEXT="${WORKSPACE}/web_extensions/userstyle"

mkdir -p "${CHECKPOINTS}" "${LORAS}" "${CONTROLNET}" "${AUX}" "${ANNOTATORS}" "${WEBEXT}"

# -------- NSFW CSS (Bypass) --------
CSS="${WEBEXT}/style.css"
if [ ! -f "${CSS}" ]; then
cat > "${CSS}" <<'CSS'
/* minimal NSFW overlay removal */
.safety_warning, .nsfw, .blur { display: none !important; visibility: hidden !important; filter: none !important; }
CSS
echo "[entrypoint] NSFW bypass CSS gesetzt."
fi

# -------- Optional: Hugging Face Sync (ohne Pose-spezifische Pfade) --------
if [ "${HF_SYNC}" = "1" ] && [ -n "${HF_REPO_ID}" ]; then
  echo "[entrypoint] [HF] snapshot_download: ${HF_REPO_ID}@${HF_BRANCH}"
  python3 - "$HF_REPO_ID" "$HF_BRANCH" "$WORKSPACE/_bundle" "$HF_TOKEN" <<'PY'
import sys, os
from huggingface_hub import snapshot_download
repo_id, branch, out_dir, token = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
kwargs = dict(repo_id=repo_id, revision=branch, local_dir=out_dir)
if token: kwargs["token"] = token
snapshot_download(**kwargs)
print("[entrypoint] HF download ok →", out_dir)
PY

  # Wichtige Ordner rüberkopieren (nicht löschen, kein Pose-Special)
  rsync() { rsync -a --ignore-existing "$1" "$2" 2>/dev/null || cp -r "$1" "$2" 2>/dev/null || true; }
  [ -d "${WORKSPACE}/_bundle/models/checkpoints" ] && rsync "${WORKSPACE}/_bundle/models/checkpoints/" "${CHECKPOINTS}/"
  [ -d "${WORKSPACE}/_bundle/models/loras" ]      && rsync "${WORKSPACE}/_bundle/models/loras/"      "${LORAS}/"
  [ -d "${WORKSPACE}/_bundle/models/controlnet" ] && rsync "${WORKSPACE}/_bundle/models/controlnet/" "${CONTROLNET}/"
  [ -d "${WORKSPACE}/_bundle/custom_nodes" ]      && rsync "${WORKSPACE}/_bundle/custom_nodes/"      "${COMFYUI_BASE}/custom_nodes/"
  [ -d "${WORKSPACE}/_bundle/web_extensions" ]    && rsync "${WORKSPACE}/_bundle/web_extensions/"    "${WORKSPACE}/web_extensions/"
  [ -d "${WORKSPACE}/_bundle/annotators/ckpts" ]  && rsync "${WORKSPACE}/_bundle/annotators/ckpts/"  "${ANNOTATORS}/"
else
  echo "[entrypoint] HF-Sync: skip"
fi

# -------- Optional: Jupyter --------
if [ "${ENABLE_JUPYTER}" = "1" ]; then
  echo "[entrypoint] Starte JupyterLab auf :${JUPYTER_PORT} …"
  nohup jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser >/tmp/jupyter.log 2>&1 &
fi

# -------- ComfyUI starten --------
cd "${COMFYUI_BASE}"
echo "[entrypoint] Starte ComfyUI auf :${COMFYUI_PORT} …"
exec python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}"

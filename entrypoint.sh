#!/bin/sh
set -eu

# -------- Defaults / ENV --------
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
: "${HF_SYNC:=1}"                 # 1=ziehen, 0=skip
: "${HF_DELETE_EXTRAS:=0}"        # 1=rsync --delete
: "${ENTRYPOINT_DRY:=0}"          # 1=kein Netz/Download
: "${COMFYUI_PORT:=8188}"
: "${ENABLE_JUPYTER:=0}"
: "${JUPYTER_PORT:=8888}"
: "${HF_REQUIRE_TOKEN:=1}"        # 1=Token Pflicht, 0=auch ohne
: "${START_COMFYUI:=1}"

# Optional: HF Cache + TF Loglevel
: "${HF_HOME:=${WORKSPACE}/.cache/huggingface}"; export HF_HOME; mkdir -p "$HF_HOME"
: "${TF_CPP_MIN_LOG_LEVEL:=2}"; export TF_CPP_MIN_LOG_LEVEL

# HUGGINGFACE Token varianten
[ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

# ComfyUI Basis finden (RunPod / Docker)
if [ -z "${COMFYUI_BASE}" ]; then
  for p in "/workspace/ComfyUI" "/content/ComfyUI"; do
    [ -d "$p" ] && COMFYUI_BASE="$p" && break
  done
  [ -n "$COMFYUI_BASE" ] || COMFYUI_BASE="/workspace/ComfyUI"
fi
echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"

# Models-Struktur
mkdir -p "${WORKSPACE}/workspace/models/checkpoints" \
         "${WORKSPACE}/workspace/models/loras" \
         "${WORKSPACE}/workspace/models/controlnet" \
         "${WORKSPACE}/workspace/annotators/ckpts" \
         "${WORKSPACE}/workspace/web_extensions/userstyle" \
         "${WORKSPACE}/workspace/workflows"

# ---------- HF-Sync ----------
if [ "$ENTRYPOINT_DRY" = "1" ]; then
  echo "[entrypoint] HF-Sync: skip (dry/no token)"
else
  if [ "$HF_SYNC" = "1" ]; then
    if [ "$HF_REQUIRE_TOKEN" = "1" ] && [ -z "${HF_TOKEN:-}" ]; then
      echo "[entrypoint] ⚠️ Kein HF_TOKEN gesetzt → Sync übersprungen"; 
    else
      echo "[entrypoint] [HF] snapshot_download: ${HF_REPO_ID}"
      python3 - "$HF_REPO_ID" "$HF_BRANCH" "$WORKSPACE" "$HF_TOKEN" <<'PY'
import sys, os
from huggingface_hub import snapshot_download

repo_id, branch, workspace, token = sys.argv[1:5]
local_dir = os.path.join(workspace,"workspace")
try:
    snapshot_download(
        repo_id=repo_id,
        revision=branch,
        local_dir=local_dir,
        token=token if token else None
    )
    print("[entrypoint] HF-Sync OK")
except Exception as e:
    print("[entrypoint] ⚠️ HF-Sync Fehler:", e)
PY
    fi
  fi
fi

# ---------- Annotator Symlinks ----------
AUX="${WORKSPACE}/workspace/annotators/ckpts"
CN1="${WORKSPACE}/workspace/custom_nodes/comfyui_controlnet_aux/ckpts"
CN2="${WORKSPACE}/workspace/custom_nodes/comfyui_controlnet_aux/annotator/ckpts"
mkdir -p "$(dirname "$CN1")" "$(dirname "$CN2")"
ln -sf "$AUX" "$CN1" || true
ln -sf "$AUX" "$CN2" || true

# ---------- Optional Jupyter ----------
if [ "$ENABLE_JUPYTER" = "1" ]; then
  echo "[entrypoint] Jupyter-Server starten (Port ${JUPYTER_PORT})"
  jupyter notebook --ip=0.0.0.0 --port="${JUPYTER_PORT}" --allow-root &
fi

# ---------- Optional ComfyUI ----------
if [ "$START_COMFYUI" = "1" ]; then
  echo "[entrypoint] Starte ComfyUI (Port ${COMFYUI_PORT})"
  cd "${COMFYUI_BASE}" && python3 main.py --listen --port "${COMFYUI_PORT}" ${EXTRA_COMFY_ARGS:-}
else
  echo "[entrypoint] START_COMFYUI=0 → kein ComfyUI-Start"
fi

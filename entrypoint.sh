\
    #!/bin/sh
    set -eu

    # -------- Defaults / ENV --------
    : "${WORKSPACE:=/workspace}"
    : "${COMFYUI_BASE:=}"
    : "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
    : "${HF_BRANCH:=main}"
    : "${HF_SYNC:=1}"                 # 1=ziehen, 0=skip
    : "${HF_DELETE_EXTRAS:=0}"        # ungenutzt; wir löschen nichts
    : "${ENTRYPOINT_DRY:=0}"          # 1=kein Netz/Download
    : "${COMFYUI_PORT:=8188}"
    : "${ENABLE_JUPYTER:=0}"
    : "${JUPYTER_PORT:=8888}"

    # Tokens (HF optional)
    [ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

    # ComfyUI-Basis finden (RunPod/Docker/Colab)
    if [ -z "${COMFYUI_BASE}" ]; then
      for d in "/workspace/ComfyUI" "/content/ComfyUI" "/ComfyUI" "/root/ComfyUI"; do
        if [ -d "$d" ]; then COMFYUI_BASE="$d"; break; fi
      done
      [ -n "${COMFYUI_BASE}" ] || COMFYUI_BASE="/content/ComfyUI"
      mkdir -p "${COMFYUI_BASE}"
    fi
    echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"

    # Ordnerstruktur
    MODELS_BASE="${WORKSPACE}/models"
    mkdir -p "${MODELS_BASE}/checkpoints" "${MODELS_BASE}/loras" "${MODELS_BASE}/controlnet"
    mkdir -p "${WORKSPACE}/web_extensions/userstyle"

    # ---------- NSFW Bypass (nur CSS) ----------
    cat > "${WORKSPACE}/web_extensions/userstyle/no_nsfw.css" <<'CSS'
    .nsfw-placeholder, .nsfw-warning, .nsfw_overlay { display: none !important; }
    CSS
    echo "[entrypoint] NSFW bypass CSS gesetzt."

    # ---------- HF Sync (ohne Pose, keine Pflicht) ----------
    if [ "${ENTRYPOINT_DRY}" = "1" ]; then
      echo "[entrypoint] DRY: HF-Sync übersprungen."
    else
      if [ "${HF_SYNC}" = "1" ] && [ -n "${HF_REPO_ID}" ]; then
        echo "[entrypoint] [HF] snapshot_download: ${HF_REPO_ID}@${HF_BRANCH}"
        python3 - "$HF_REPO_ID" "$HF_BRANCH" <<'PY'
import os, sys, subprocess
rid = sys.argv[1]; rev = sys.argv[2]
dst = "/workspace/hf_stage"
tok = os.environ.get("HF_TOKEN") or None
try:
    import huggingface_hub  # noqa
except Exception:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-U", "huggingface_hub==0.35.3"])
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id=rid, revision=rev, local_dir=dst, local_dir_use_symlinks=False, token=tok
)
PY
        rsync -a --ignore-existing /workspace/hf_stage/ "${WORKSPACE}/"
      fi
    fi

    # ---------- WICHTIG: KEIN Pose-Kram ----------
    # - Kein controlnet_aux, kein OpenPose/DWPose, keine Aliase, keine Model-Downloads.

    # ---------- Optional: Jupyter ----------
    if [ "${ENABLE_JUPYTER}" = "1" ]; then
      jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser --NotebookApp.token='' \
        --NotebookApp.password='' --allow-root >/dev/null 2>&1 &
      echo "[entrypoint] Jupyter gestartet auf Port ${JUPYTER_PORT}."
    fi

    # ---------- ComfyUI starten ----------
    if [ "${ENTRYPOINT_DRY}" = "1" ]; then
      echo "[entrypoint] DRY: Ende (keine Server gestartet)."
      exit 0
    fi

    cd "${COMFYUI_BASE}"
    # Port & Listen
    exec python3 -u main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}"

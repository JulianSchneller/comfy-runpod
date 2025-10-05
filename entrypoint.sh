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

# HUGGINGFACE Token varianten
[ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

# ComfyUI Basis finden (RunPod / Docker)
if [ -z "${COMFYUI_BASE}" ]; then
  if [ -d "/workspace/ComfyUI" ]; then COMFYUI_BASE="/workspace/ComfyUI";
  elif [ -d "/content/ComfyUI" ]; then COMFYUI_BASE="/content/ComfyUI";
  else COMFYUI_BASE="/workspace/ComfyUI"; fi
fi

echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"

MODELS_DIR="${WORKSPACE}/models"
ANNO_DIR="${WORKSPACE}/annotators/ckpts"
WE_EXT="${WORKSPACE}/web_extensions/userstyle"

mkdir -p "${MODELS_DIR}/checkpoints" \
         "${MODELS_DIR}/loras" \
         "${MODELS_DIR}/controlnet" \
         "${ANNO_DIR}" \
         "${WE_EXT}"

# NSFW-Bypass (Comfy Manager & SDXL Pipeline patterns)
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' || true
import re, sys, pathlib
roots = [pathlib.Path("/workspace/ComfyUI"), pathlib.Path("/content/ComfyUI")]
for base in roots:
    if not base.exists(): continue
    for p in base.rglob("*.py"):
        try:
            s = p.read_text(encoding="utf-8")
        except Exception:
            continue
        orig = s
        s = re.sub(r'block_nsfw\s*:\s*Optional\[bool\]\s*=\s*None', 'block_nsfw: Optional[bool] = False', s)
        s = re.sub(r'block_nsfw\s*=\s*True', 'block_nsfw=False', s)
        s = re.sub(r'safety[_ ]?checker\s*=\s*[^,\n)]+', 'safety_checker=None', s)
        if s != orig:
            try:
                p.write_text(s, encoding="utf-8")
                print(f"[nsfw] patched: {p}")
            except Exception:
                pass
print("[nsfw] done")
PY
fi

# HF Sync (Workflows, Nodes, CKPTs, Web-Extensions) — optional
if [ "${HF_SYNC}" = "1" ] && [ "${ENTRYPOINT_DRY}" = "0" ]; then
  if [ -z "${HF_TOKEN:-}" ]; then
    echo "[entrypoint] ⚠️ HF-Sync übersprungen (kein Token gesetzt)."
  else
    echo "[entrypoint] [HF] snapshot_download: ${HF_REPO_ID}"
python3 -m pip install --no-cache-dir --upgrade huggingface_hub || { echo "[entrypoint] ⚠️ WARN: konnte huggingface_hub nicht installieren"; }
    python3 - <<PY
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="${HF_REPO_ID}",
    repo_type="model",
    revision="${HF_BRANCH}",
    local_dir="${WORKSPACE}",
    local_dir_use_symlinks=False,
    token="${HF_TOKEN}"
)
print("[hf] snapshot ok")
PY
  fi
else
  echo "[entrypoint] HF-Sync: skip (dry/hf_sync=0)"
fi

# Symlink: annotators/ckpts -> ComfyUI/annotators/ckpts (falls benötigt)
mkdir -p "${COMFYUI_BASE}/annotators"
if [ ! -e "${COMFYUI_BASE}/annotators/ckpts" ]; then
  ln -s "${ANNO_DIR}" "${COMFYUI_BASE}/annotators/ckpts" || true
fi

# Optional Jupyter
if [ "${ENABLE_JUPYTER}" = "1" ]; then
  echo "[entrypoint] Jupyter unter Port ${JUPYTER_PORT}"
  jupyter lab --ServerApp.allow_origin="*" --no-browser --port="${JUPYTER_PORT}" &
fi

# ComfyUI Start
cd "${COMFYUI_BASE}"
echo "[entrypoint] Starte ComfyUI auf Port ${COMFYUI_PORT}"
python3 main.py --listen --port "${COMFYUI_PORT}"

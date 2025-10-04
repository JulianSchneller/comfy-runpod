#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[$(date +'%F %T')] $*"; }
retry(){ local n=0; local max="${2:-5}"; local sleep_s="${3:-2}"; until "$1"; do n=$((n+1)); if [[ $n -ge $max ]]; then return 1; fi; sleep $((sleep_s*n)); done; }

# -------------------------------
# 0) Defaults / ENV
# -------------------------------
export PYTHONUNBUFFERED=1
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
DATA_DIR="${DATA_DIR:-/workspace}"
HF_REPO_ID="${HF_REPO_ID:-}"        # z.B. Floorius/comfyui-model-bundle
HF_TOKEN="${HF_TOKEN:-}"            # optional (privates Repo / große Dateien)
HF_SYNC_FOLDERS="${HF_SYNC_FOLDERS:-custom_nodes annotators web_extensions workflows}"  # gezielte, leichte Pulls
PORT="${PORT:-8188}"
COMFY_FLAGS="${COMFY_FLAGS:---listen 0.0.0.0 --port ${PORT}}"
ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"

log "🚀 entrypoint.sh start"
mkdir -p "${DATA_DIR}" "${COMFY_DIR}"

# -------------------------------
# 1) Stelle ComfyUI sicher
# -------------------------------
if [[ ! -d "${COMFY_DIR}/.git" && ! -f "${COMFY_DIR}/main.py" ]]; then
  log "📦 ComfyUI fehlt → clone"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "${COMFY_DIR}"
fi

# -------------------------------
# 2) HuggingFace Sync (gezielt & idempotent)
# -------------------------------
hf_clone_path="${DATA_DIR}/.hf_repo"
hf_clone_cmd(){
  if [[ -n "${HF_TOKEN}" ]]; then
    GIT_ASKPASS=/bin/echo git clone --depth 1 "https://user:${HF_TOKEN}@huggingface.co/${HF_REPO_ID}" "${hf_clone_path}"
  else
    git clone --depth 1 "https://huggingface.co/${HF_REPO_ID}" "${hf_clone_path}"
  fi
}

if [[ -n "${HF_REPO_ID}" ]]; then
  log "🔗 HF_REPO_ID: ${HF_REPO_ID}"
  if [[ -d "${hf_clone_path}/.git" ]]; then
    log "🔄 HF pull"
    pushd "${hf_clone_path}" >/dev/null
    git lfs install --system || true
    git pull || true
    popd >/dev/null
  else
    log "⬇️  HF clone (light)"
    git lfs install --system || true
    if ! retry "bash -lc '$(declare -f hf_clone_cmd); hf_clone_cmd'"; then
      log "⚠️  HF Clone fehlgeschlagen – fahre ohne HF fort."
    fi
  fi
else
  log "ℹ️ Kein HF_REPO_ID gesetzt – überspringe Sync."
fi

rs(){
  # rs <src> <dst>
  [[ -d "$1" ]] || return 0
  mkdir -p "$2"
  rsync -a --update --ignore-existing --no-perms --no-owner --no-group "$1"/ "$2"/ || true
}

if [[ -d "${hf_clone_path}" ]]; then
  log "🧩 Übernehme ausgewählte Ordner: ${HF_SYNC_FOLDERS}"
  for d in ${HF_SYNC_FOLDERS}; do
    case "$d" in
      custom_nodes)
        rs "${hf_clone_path}/custom_nodes" "${COMFY_DIR}/custom_nodes"
        ;;
      annotators)
        # CKPTs für controlnet_aux (OpenPose/DWPose)
        rs "${hf_clone_path}/annotators/ckpts" "${COMFY_DIR}/custom_nodes/comfyui_controlnet_aux/ckpts"
        ;;
      web_extensions)
        # User-Styles & UI Mods
        rs "${hf_clone_path}/web_extensions" "${COMFY_DIR}/web/extensions/user"
        ;;
      workflows)
        # Workflows → ComfyUI user dir
        rs "${hf_clone_path}/workflows" "${COMFY_DIR}/user/default/workflows"
        ;;
      checkpoints)
        rs "${hf_clone_path}/checkpoints" "${COMFY_DIR}/models/checkpoints"
        ;;
      loras)
        rs "${hf_clone_path}/loras" "${COMFY_DIR}/models/loras"
        ;;
      controlnet)
        rs "${hf_clone_path}/controlnet" "${COMFY_DIR}/models/controlnet"
        ;;
      faces)
        rs "${hf_clone_path}/faces" "${COMFY_DIR}/models/insightface"
        ;;
      upscale_models)
        rs "${hf_clone_path}/upscale_models" "${COMFY_DIR}/models/upscale_models"
        ;;
      *)
        log "   • unbekannt: $d (übersprungen)"
        ;;
    esac
  done
fi

# -------------------------------
# 3) Optional: Requirements der Custom-Nodes nachinstallieren
# -------------------------------
log "📦 Prüfe requirements.txt in custom_nodes …"
find "${COMFY_DIR}/custom_nodes" -maxdepth 2 -type f -name "requirements.txt" | while read -r req; do
  log "   pip install -r ${req}"
  pip install --no-cache-dir -r "${req}" || true
done

# -------------------------------
# 4) NSFW-Bypass (best effort, no-op wenn nicht vorhanden)
# -------------------------------
log "⚠️  NSFW-Bypass aktivieren (best effort)"
export DISABLE_NSFW_FILTER=1
# Patch gängige safety_checker Implementationen (falls vorhanden)
python - <<'PY' || true
import os, re
from pathlib import Path

candidates = []
site = Path('/usr/local/lib/python3.*/dist-packages'.replace('*',''))
for p in [
    site / 'diffusers' / 'pipelines',
    Path('/workspace') ,
    Path('/opt')
]:
    if p.exists():
        candidates.extend(p.rglob('safety_checker.py'))

patched=0
for f in candidates:
    try:
        txt = f.read_text(encoding='utf-8', errors='ignore')
        new = re.sub(r'return\s+(.+?),\s*has_nsfw_concepts', r'return \1, False', txt)
        new = re.sub(r'return\s+has_nsfw_concepts', 'return False', new)
        if new != txt:
            f.write_text(new, encoding='utf-8')
            patched += 1
    except Exception:
        pass
print(f"Patched files: {patched}")
PY

# -------------------------------
# 5) Optional: Jupyter
# -------------------------------
if [[ "${ENABLE_JUPYTER}" == "1" ]]; then
  log "📓 Starte Jupyter Lab auf :${JUPYTER_PORT}"
  mkdir -p "${DATA_DIR}/.jupyter"
  jupyter lab --ip=0.0.0.0 --port="${JUPYTER_PORT}" \
    --NotebookApp.token='' --NotebookApp.password='' \
    --ServerApp.token='' --ServerApp.password='' \
    --no-browser --allow-root > "${DATA_DIR}/jupyter.log" 2>&1 &
fi

# -------------------------------
# 6) Start ComfyUI
# -------------------------------
log "▶️  Starte ComfyUI: ${COMFY_FLAGS}"
cd "${COMFY_DIR}"
# Logging
python main.py ${COMFY_FLAGS} 2>&1 | tee -a "${DATA_DIR}/comfyui.log"

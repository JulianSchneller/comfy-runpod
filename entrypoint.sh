#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------
# Konfiguration & Pfade
# ---------------------
export HF_REPO_ID="${HF_REPO_ID:-}"          # z.B. Floorius/comfyui-model-bundle
export HF_TOKEN="${HF_TOKEN:-}"              # optional (für private Repos)
export HF_SYNC="${HF_SYNC:-1}"               # 1=Modelle/Workflows/Web-Extensions aus HF syncen
export ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}" # 1=Jupyter starten
export INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}" # 1=requirements.txt in custom_nodes installieren
export COMFYUI_PORT="${COMFYUI_PORT:-8188}"

COMFY_ROOT="/workspace/ComfyUI"
MODELS="${COMFY_ROOT}/models"
CNODES="${COMFY_ROOT}/custom_nodes"
USER_WEB_EXT="${COMFY_ROOT}/web/extensions/user"
ANNOT_CKPTS="${MODELS}/annotators/ckpts"

log(){ echo -e "[entrypoint] $*"; }

mkdir -p \
  "${MODELS}/checkpoints" \
  "${MODELS}/loras" \
  "${MODELS}/controlnet" \
  "${MODELS}/upscale_models" \
  "${MODELS}/embeddings" \
  "${ANNOT_CKPTS}" \
  "${CNODES}" \
  "${USER_WEB_EXT}" \
  "${COMFY_ROOT}/workflows"

# ---------------------
# Hilfsfunktionen
# ---------------------
start_jupyter(){
  if [[ "${ENABLE_JUPYTER}" != "1" ]]; then return 0; fi
  log "Jupyter Notebook aktivieren …"
  if ! command -v jupyter >/dev/null 2>&1; then
    pip install -U notebook >/dev/null
  fi
  jupyter notebook \
    --NotebookApp.token='' \
    --NotebookApp.password='' \
    --ip=0.0.0.0 \
    --port=8888 \
    --no-browser \
    --allow-root \
    >/tmp/jupyter.log 2>&1 &
  log "Jupyter läuft auf Port 8888 (ohne Token/Passwort)."
}

nsfw_bypass(){
  # Patch für evtl. vorhandenen Diffusers Safety Checker (idempotent)
  python - <<'PY'
import glob
paths = glob.glob("/usr/local/lib/python*/site-packages/diffusers/pipelines/stable_diffusion/safety_checker.py") + \
        glob.glob("/usr/local/lib/python*/dist-packages/diffusers/pipelines/stable_diffusion/safety_checker.py")
patched = False
for p in paths:
    try:
        s = open(p, "r", encoding="utf-8").read()
        if "return images, has_nsfw_concept" in s and "[False]*len(images)" not in s:
            s = s.replace("return images, has_nsfw_concept", "return images, [False]*len(images)")
            open(p, "w", encoding="utf-8").write(s)
            print(f"[entrypoint] NSFW safety_checker.patch angewendet: {p}")
            patched = True
            break
    except Exception:
        pass
print("[entrypoint] NSFW bypass aktiv." if patched else "[entrypoint] Kein Diffusers-SafetyChecker gefunden (ok).")
PY
}

install_node_requirements(){
  if [[ "${INSTALL_NODE_REQS}" != "1" ]]; then return 0; fi
  log "Node-Requirements in custom_nodes installieren (falls vorhanden) …"
  shopt -s nullglob
  for d in "${CNODES}"/*; do
    if [[ -f "${d}/requirements.txt" ]]; then
      log "pip install -r ${d}/requirements.txt"
      pip install -r "${d}/requirements.txt" || true
    fi
  done
  shopt -u nullglob
}

ensure_controlnet_aux_symlink(){
  # Symlink: models/annotators/ckpts → custom_nodes/comfyui_controlnet_aux/ckpts
  local target="${CNODES}/comfyui_controlnet_aux/ckpts"
  if [[ -d "${CNODES}/comfyui_controlnet_aux" ]]; then
    mkdir -p "${ANNOT_CKPTS}"
    ln -sfn "${ANNOT_CKPTS}" "${target}"
    log "Symlink gesetzt: ${target} -> ${ANNOT_CKPTS}"
  else
    log "Hinweis: comfyui_controlnet_aux nicht gefunden (kommt ggf. durch HF_SYNC)."
  fi
}

sync_from_hf(){
  if [[ "${HF_SYNC}" != "1" ]]; then
    log "HF_SYNC=0 → Überspringe HuggingFace-Sync."
    return 0
  fi
  if [[ -z "${HF_REPO_ID}" ]]; then
    log "⚠️  HF_SYNC=1 aber HF_REPO_ID ist leer → Überspringe Sync."
    return 0
  fi

  # Sicherstellen, dass huggingface_hub vorhanden ist
  pip show huggingface_hub >/dev/null 2>&1 || pip install -U huggingface_hub

  log "HuggingFace-Sync aus '${HF_REPO_ID}' starten …"
  python - <<'PY'
import os, shutil
from pathlib import Path
from huggingface_hub import snapshot_download

repo_id = os.environ.get("HF_REPO_ID")
token   = os.environ.get("HF_TOKEN") or None

COMFY   = Path("/workspace/ComfyUI")
MODELS  = COMFY / "models"
CNODES  = COMFY / "custom_nodes"
USERWEB = COMFY / "web" / "extensions" / "user"

dst = {
    "checkpoints": MODELS/"checkpoints",
    "loras": MODELS/"loras",
    "controlnet": MODELS/"controlnet",
    "upscale_models": MODELS/"upscale_models",
    "annotators/ckpts": MODELS/"annotators"/"ckpts",
    "custom_nodes/comfyui_controlnet_aux": CNODES/"comfyui_controlnet_aux",
    "web_extensions/userstyle": USERWEB,
    "workflows": COMFY/"workflows"
}
for p in dst.values(): p.mkdir(parents=True, exist_ok=True)

tmp = Path("/tmp/hf_bundle")
if tmp.exists(): shutil.rmtree(tmp)
tmp.mkdir(parents=True, exist_ok=True)

local_dir = snapshot_download(
    repo_id=repo_id,
    repo_type="model",
    token=token,
    local_dir=str(tmp),
    local_dir_use_symlinks=False,
)

def copy_tree(src: Path, dst: Path, only_js=None):
    if not src.exists(): return
    dst.mkdir(parents=True, exist_ok=True)
    for root, _, files in os.walk(src):
        r = Path(root)
        rel = r.relative_to(src)
        (dst/rel).mkdir(parents=True, exist_ok=True)
        for f in files:
            if only_js and not f.endswith(".js"):
                continue
            s = r/f
            d = (dst/rel)/f
            if not d.exists() or s.stat().st_mtime > d.stat().st_mtime:
                shutil.copy2(s, d)

mapping = [
    ("checkpoints", "checkpoints"),
    ("loras", "loras"),
    ("controlnet", "controlnet"),
    ("upscale_models", "upscale_models"),
    ("annotators/ckpts", "annotators/ckpts"),
    ("custom_nodes/comfyui_controlnet_aux", "custom_nodes/comfyui_controlnet_aux"),
    ("web_extensions/userstyle", "web_extensions/userstyle"),  # nur .js
    ("workflows", "workflows"),
]
for src_rel, dst_rel in mapping:
    s = tmp / src_rel
    d = dst[dst_rel]
    if src_rel == "web_extensions/userstyle":
        copy_tree(s, d, only_js=True)
    else:
        copy_tree(s, d)

print("[entrypoint] HF-Sync abgeschlossen.")
PY
}

start_comfy(){
  cd "${COMFY_ROOT}"
  log "Starte ComfyUI auf Port ${COMFYUI_PORT} …"
  python main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}"
}

# ---------------------
# Ablauf
# ---------------------
log "Entry gestartet. COMFYUI_ROOT=${COMFY_ROOT}"
nsfw_bypass
sync_from_hf
ensure_controlnet_aux_symlink
install_node_requirements
start_jupyter
start_comfy

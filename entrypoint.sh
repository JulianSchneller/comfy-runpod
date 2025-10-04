#!/usr/bin/env bash
set -Eeuo pipefail

# ======================= Config / Environment =======================
: "${COMFYUI_ROOT:=/workspace/ComfyUI}"
: "${PORT:=8188}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
: "${ENABLE_JUPYTER:=0}"
: "${AUTO_QUEUE:=0}"

LOG(){ echo -e "[$(date +'%H:%M:%S')] $*"; }

# ======================= Preflight =================================
PYBIN="$(command -v python3 || command -v python)"
PIPBIN="$PYBIN -m pip"

LOG "Python: $($PYBIN -V)"
$PIPBIN install -q --upgrade pip
# Bewährte Hub-Version
$PIPBIN install -q "huggingface_hub==0.35.3"

# ----------------------- HF Login (optional) -----------------------
if [[ -n "${HF_TOKEN:-}" ]]; then
  LOG "HF login …"
  $PYBIN - <<PY
from huggingface_hub import login
login(token="${HF_TOKEN}", add_to_git_credential=True)
print("HF login ok.")
PY
else
  LOG "HF login übersprungen (kein HF_TOKEN gesetzt)"
fi

# ======================= ComfyUI holen/aktualisieren ===============
if [[ ! -d "${COMFYUI_ROOT}/.git" ]]; then
  LOG "ComfyUI nicht gefunden – clone …"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_ROOT}"
else
  LOG "ComfyUI vorhanden – pull --rebase …"
  git -C "${COMFYUI_ROOT}" pull --rebase --autostash || true
fi

# ======================= HF Snapshot → Stage =======================
STAGE="/workspace/hf_stage"
mkdir -p "${STAGE}"

LOG "HF snapshot → ${STAGE}"
$PYBIN - <<PY
import os
from huggingface_hub import snapshot_download
repo_id = os.environ.get("HF_REPO_ID","Floorius/comfyui-model-bundle")
branch  = os.environ.get("HF_BRANCH","main")
token   = os.environ.get("HF_TOKEN")
local   = os.environ.get("STAGE","/workspace/hf_stage")

# Selektiv erlauben:
allow = [
  "workflows/*.json",
  "custom_nodes/**",
  "annotators/ckpts/**",
  "web_extensions/**",
]
print("  repo :", repo_id)
print("  branch:", branch)
print("  allow :", allow)
snapshot_download(
    repo_id=repo_id,
    revision=branch,
    local_dir=local,
    allow_patterns=allow,
    token=token,
    local_dir_use_symlinks=False,
)
print("Snapshot ok.")
PY

# ======================= Sync Mapping ==============================
shopt -s dotglob nullglob

# Workflows → user/workflows
if [[ -d "${STAGE}/workflows" ]]; then
  LOG "Sync workflows → user/workflows"
  mkdir -p "${COMFYUI_ROOT}/user/workflows"
  rsync -a --delete "${STAGE}/workflows/" "${COMFYUI_ROOT}/user/workflows/"
fi

# Custom Nodes → custom_nodes
if [[ -d "${STAGE}/custom_nodes" ]]; then
  LOG "Sync custom_nodes → ComfyUI/custom_nodes"
  mkdir -p "${COMFYUI_ROOT}/custom_nodes"
  rsync -a "${STAGE}/custom_nodes/" "${COMFYUI_ROOT}/custom_nodes/"
fi

# Annotator CKPTs
if [[ -d "${STAGE}/annotators/ckpts" ]]; then
  LOG "Sync annotators/ckpts"
  mkdir -p "${COMFYUI_ROOT}/annotators/ckpts"
  rsync -a "${STAGE}/annotators/ckpts/" "${COMFYUI_ROOT}/annotators/ckpts/"
  # Kompatibler Pfad für comfyui_controlnet_aux
  AUX_CKPTS="${COMFYUI_ROOT}/custom_nodes/comfyui_controlnet_aux/ckpts"
  if [[ -d "${COMFYUI_ROOT}/custom_nodes/comfyui_controlnet_aux" ]]; then
    mkdir -p "$(dirname "${AUX_CKPTS}")"
    if [[ ! -e "${AUX_CKPTS}" ]]; then
      ln -s "${COMFYUI_ROOT}/annotators/ckpts" "${AUX_CKPTS}" || true
      LOG "Symlink gesetzt: ${AUX_CKPTS} → annotators/ckpts"
    fi
  fi
fi

# Web Extensions → web/extensions
if [[ -d "${STAGE}/web_extensions" ]]; then
  LOG "Sync web_extensions → ComfyUI/web/extensions"
  mkdir -p "${COMFYUI_ROOT}/web/extensions"
  rsync -a "${STAGE}/web_extensions/" "${COMFYUI_ROOT}/web/extensions/"
fi

# ======================= Requirements (optional) ===================
REQS=(
  "custom_nodes/comfyui_controlnet_aux/requirements.txt"
  "custom_nodes/ComfyUI-Advanced-ControlNet/requirements.txt"
)
for req in "${REQS[@]}"; do
  if [[ -f "${COMFYUI_ROOT}/${req}" ]]; then
    LOG "pip install -r ${req}"
    $PIPBIN install -q -r "${COMFYUI_ROOT}/${req}" || true
  fi
done

# ======================= NSFW Bypass (defensiv) ====================
# Patches nur, wenn Muster existieren; niemals fatal.
LOG "NSFW bypass (defensiv)"
$PYBIN - <<'PY'
import re, sys, pathlib
root = pathlib.Path("${COMFYUI_ROOT}")
targets = []
for p in root.rglob("*.py"):
    if "site-packages" in str(p) or "/.venv/" in str(p):
        continue
    txt = p.read_text(encoding="utf-8", errors="ignore")
    orig = txt
    # typische Schalter
    txt = re.sub(r"(block_nsfw\s*:\s*Optional\[bool\]\s*=\s*)None", r"\1False", txt)
    txt = re.sub(r"(safety_checker\s*=\s*)True", r"\1False", txt)
    if txt != orig:
        p.write_text(txt, encoding="utf-8")
        targets.append(str(p))
print("Patched files:", len(targets))
PY

# ======================= Jupyter (opt-in) ==========================
if [[ "${ENABLE_JUPYTER}" == "1" ]]; then
  LOG "Starte Jupyter (Token=disabled) ..."
  nohup ${PYBIN} -m jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --NotebookApp.token='' --NotebookApp.password='' >/workspace/jupyter.log 2>&1 &
fi

# ======================= Start ComfyUI =============================
LOG "Starte ComfyUI auf 0.0.0.0:${PORT}"
cd "${COMFYUI_ROOT}"
exec ${PYBIN} main.py --listen 0.0.0.0 --port "${PORT}" $( [[ "${AUTO_QUEUE}" == "1" ]] && echo "--auto-launch" )

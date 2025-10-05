#!/bin/sh
# entrypoint.sh – RunPod/Docker Entrypoint für ComfyUI + HF Bundle
# - Klont ComfyUI Codebasis falls nicht vorhanden
# - Synct Modelle/Workflows/Web-Extras aus HF Bundle
# - Legt OpenPose/DWPose ckpts-Symlink an
# - NSFW-Bypass-Hook (best effort)
# - Startet ComfyUI (und optional Jupyter)

set -eu

# -------- Defaults / ENV --------
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
: "${HF_SYNC:=1}"                 # 1=ziehen, 0=skip
: "${HF_DELETE_EXTRAS:=0}"        # 1=rsync --delete
: "${ENTRYPOINT_DRY:=0}"          # 1=kein Netz/Download + kein Start
: "${COMFYUI_PORT:=8188}"
: "${ENABLE_JUPYTER:=0}"
: "${JUPYTER_PORT:=8888}"

# HF Token Varianten: HF_TOKEN oder HUGGINGFACE_HUB_TOKEN
[ -n "${HF_TOKEN:-}" ] || HF_TOKEN="${HUGGINGFACE_HUB_TOKEN:-}"

# -------- ComfyUI Basis finden --------
if [ -z "${COMFYUI_BASE}" ]; then
  # Standard RunPod-Layout
  COMFYUI_BASE="${WORKSPACE}/ComfyUI"
fi

# -------- Verzeichnisstruktur --------
mkdir -p \
  "${COMFYUI_BASE}" \
  "${WORKSPACE}/models/checkpoints" \
  "${WORKSPACE}/models/loras" \
  "${WORKSPACE}/models/controlnet" \
  "${WORKSPACE}/annotators/ckpts" \
  "${WORKSPACE}/web_extensions/userstyle" \
  "${WORKSPACE}/workflows"

echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"
echo "[entrypoint] Models Base : ${WORKSPACE}/models"
echo "[entrypoint] HF Repo     : ${HF_REPO_ID}@${HF_BRANCH}"

# -------- NSFW-Bypass (best effort) --------
# Falls ein Node/Lib blockiert, versuchen wir eine env-basierte Abschaltung;
# ComfyUI selbst erzwingt kein NSFW-Filtering, aber manche Zusatz-Nodes tun das.
export DISABLE_NSFWW=True
export NO_SAFETY_CHECKS=1
echo "[entrypoint] NSFW bypass aktiv (env Flags gesetzt)."

# -------- ComfyUI Code klonen (falls fehlt) --------
if [ ! -f "${COMFYUI_BASE}/main.py" ]; then
  echo "[entrypoint] Klone ComfyUI Codebasis…"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_BASE}"
else
  echo "[entrypoint] ComfyUI bereits vorhanden."
fi

# -------- HF Bundle synchronisieren --------
if [ "${HF_SYNC}" = "1" ]; then
  if [ "${ENTRYPOINT_DRY}" = "1" ]; then
    echo "[entrypoint] HF-Sync: skip (ENTRYPOINT_DRY=1)."
  else
    if [ -z "${HF_TOKEN:-}" ]; then
      echo "[entrypoint] ⚠️ HF-Sync übersprungen: Kein HF_TOKEN gesetzt."
    else
      echo "[entrypoint] [HF] snapshot_download: ${HF_REPO_ID}@${HF_BRANCH}"
      python3 - "$HF_REPO_ID" "$HF_BRANCH" "$WORKSPACE" "$HF_TOKEN" <<'PY'
import os, sys, shutil, subprocess, pathlib
from huggingface_hub import snapshot_download

repo_id, branch, ws, token = sys.argv[1:5]
tmp = os.path.join(ws, "_hf_tmp")
os.makedirs(tmp, exist_ok=True)

# Download
snapshot_download(repo_id=repo_id, revision=branch, local_dir=tmp, local_dir_use_symlinks=False, token=token, repo_type="model")

def rsync(src, dst, delete=False):
    os.makedirs(dst, exist_ok=True)
    args = ["rsync","-a","--info=NAME0","--exclude",".git/","--exclude",".gitattributes"]
    if delete:
        args.append("--delete")
    args += [f"{src.rstrip('/')}/", f"{dst.rstrip('/')}/"]
    subprocess.run(args, check=True)

# Bekannte Teilbäume des Bundles
mapping = {
  "checkpoints": ("models/checkpoints", True),
  "loras":       ("models/loras", False),
  "controlnet":  ("models/controlnet", False),
  "annotators":  ("annotators", False),
  "web_extensions": ("web_extensions", False),
  "workflows":   ("workflows", False),
}

for src_name,(rel_dst, want_delete) in mapping.items():
    src = os.path.join(tmp, src_name)
    dst = os.path.join(ws, rel_dst)
    if os.path.isdir(src):
        rsync(src, dst, delete=want_delete)
        print(f"[hf-sync] synced {src_name} -> {rel_dst}")
    else:
        print(f"[hf-sync] skip (not found): {src_name}")
PY
    fi
  fi
else
  echo "[entrypoint] HF-Sync: deaktiviert (HF_SYNC=0)."
fi

# -------- OpenPose/DWPose ckpts Symlink in controlnet_aux --------
AUX_DIR="${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux"
if [ -d "${WORKSPACE}/annotators/ckpts" ]; then
  mkdir -p "${AUX_DIR}"
  ln -sfn "${WORKSPACE}/annotators/ckpts" "${AUX_DIR}/ckpts"
  echo "[entrypoint] Symlink gesetzt: ${AUX_DIR}/ckpts -> ${WORKSPACE}/annotators/ckpts"
fi

# -------- Optional: Jupyter --------
if [ "${ENABLE_JUPYTER}" = "1" ]; then
  if command -v jupyter >/dev/null 2>&1; then
    echo "[entrypoint] Starte Jupyter (Port ${JUPYTER_PORT})…"
    (cd "${WORKSPACE}" && nohup jupyter notebook --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser >/dev/null 2>&1 &) || true
  else
    echo "[entrypoint] Jupyter nicht installiert – übersprungen."
  fi
fi

# -------- Dry-Run Ende --------
if [ "${ENTRYPOINT_DRY}" = "1" ]; then
  echo "[entrypoint] DRY-RUN beendet (kein Serverstart)."
  exit 0
fi

# -------- ComfyUI starten --------
echo "[entrypoint] Starte ComfyUI auf :${COMFYUI_PORT} …"
cd "${COMFYUI_BASE}"
exec python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}"

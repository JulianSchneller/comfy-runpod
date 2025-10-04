#!/bin/sh
set -Eeuo pipefail

# --- Robust Defaults (verhindert 'unbound variable' bei set -u) ---
: "${WORKSPACE:=/workspace}"
: "${COMFYUI_BASE:=${WORKSPACE}/ComfyUI}"
: "${MODELS_DIR:=${WORKSPACE}/models}"
: "${HF_REPO_ID:=Floorius/comfyui-model-bundle}"
: "${HF_BRANCH:=main}"
# akzeptiere HF_TOKEN oder HUGGINGFACE_HUB_TOKEN
if [[ -z "${HF_TOKEN:-}" && -n "${HUGGINGFACE_HUB_TOKEN:-}" ]]; then
  export HF_TOKEN="${HUGGINGFACE_HUB_TOKEN}"
fi

echo "[entrypoint] ComfyUI Base: ${COMFYUI_BASE}"
# Re-exec in bash, falls mit /bin/sh gestartet (z.B. RunPod StartCommand).
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
### HF_SKIP_DL_HEADER_GUARD ###
: "${ENTRYPOINT_DRY:=0}"
if [ -z "${HF_TOKEN:-}" ] || [ "${ENTRYPOINT_DRY}" = "1" ]; then
  export HF_SKIP_DL=1
  echo "[entrypoint] HF-Sync: skip (dry/no token)"
fi
### /HF_SKIP_DL_HEADER_GUARD ###
# === ENTRYPOINT_DRY_HEADER_GUARD ===
: "${ENTRYPOINT_DRY:=0}"
if [ -z "${HF_TOKEN:-}" ] || [ "${ENTRYPOINT_DRY}" = "1" ]; then
  export HF_SKIP_DL=1
fi
# ===================================

# --- ENTRYPOINT_DRY_GUARD ---
: "${ENTRYPOINT_DRY:=0}"
if [[ "${ENTRYPOINT_DRY}" == "1" ]]; then
  export HF_SKIP_DL=1
fi
# Wenn kein HF_TOKEN gesetzt ist → ebenfalls Skip
if [[ -z "${HF_TOKEN:-}" ]]; then
  export HF_SKIP_DL=1
fi

IFS=$'\n\t'

log(){ echo "[entrypoint] $*"; }
warn(){ echo "[entrypoint][WARN] $*" >&2; }

# ----------------- ENV / Defaults -----------------
PORT="${COMFYUI_PORT:-8188}"
HF_SYNC="${HF_SYNC:-1}"              # 1 = aus HF ziehen
HF_DELETE_EXTRAS="${HF_DELETE_EXTRAS:-0}"  # 1 = rsync --delete
ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}"
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"

# ComfyUI Basis finden
BASE="/workspace/ComfyUI"; [[ -d "$BASE" ]] || BASE="/app/ComfyUI"; [[ -d "$BASE" ]] || BASE="/content/ComfyUI"
mkdir -p "$BASE"; cd "$BASE" || exit 1

# Ordner
MODELS="$BASE/models"
CHECKPOINTS="$MODELS/checkpoints"; LORAS="$MODELS/loras"; CONTROLNET="$MODELS/controlnet"
UPSCALE="$MODELS/upscale_models"; FACES="$MODELS/faces"; EMBED="$MODELS/embeddings"; ANNOTATORS="$MODELS/annotators"
CUSTOM_NODES="$BASE/custom_nodes"; WORKFLOWS="$BASE/user/workflows"; WEB_USER="$BASE/web/extensions/user"
AUX_CKPTS="$CUSTOM_NODES/comfyui_controlnet_aux/ckpts"
mkdir -p "$CHECKPOINTS" "$LORAS" "$CONTROLNET" "$UPSCALE" "$FACES" "$EMBED" "$ANNOTATORS" "$CUSTOM_NODES" "$WORKFLOWS" "$WEB_USER" "$AUX_CKPTS"

# ----------------- NSFW-Bypass --------------------

    # --- HF Snapshot (guarded) ---
    if [[ -n "${HF_REPO_ID:-}" ]]; then
      if [[ -n "${HF_TOKEN:-}" ]]; then
        export HUGGINGFACE_HUB_TOKEN="${HF_TOKEN}"
      fi
      python3 - <<'PY'
import os, sys
repo = os.environ.get("HF_REPO_ID","").strip()
branch = os.environ.get("HF_BRANCH","main").strip()
token = os.environ.get("HF_TOKEN","") or os.environ.get("HUGGINGFACE_HUB_TOKEN","")
if not repo:
    print("[entrypoint] HF-Sync: skip (kein Repo gesetzt)")
    sys.exit(0)
print(f"[entrypoint] [HF] snapshot_download: {repo}")
from huggingface_hub import snapshot_download
local = os.environ.get("COMFYUI_BASE","/workspace/ComfyUI")
# Models kommen ins /workspace Pfadbaum (wie im Rest des Skripts genutzt)
target = os.path.join(local, "models")
os.makedirs(target, exist_ok=True)
try:
    snapshot_download(
        repo_id=repo,
        revision=branch,
        local_dir=target,
        repo_type="model",
        allow_patterns=["*"],
    )
    print("[entrypoint] [HF] Snapshot ok.")
except Exception as e:
    # Bei privaten Repos ohne Token: sauber abbrechen, Rest vom entrypoint darf weiterlaufen
    print(f"[entrypoint] [HF] Snapshot skip/fehlgeschlagen: {e}")
PY
    fi

# ----------------- Requirements -------------------
command -v rsync >/dev/null 2>&1 || { apt-get update -y && apt-get install -y rsync >/dev/null; }
python3 -c "import huggingface_hub" 2>/dev/null || python3 -m pip install -U --no-cache-dir huggingface_hub >/dev/null

if [[ "$INSTALL_NODE_REQS" == "1" ]]; then
  for R in "$CUSTOM_NODES"/*/requirements.txt; do
    [[ -f "$R" ]] || continue
    log "pip install -r $R"
    python3 -m pip install --no-input -r "$R" || true
  done
fi

# ----------------- HF Sync ------------------------
sync_hf(){
  [[ "$HF_SYNC" == "1" ]] || { log "[HF] Sync aus"; return 0; }
  [[ -n "${HF_REPO_ID:-}" ]] || { warn "[HF] HF_REPO_ID fehlt – breche ab"; return 0; }

  STAGE="/tmp/hf_stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  log "[HF] snapshot_download: $HF_REPO_ID"
  python3 - <<PY
import os
from huggingface_hub import snapshot_download
repo=os.environ["HF_REPO_ID"]
token=os.environ.get("HF_TOKEN") or None
allow=[
 "checkpoints/**","loras/**","controlnet/**",
 "custom_nodes/**","web_extensions/**",
 "workflows/**","Arbeitsabläufe/**",
 "annotators/ckpts/**",
 "upscale_models/**","faces/**","embeddings/**",
]
snapshot_download(repo_id=repo, token=token, local_dir="/tmp/hf_stage",
                  allow_patterns=allow,
                  ignore_patterns=[".git/**",".gitattributes","README.md"])
print("[entrypoint] [HF] Snapshot ok.")
PY

  RSDEL=""
  [[ "$HF_DELETE_EXTRAS" == "1" ]] && RSDEL="--delete"

  rsync -a $RSDEL "$STAGE/checkpoints/"    "$CHECKPOINTS/"    2>/dev/null || true
  rsync -a $RSDEL "$STAGE/loras/"          "$LORAS/"          2>/dev/null || true
  rsync -a $RSDEL "$STAGE/controlnet/"     "$CONTROLNET/"     2>/dev/null || true
  rsync -a $RSDEL "$STAGE/upscale_models/" "$UPSCALE/"        2>/dev/null || true
  rsync -a $RSDEL "$STAGE/embeddings/"     "$EMBED/"          2>/dev/null || true
  rsync -a $RSDEL "$STAGE/faces/"          "$FACES/"          2>/dev/null || true
  rsync -a $RSDEL "$STAGE/custom_nodes/"   "$CUSTOM_NODES/"   2>/dev/null || true
  rsync -a $RSDEL "$STAGE/workflows/"      "$WORKFLOWS/"      2>/dev/null || true
  rsync -a $RSDEL "$STAGE/Arbeitsabläufe/" "$WORKFLOWS/"      2>/dev/null || true
  [[ -d "$STAGE/web_extensions" ]] && rsync -a $RSDEL "$STAGE/web_extensions/" "$WEB_USER/"

  # annotators/ckpts → Symlink auf AUX_CKPTS
  rsync -a "$STAGE/annotators/ckpts/" "$AUX_CKPTS/" 2>/dev/null || true
  if [[ -e "$ANNOTATORS/ckpts" && ! -L "$ANNOTATORS/ckpts" ]]; then
    warn "[HF] $ANNOTATORS/ckpts existiert (kein Symlink) – lasse unverändert."
  else
    rm -f "$ANNOTATORS/ckpts"
    ln -s "$AUX_CKPTS" "$ANNOTATORS/ckpts"
    log "[HF] Symlink: $ANNOTATORS/ckpts -> $AUX_CKPTS"
  fi

  # Cleanup Caches
  find "$BASE" -type f -name '*.part' -delete 2>/dev/null || true
  rm -rf ~/.cache/huggingface/hub ~/.cache/torch 2>/dev/null || true
  python3 -m pip cache purge >/dev/null 2>&1 || true
  rm -rf "$STAGE"
  log "[HF] Sync abgeschlossen."
}

# ----------------- Optional: Jupyter --------------
if [[ "$ENABLE_JUPYTER" == "1" ]]; then
  command -v jupyter >/dev/null 2>&1 || python3 -m pip install -U notebook >/dev/null
  jupyter notebook --ip=0.0.0.0 --port="${JUPYTER_PORT:-8888}" \
    --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password='' \
    >/tmp/jupyter.log 2>&1 &
  log "Jupyter läuft auf Port ${JUPYTER_PORT:-8888}"
fi

# ----------------- Start --------------------------
log "ComfyUI Base: $BASE"
sync_hf
log "Starte ComfyUI (Port ${PORT}) …"

# --- Optional: System-Preqs für rlpycairo/svglib (falls nötig) ---
need_cairo=0
python3 - <<'PY' >/dev/null 2>&1 || need_cairo=1
try:
    import cairo, rlpycairo  # type: ignore
    import svglib  # type: ignore
except Exception:
    raise SystemExit(1)
PY
if [ "$need_cairo" -ne 0 ] ; then
  echo "[entrypoint] Installiere Cairo-Dev-Prereqs (apt) für svglib/rlpycairo …"
  if command -v apt-get >/dev/null 2>&1 ; then
    apt-get update -y && apt-get install -y --no-install-recommends libcairo2-dev pkg-config && rm -rf /var/lib/apt/lists/*
  else
    echo "[entrypoint] ⚠ apt-get nicht verfügbar – svglib/rlpycairo könnten fehlschlagen."
  fi
fi

# --- Python-Dependencies für comfyui_controlnet_aux ---
if [ -f "${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux/requirements.txt" ]; then
  echo "[entrypoint] pip install -r ${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux/requirements.txt"
  pip install --no-cache-dir -r "${COMFYUI_BASE}/custom_nodes/comfyui_controlnet_aux/requirements.txt" || true
fi

# --- ComfyUI starten ---
PORT="${PORT:-8188}"
echo "[entrypoint] Starte ComfyUI (Port ${PORT}) …"
exec python3 "${COMFYUI_BASE}/main.py" --listen 0.0.0.0 --port "${PORT}"


    # --- NSFW UI bypass (nur CSS, optional) ---
    if [[ -d "${COMFYUI_BASE}/web/extensions" ]]; then
      mkdir -p "${COMFYUI_BASE}/web/extensions/userstyle"
      CSS="${COMFYUI_BASE}/web/extensions/userstyle/userstyle.css"
      if [[ ! -f "${CSS}" ]] || ! grep -q "nsfw-bypass" "${CSS}" 2>/dev/null; then
        cat > "${CSS}" <<'CSS'
/* nsfw-bypass */
.safety-warning, .nsfw, .content-warning { display: none !important; }
CSS
        echo "[entrypoint] NSFW bypass aktiv."
      fi
    fi


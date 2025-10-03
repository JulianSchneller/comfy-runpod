#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# -------------------------------------------------
# Defaults (per Runpod-Env überschreibbar)
# -------------------------------------------------
: "${COMFYUI_PORT:=8188}"
: "${JUPYTER_PORT:=8888}"
: "${RUN_JUPYTER:=1}"                 # <— Jupyter standardmäßig AN
: "${HF_REPO_ID:=}"                   # z.B. Floorius/comfyui-model-bundle
: "${HF_TOKEN:=}"                     # falls privates HF-Repo
: "${JUPYTER_PASSWORD:=}"            # optional; Token-Auth wenn leer
: "${PYTHONUNBUFFERED:=1}"

export PYTHONUNBUFFERED

ROOT="/workspace"
CUI="$ROOT/ComfyUI"
HF_DST="$ROOT/hf_sync"               # hierhin wird das HF-Bundle gespiegelt

# -------------------------------------------------
# ComfyUI bereitstellen (klonen, wenn fehlt)
# -------------------------------------------------
if [[ ! -d "$CUI" ]]; then
  log "ComfyUI nicht gefunden – klone…"
  git -C "$ROOT" clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git
fi

# -------------------------------------------------
# HF-Bundle synchronisieren (falls konfiguriert)
# -------------------------------------------------
if [[ -n "${HF_REPO_ID}" ]]; then
  log "HF-Sync aus: ${HF_REPO_ID}"
  mkdir -p "$HF_DST"
  # privates Repo via Token klonen/aktualisieren
  if [[ -d "$HF_DST/.git" ]]; then
    git -C "$HF_DST" fetch --all || true
    git -C "$HF_DST" reset --hard origin/main || true
  else
    if [[ -n "${HF_TOKEN}" ]]; then
      git clone "https://user:${HF_TOKEN}@huggingface.co/${HF_REPO_ID}" "$HF_DST" || true
    else
      git clone "https://huggingface.co/${HF_REPO_ID}" "$HF_DST" || true
    fi
  fi
  # falls git-Ordner im HF_DST nicht existiert (z.B. Snapshot), ist auch ok.
else
  log "HF_REPO_ID leer – überspringe HF-Sync."
fi

# -------------------------------------------------
# Zielordner in ComfyUI anlegen
# -------------------------------------------------
mkdir -p \
  "$CUI/models/checkpoints" \
  "$CUI/models/loras" \
  "$CUI/models/vae" \
  "$CUI/models/controlnet" \
  "$CUI/models/upscale_models" \
  "$CUI/custom_nodes" \
  "$CUI/user/default/workflows"

# -------------------------------------------------
# HF-Bundle → ComfyUI mappen (nur wenn HF_DST existiert)
# -------------------------------------------------
if [[ -d "$HF_DST" ]]; then
  log "Mappe HF-Bundle in ComfyUI…"
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/checkpoints/"     "$CUI/models/checkpoints/"     || true
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/loras/"           "$CUI/models/loras/"           || true
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/vae/"             "$CUI/models/vae/"             || true
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/controlnet/"      "$CUI/models/controlnet/"      || true
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/upscale_models/"  "$CUI/models/upscale_models/"  || true
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/custom_nodes/"    "$CUI/custom_nodes/"           || true
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/workflows/"       "$CUI/user/default/workflows/" || true
  # optionale Ordner (falls vorhanden)
  rsync -a --delete --mkpath --exclude=".git" "$HF_DST/faces/"           "$CUI/models/faces/"           || true
fi

# -------------------------------------------------
# Python-Abhängigkeiten (ComfyUI + Custom-Nodes)
# -------------------------------------------------
log "Installiere Python-Abhängigkeiten…"
python3 -m pip install --upgrade pip wheel
# Core
if [[ -f "$CUI/requirements.txt" ]]; then
  python3 -m pip install -r "$CUI/requirements.txt"
fi
# Custom-Nodes requirements
if compgen -G "$CUI/custom_nodes/*/requirements*.txt" > /dev/null; then
  for req in "$CUI"/custom_nodes/*/requirements*.txt; do
    log "  → pip install -r ${req}"
    python3 -m pip install -r "$req" || true
  done
fi

# -------------------------------------------------
# JupyterLab (optional)
# -------------------------------------------------
start_jupyter() {
  # Jupyter installiert? (sollte aus dem Image kommen)
  if ! command -v jupyter-lab >/dev/null 2>&1; then
    log "JupyterLab fehlt – installiere…"
    python3 -m pip install --no-cache-dir "jupyterlab>=4,<5" "jupyter_server>=2,<3"
  fi
  log "Starte JupyterLab auf :${JUPYTER_PORT}"
  if [[ -n "${JUPYTER_PASSWORD}" ]]; then
    # Token setzen (bequemer in Runpod)
    jupyter-lab --no-browser --port="${JUPYTER_PORT}" --ip=0.0.0.0 \
      --ServerApp.token="${JUPYTER_PASSWORD}" \
      --ServerApp.allow_origin="*" \
      --ServerApp.base_url="/" >/workspace/logs/jupyter.log 2>&1 &
  else
    # ohne Passwort/Token – nur wenn Port durch Runpod geschützt ist
    jupyter-lab --no-browser --port="${JUPYTER_PORT}" --ip=0.0.0.0 \
      --ServerApp.token="" --ServerApp.password="" \
      --ServerApp.allow_origin="*" \
      --ServerApp.base_url="/" >/workspace/logs/jupyter.log 2>&1 &
  fi
}

# -------------------------------------------------
# ComfyUI starten
# -------------------------------------------------
log "Starte ComfyUI auf :${COMFYUI_PORT}"
cd "$CUI"
python3 main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" >/workspace/logs/comfyui.log 2>&1 &

# optional Jupyter
if [[ "${RUN_JUPYTER}" == "1" ]]; then
  start_jupyter
else
  log "RUN_JUPYTER=0 – JupyterLab deaktiviert."
fi

# Health-Ausgaben
sleep 2
log "== Laufende Prozesse =="
ps -eo pid,cmd | grep -E "main.py|jupyter-lab" | grep -v grep || true
log "== Ports =="
ss -ltnp | grep -E ":${COMFYUI_PORT}|:${JUPYTER_PORT}" || true

# Prozess offen halten
log "Bereit. ComfyUI: ${COMFYUI_PORT} / Jupyter: ${JUPYTER_PORT}"
tail -F /workspace/logs/comfyui.log /workspace/logs/jupyter.log 2>/dev/null || tail -f /dev/null

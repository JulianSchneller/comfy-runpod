#!/bin/bash
set -eo pipefail
    #!/usr/bin/env bash
    set -Eeuo pipefail

    log(){ printf "%s %s\n" "$(date +'%F %T')" "$*"; }

    # -------- Settings via ENV --------
    : "${HF_REPO_ID:=}"            # z.B. Floorius/comfyui-model-bundle
    : "${HF_BRANCH:=main}"
    : "${HF_TOKEN:=}"              # optional; für private Repos
    : "${HF_SYNC:=1}"              # 1=an, 0=aus
    : "${ENABLE_JUPYTER:=0}"       # 1=startet JupyterLab auf :8888
    : "${INSTALL_NODE_REQS:=0}"    # 1=installiert requirements.txt in custom_nodes/*
    : "${COMFY_PORT:=8188}"
    : "${COMFY_IP:=0.0.0.0}"

    COMFY_DIR="/workspace/ComfyUI"
    HF_STAGE="/workspace/_hf_stage"

    log "🚀 entrypoint.sh gestartet"

    # --------- ComfyUI bereitstellen ----------
    if [[ ! -d "$COMFY_DIR" ]]; then
      log "📦 Clone ComfyUI …"
      git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
    fi

    # ---------- Helper: sync ohne harte Abhängigkeit von rsync ----------
    safe_sync() {
      # $1: src, $2: dst
      local src="$1"; local dst="$2"
      [[ -d "$src" ]] || return 0
      mkdir -p "$dst"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src"/ "$dst"/
      else
        rm -rf "$dst"
        mkdir -p "$dst"
        cp -a "$src"/. "$dst"/
      fi
    }

    # ---------- HF Sync (optional) ----------
    if [[ "${HF_SYNC}" == "1" && -n "${HF_REPO_ID}" ]]; then
      log "🔗 HF Sync aus ${HF_REPO_ID}@${HF_BRANCH}"
      rm -rf "${HF_STAGE}"; mkdir -p "${HF_STAGE}"

      use_snapshot=0
      if command -v git >/dev/null 2>&1; then
        if [[ -n "${HF_TOKEN}" ]]; then
          HF_URL="https://user:${HF_TOKEN}@huggingface.co/${HF_REPO_ID}"
        else
          HF_URL="https://huggingface.co/${HF_REPO_ID}"
        fi
        if git clone --depth 1 -b "${HF_BRANCH}" "${HF_URL}" "${HF_STAGE}" 2>/dev/null; then
          log "✅ HF git clone OK"
        else
          log "ℹ️ git clone nicht möglich, fallback snapshot_download …"
          use_snapshot=1
        fi
      else
        use_snapshot=1
      fi

      if [[ "${use_snapshot}" == "1" ]]; then
        python3 - <<'PY'
import sys, subprocess, os
from pathlib import Path

def ensure_hub():
    try:
        import huggingface_hub  # noqa
    except Exception:
        subprocess.run([sys.executable,"-m","pip","install","-q","huggingface_hub==0.35.3"], check=True)

ensure_hub()
from huggingface_hub import snapshot_download

repo_id  = os.environ.get("HF_REPO_ID","")
branch   = os.environ.get("HF_BRANCH","main")
token    = os.environ.get("HF_TOKEN") or None
dest     = os.environ.get("HF_STAGE","/workspace/_hf_stage")
Path(dest).mkdir(parents=True, exist_ok=True)
snapshot_download(repo_id=repo_id, revision=branch, local_dir=dest, token=token, repo_type="model")
print("✅ snapshot_download OK:", dest)
PY
      fi

      # Inhalte gezielt in ComfyUI spiegeln
      safe_sync "${HF_STAGE}/custom_nodes"        "${COMFY_DIR}/custom_nodes"
      safe_sync "${HF_STAGE}/models"              "${COMFY_DIR}/models"
      safe_sync "${HF_STAGE}/checkpoints"         "${COMFY_DIR}/models/checkpoints"
      safe_sync "${HF_STAGE}/loras"               "${COMFY_DIR}/models/loras"
      safe_sync "${HF_STAGE}/controlnet"          "${COMFY_DIR}/models/controlnet"
      safe_sync "${HF_STAGE}/upscale_models"      "${COMFY_DIR}/models/upscale_models"
      safe_sync "${HF_STAGE}/faces"               "${COMFY_DIR}/models/faces"
      safe_sync "${HF_STAGE}/workflows"           "${COMFY_DIR}/user/workflows"
      safe_sync "${HF_STAGE}/web_extensions"      "${COMFY_DIR}/web/extensions"
      safe_sync "${HF_STAGE}/annotators/ckpts"    "${COMFY_DIR}/annotators/ckpts"
      # fallback common layout
      safe_sync "${HF_STAGE}/models/checkpoints"  "${COMFY_DIR}/models/checkpoints"

      log "✅ HF Sync abgeschlossen"

      # Optional: requirements aus custom_nodes installieren
      if [[ "${INSTALL_NODE_REQS}" == "1" ]]; then
        log "📦 Installiere requirements aus custom_nodes …"
        shopt -s nullglob
        for req in "${COMFY_DIR}"/custom_nodes/*/requirements*.txt; do
          log "pip install -r ${req}"
          pip install -r "${req}" -q || true
        done
        shopt -u nullglob
      fi
    else
      log "⏩ HF Sync übersprungen (HF_SYNC!=1 oder HF_REPO_ID leer)"
    fi

    # ---------- NSFW-Bypass (best effort) ----------
    log "⚠️ NSFW-Bypass anwenden (best effort)"
    patched=0
    while IFS= read -r -d '' f; do
      sed -i 's/block_nsfw[[:space:]]*=[[:space:]]*True/block_nsfw=False/g' "$f" || true
      sed -i 's/block_nsfw[[:space:]]*:[^=]*=[[:space:]]*True/block_nsfw: Optional[bool] = False/g' "$f" || true
      sed -i 's/block_nsfw[[:space:]]*=[[:space:]]*None/block_nsfw=False/g' "$f" || true
      sed -i 's/block_nsfw[[:space:]]*=[[:space:]]*\"True\"/block_nsfw=False/g' "$f" || true
      if grep -q "block_nsfw" "$f"; then patched=$((patched+1)); fi
    done < <(find "${COMFY_DIR}" -type f -name "*.py" -print0)
    log "… Dateien mit Patches: ${patched}"

    # ---------- Optional: Jupyter ----------
    if [[ "${ENABLE_JUPYTER}" == "1" ]]; then
      if ! command -v jupyter >/dev/null 2>&1; then
        log "🧪 Installiere JupyterLab …"
        pip install -q jupyterlab || true
      fi
      log "🧪 Starte JupyterLab auf :8888 (token-los; nur im Pod nutzen)"
      nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --ServerApp.token= --ServerApp.password= \
        >/workspace/jupyter.log 2>&1 &
    fi

    # ---------- ComfyUI starten ----------
    log "▶️ Starte ComfyUI auf ${COMFY_IP}:${COMFY_PORT}"
    cd "${COMFY_DIR}"
    exec python3 main.py --listen --port "${COMFY_PORT}"

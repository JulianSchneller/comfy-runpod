#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- Konfiguration über ENV ----------
COMFYUI_ROOT="${COMFYUI_ROOT:-/workspace/ComfyUI}"
HF_REPO_ID="${HF_REPO_ID:-}"                  # z.B. Floorius/comfyui-model-bundle
HF_SYNC="${HF_SYNC:-1}"                       # 1=Bundle syncen
INSTALL_NODE_REQ="${INSTALL_NODE_REQ:-1}"     # 1=custom_nodes requirements installieren
ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}"         # 1=Jupyter startbar
NSFW_BYPASS="${NSFW_BYPASS:-1}"               # 1=NSFW-SafetyChecker deaktivieren (wo vorhanden)
HF_TOKEN="${HF_TOKEN:-}"                      # optional: für private HF-Repos (non-interactive)

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONUNBUFFERED=1
export HF_HUB_DISABLE_TELEMETRY=1

echo "==> COMFYUI_ROOT:      $COMFYUI_ROOT"
echo "==> HF_REPO_ID:        ${HF_REPO_ID:-<none>}"
echo "==> HF_SYNC:           $HF_SYNC"
echo "==> INSTALL_NODE_REQ:  $INSTALL_NODE_REQ"
echo "==> ENABLE_JUPYTER:    $ENABLE_JUPYTER"
echo "==> NSFW_BYPASS:       $NSFW_BYPASS"

# ---------- System-Dependencies für controlnet_aux / pycairo ----------
echo "==> Installiere System-Dependencies (cairo/pango etc.) …"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git curl ca-certificates jq rsync \
  pkg-config libcairo2-dev libpango1.0-dev libglib2.0-dev libfreetype6-dev libffi-dev \
  > /dev/null
apt-get clean
rm -rf /var/lib/apt/lists/*

# ---------- ComfyUI-Quelle sicherstellen ----------
if [[ ! -d "$COMFYUI_ROOT/.git" ]]; then
  echo "==> ComfyUI nicht gefunden – clone …"
  mkdir -p "$(dirname "$COMFYUI_ROOT")"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_ROOT"
else
  echo "==> ComfyUI vorhanden – Pull …"
  git -C "$COMFYUI_ROOT" fetch --depth 1 origin
  git -C "$COMFYUI_ROOT" reset --hard origin/master || git -C "$COMFYUI_ROOT" reset --hard origin/main || true
fi

# ---------- Python-Dependencies (ComfyUI) ----------
echo "==> Python-Abhängigkeiten (ComfyUI) …"
python3 -m pip install --upgrade pip wheel setuptools >/dev/null
if [[ -f "$COMFYUI_ROOT/requirements.txt" ]]; then
  python3 -m pip install -r "$COMFYUI_ROOT/requirements.txt"
fi

# ---------- NSFW-BYPASS (optional robust) ----------
if [[ "$NSFW_BYPASS" == "1" ]]; then
  echo "==> Aktiviere NSFW-Bypass (Diffusers SafetyChecker monkeypatch) …"
  PATCH_FILE="$COMFYUI_ROOT/nsfw_bypass.py"
  cat > "$PATCH_FILE" << 'PY'
import types, sys
def _patch():
    try:
        from diffusers.pipelines.stable_diffusion import safety_checker as sc
        class _Dummy:
            def __call__(self, images, **kwargs):
                # Return images unverändert + alle 'not nsfw'
                return images, [False] * len(images)
        sc.StableDiffusionSafetyChecker = _Dummy
    except Exception:
        pass
_patch()
PY
  # ComfyUI lädt alles per Python; wir sorgen dafür, dass unser Patch beim Start importiert wird
  export PYTHONPATH="$COMFYUI_ROOT:$PYTHONPATH"
else
  echo "==> NSFW-Bypass: deaktiviert"
fi

# ---------- HF-Bundle synchronisieren ----------
bundle_dir="/opt/hf-bundle"
if [[ "$HF_SYNC" == "1" && -n "${HF_REPO_ID}" ]]; then
  echo "==> Synchronisiere HuggingFace-Bundle: $HF_REPO_ID → $bundle_dir"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"

  if [[ -n "$HF_TOKEN" ]]; then
    echo "$HF_TOKEN" | huggingface-cli login --token --stdin >/dev/null 2>&1 || true
  fi

  # git clone (xet/LFS handled server-side); Fallback auf snapshot-download wäre möglich
  git clone --depth 1 "https://huggingface.co/${HF_REPO_ID}" "$bundle_dir"

  # Mapping: Quelle → Ziel (nur existierende Quellen kopieren)
  declare -A MAP
  MAP["checkpoints"]="$COMFYUI_ROOT/models/checkpoints"
  MAP["loras"]="$COMFYUI_ROOT/models/loras"
  MAP["controlnet"]="$COMFYUI_ROOT/models/controlnet"
  MAP["upscale_models"]="$COMFYUI_ROOT/models/upscale_models"
  MAP["workflows"]="$COMFYUI_ROOT/workflows"
  MAP["web-extensions"]="$COMFYUI_ROOT/web/extensions/user"
  MAP["web_extensions"]="$COMFYUI_ROOT/web/extensions/user"    # falls anderer Ordnername
  MAP["custom_nodes"]="$COMFYUI_ROOT/custom_nodes"
  MAP["annotators/ckpts"]="$COMFYUI_ROOT/custom_nodes/comfyui_controlnet_aux/ckpts"

  for src in "${!MAP[@]}"; do
    if [[ -d "$bundle_dir/$src" ]]; then
      dst="${MAP[$src]}"
      mkdir -p "$dst"
      echo "   • rsync $src → $dst"
      rsync -a --ignore-existing "$bundle_dir/$src/" "$dst/"
    fi
  done

  # Spezieller Fall: annotators/ckpts → falls vorhanden zusätzlich Link anlegen,
  # weil einige Aux-Nodes genau diesen Pfad erwarten.
  if [[ -d "$bundle_dir/annotators/ckpts" ]]; then
    aux_ck="$COMFYUI_ROOT/custom_nodes/comfyui_controlnet_aux/ckpts"
    mkdir -p "$(dirname "$aux_ck")"
    if [[ ! -e "$aux_ck" ]]; then
      ln -s "$bundle_dir/annotators/ckpts" "$aux_ck" || true
      echo "   • Symlink gesetzt: $aux_ck -> bundle/annotators/ckpts"
    fi
  fi
else
  echo "==> HF_SYNC=0 oder kein HF_REPO_ID – überspringe Bundle-Sync."
fi

# ---------- Custom-Node Requirements ----------
if [[ "$INSTALL_NODE_REQ" == "1" && -d "$COMFYUI_ROOT/custom_nodes" ]]; then
  echo "==> Installiere requirements.txt von custom_nodes (falls vorhanden) …"
  # controlnet_aux zuerst (wegen Cairo)
  if [[ -d "$COMFYUI_ROOT/custom_nodes/comfyui_controlnet_aux" && -f "$COMFYUI_ROOT/custom_nodes/comfyui_controlnet_aux/requirements.txt" ]]; then
    python3 -m pip install -r "$COMFYUI_ROOT/custom_nodes/comfyui_controlnet_aux/requirements.txt"
  fi
  # Restliche Nodes
  find "$COMFYUI_ROOT/custom_nodes" -maxdepth 2 -name "requirements.txt" \
    ! -path "*/comfyui_controlnet_aux/*" -print0 | while IFS= read -r -d '' req; do
      echo "   • pip install -r $req"
      python3 -m pip install -r "$req" || true
    done
else
  echo "==> INSTALL_NODE_REQ=0 oder kein custom_nodes – überspringe."
fi

# ---------- Jupyter optional vorbereiten ----------
if [[ "$ENABLE_JUPYTER" == "1" ]]; then
  echo "==> Installiere JupyterLab …"
  python3 -m pip install jupyterlab jupyter_http_over_ws >/dev/null
  jupyter serverextension enable --py jupyter_http_over_ws >/dev/null 2>&1 || true
else
  echo "==> ENABLE_JUPYTER=0 – Jupyter wird nicht installiert."
fi

# ---------- Start ComfyUI ----------
cd "$COMFYUI_ROOT"
echo "==> Starte ComfyUI …"
# Standard-HTTP-Port (z.B. 8188) wird vom Image/Template vorgegeben
exec python3 main.py --listen 0.0.0.0 --port "${PORT:-8188}"

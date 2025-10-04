# build-bump: 2025-10-04T15:44:49.966449Z
#!/usr/bin/env bash

# >>> COMFY_OPENPOSE_DWPOSE_SETUP:START
# Installiere Custom-Nodes + lade OpenPose/DWPose-CKPTs
set -e
COMFY_ROOT="/workspace/ComfyUI"
CNODES="$COMFY_ROOT/custom_nodes"
CKPTS="$COMFY_ROOT/annotators/ckpts"
mkdir -p "$CNODES" "$CKPTS"

clone_if_missing() {
  local url="$1"; local dir="$2"
  if [ ! -d "$dir" ]; then
    echo "⬇️  $url → $dir"
    git clone --depth=1 "$url" "$dir" || true
  else
    echo "↻  pull $dir"; (cd "$dir" && git pull --ff-only || true)
  fi
}

clone_if_missing "https://github.com/Kosinkadink/ComfyUI-Advanced-ControlNet.git" "$CNODES/ComfyUI-Advanced-ControlNet"
clone_if_missing "https://github.com/Fannovel16/comfyui_controlnet_aux.git"       "$CNODES/comfyui_controlnet_aux"

if command -v pip >/dev/null 2>&1; then
  pip install --no-cache-dir -r "$CNODES/comfyui_controlnet_aux/requirements.txt" || true
  pip install --no-cache-dir -r "$CNODES/ComfyUI-Advanced-ControlNet/requirements.txt" || true
fi

dl_if_missing() {
  local url="$1"; local out="$2"
  [ -f "$out" ] && { echo "✔️  vorhanden: $out"; return; }
  echo "⬇️  $out"; curl -L --retry 5 --connect-timeout 15 "$url" -o "$out"
}

dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/body_pose_model.pth" "$CKPTS/body_pose_model.pth"
dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/hand_pose_model.pth" "$CKPTS/hand_pose_model.pth"
# facenet.pth optional

dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth" "$CKPTS/dw-ll_ucoco_384.pth"
dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"        "$CKPTS/yolox_l.onnx"
# optionaler Fallback:
curl -L --fail --retry 3 "https://huggingface.co/monster-labs/controlnet_aux_models/resolve/main/yolox_l.torchscript" -o "$CKPTS/yolox_l.torchscript" || true
set +e
# >>> COMFY_OPENPOSE_DWPOSE_SETUP:END

set -Eeuo pipefail

log(){ printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# ---- ENV / Defaults ----
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="$WORKSPACE/ComfyUI"
MODELS_DIR="$COMFY_DIR/models"
LOG_DIR="$WORKSPACE/logs"

HF_REPO_ID="${HF_REPO_ID:-}"     # z.B. Floorius/comfyui-model-bundle
HF_TOKEN="${HF_TOKEN:-}"

COMFYUI_PORT="${COMFYUI_PORT:-8188}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
RUN_JUPYTER="${RUN_JUPYTER:-1}"        # 1 = Jupyter an
JUPYTER_TOKEN="${JUPYTER_TOKEN:-${JUPYTER_PASSWORD:-}}"  # optional

mkdir -p "$LOG_DIR"

# ---- ComfyUI klonen (idempotent) ----
if [[ ! -d "$COMFY_DIR/.git" ]]; then
  log "Cloning ComfyUI …"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  log "ComfyUI vorhanden – kein Clone."
fi

# ---- requirements.txt säubern (keine Beispiel-Workflows) ----
if grep -q "comfyui-workflow-templates" "$COMFY_DIR/requirements.txt"; then
  log "Patch requirements.txt → entferne comfyui-workflow-templates"
  sed -i '/comfyui-workflow-templates/d' "$COMFY_DIR/requirements.txt"
fi

# ---- Python-Requirements (best effort) ----
log "Install ComfyUI requirements …"
python -m pip install --no-cache-dir --upgrade pip wheel setuptools >>"$LOG_DIR/pip.log" 2>&1 || true
python -m pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
# Falls torchsde fehlt (manche KSampler brauchen es)
python - <<'PY' || true
import importlib, sys
try:
    importlib.import_module("torchsde")
except Exception:
    import subprocess
    subprocess.run([sys.executable,"-m","pip","install","--no-cache-dir","torchsde"], check=False)
PY

# ---- Zielordner in ComfyUI (idempotent) ----
mkdir -p "$MODELS_DIR"/{checkpoints,loras,controlnet,upscale_models,faces,vae,clip_vision,style_models,embeddings,diffusers,vae_approx}
mkdir -p "$COMFY_DIR/user/default/workflows"
mkdir -p "$COMFY_DIR/custom_nodes"

# ==== HF Direct Download – ALLES (große Dateien, Progress) ====
# Lädt ALLE Dateien aus den Unterordnern und kopiert sie in die korrekten ComfyUI-Verzeichnisse.
# Benötigt ausreichend Speicher (typisch 30–35 GB).

download_all_from_hf() {
  if [ -z "${HF_REPO_ID:-}" ] || [ -z "${HF_TOKEN:-}" ]; then
    log "HF Direct Download übersprungen (HF_REPO_ID/HF_TOKEN fehlen)."
    return
  fi

  python - <<'PY'
import os, sys, shutil, math, time
from huggingface_hub import HfApi, hf_hub_download, login

def human(n):
    units=["B","KB","MB","GB","TB"]; i=0
    while n>=1024 and i<len(units)-1:
        n/=1024; i+=1
    return f"{n:.2f} {units[i]}"

repo   = os.environ.get("HF_REPO_ID","")
token  = os.environ.get("HF_TOKEN","")
work   = os.environ.get("WORKSPACE","/workspace")
comfy  = os.path.join(work,"ComfyUI")
models = os.path.join(comfy,"models")

login(token=token, add_to_git_credential=False)
api = HfApi()

# Map: HF-Subfolder -> Zielverzeichnis
MAP = {
  "checkpoints":    os.path.join(models,"checkpoints"),
  "loras":          os.path.join(models,"loras"),
  "controlnet":     os.path.join(models,"controlnet"),
  "upscale_models": os.path.join(models,"upscale_models"),
  "faces":          os.path.join(models,"faces"),
  "vae":            os.path.join(models,"vae"),
  # Workflows separat behandelt (nur .json)
}

# Liste aller Dateien im Model-Repo
files = api.list_repo_files(repo_id=repo, repo_type="model")

# Vorab: Größe grob aufsummieren, um ein Gefühl zu geben (nur bekannte Subpfade)
est_total = 0
cand = []
for f in files:
    sub = f.split("/")[0] if "/" in f else ""
    if sub in MAP and not f.endswith("/"):
        cand.append(f)
# naive Abschätzung: Dateigrößen via try-download HEAD ist nicht verfügbar => zeigen nur Anzahl
print(f"[INFO] Lade {len(cand)} Dateien aus {sorted(set([c.split('/')[0] for c in cand]))} … (Größen siehe während des Downloads)")

# Download & Kopie
cache = "/tmp/hf_cache_full"
os.makedirs(cache, exist_ok=True)
loaded = 0
total_bytes = 0

def copy_to(dst_dir, file_path):
    os.makedirs(dst_dir, exist_ok=True)
    base = os.path.basename(file_path)
    dst  = os.path.join(dst_dir, base)
    # Falls bereits vorhanden mit gleicher Größe: überspringen
    if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(file_path):
        print(f"[SKIP] {base} (bereits vorhanden)")
        return 0
    shutil.copy2(file_path, dst)
    return os.path.getsize(dst)

# Modelle: alle Dateien laden
for f in cand:
    sub = f.split("/")[0]
    dst_dir = MAP[sub]
    try:
        p = hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                            local_dir=cache, local_dir_use_symlinks=False)
        sz = copy_to(dst_dir, p)
        total_bytes += sz
        loaded += 1
        print(f"[OK]  {f}  (+{human(sz)})  ⇒ {dst_dir}")
    except Exception as e:
        print(f"[ERR] {f} -> {e}")

# Workflows (nur .json) nach user/default/workflows
w_dst = os.path.join(comfy,"user","default","workflows")
os.makedirs(w_dst, exist_ok=True)
w_cnt = 0
for f in files:
    if f.startswith("workflows/") and f.lower().endswith(".json"):
        try:
            p = hf_hub_download(repo_id=repo, filename=f, repo_type="model",
                                local_dir=cache, local_dir_use_symlinks=False)
            sz = copy_to(w_dst, p)
            total_bytes += sz
            w_cnt += 1
            print(f"[WF] {f}  (+{human(sz)})  ⇒ {w_dst}")
        except Exception as e:
            print(f"[ERR] {f} -> {e}")

print(f"[SUMMARY] Dateien geladen: {loaded} Models, {w_cnt} Workflows, Gesamt: {human(total_bytes)}")
PY
}

# Aufruf (ersetzt bisherigen HF-Sync)
download_all_from_hf


# ---- Services starten ----
# Jupyter zuerst (optional, Hintergrund)
if [[ "${RUN_JUPYTER}" == "1" ]]; then
  log "Starte JupyterLab auf :${JUPYTER_PORT}"
  if [[ -n "$JUPYTER_TOKEN" ]]; then
    jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root           --ServerApp.token="$JUPYTER_TOKEN" --ServerApp.open_browser=False >"$LOG_DIR/jupyter.log" 2>&1 &
  else
    jupyter lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root           --ServerApp.token="" --ServerApp.password="" --ServerApp.open_browser=False >"$LOG_DIR/jupyter.log" 2>&1 &
  fi
else
  log "RUN_JUPYTER=0 – Jupyter deaktiviert."
fi

# ComfyUI (Vordergrund, via exec = saubere PID)
log "Starte ComfyUI auf :${COMFYUI_PORT}"
cd "$COMFY_DIR"
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >"$LOG_DIR/comfyui.log" 2>&1

echo "== 📦 Kopiere Web-Extensions =="
if [ -d "$HF_DIR/web_extensions" ]; then
  mkdir -p "$COMFY_DIR/web/extensions"
  rsync -a "$HF_DIR/web_extensions/" "$COMFY_DIR/web/extensions/"
  echo "   ✔ Web-Extensions aktualisiert."
else
  echo "   (keine web_extensions im HF-Bundle gefunden)"
fi

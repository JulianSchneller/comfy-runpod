#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR=/workspace/logs; mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/start.sh.stdout") 2> >(tee -a "$LOG_DIR/start.sh.stderr" >&2)

echo "[START] $(date -u +'%Y-%m-%d %H:%M:%S') UTC"
echo "== Setup =="

# --- Konfiguration (ENV aus RunPod Template) ---
: "${HF_REPO_ID:?Setze HF_REPO_ID als 'user/repo' im Template (Environment Variables).}"
: "${HF_TOKEN:?Setze HF_TOKEN im Template (Environment Variables).}"   # privat -> nötig
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
WORKSPACE=/workspace
COMFY_DIR="$WORKSPACE/ComfyUI"
VENV="$WORKSPACE/venv"

echo "Workspace : $WORKSPACE"
echo "ComfyUI   : $COMFY_DIR"
echo "Ports     : ComfyUI=$COMFYUI_PORT | Jupyter=$JUPYTER_PORT"
echo "HF_REPO_ID: $HF_REPO_ID"

# --- Einmalige System-Pakete (Idempotenz) ---
APT_STAMP=/opt/.startup_apt_done
if [[ ! -f $APT_STAMP ]]; then
  echo "== apt install =="
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl rsync jq tini python3-venv build-essential libglib2.0-0 libgl1
  touch $APT_STAMP
else
  echo "== apt install == (übersprungen)"
fi

# --- Python venv ---
if [[ ! -d "$VENV" ]]; then
  echo "== create venv =="
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip wheel setuptools
else
  echo "== create venv == (vorhanden)"
fi

# --- ComfyUI holen/aktualisieren ---
if [[ ! -d "$COMFY_DIR" ]]; then
  echo "== clone ComfyUI =="
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "== update ComfyUI =="
  (cd "$COMFY_DIR" && git pull --ff-only || true)
fi

# --- Python Abhängigkeiten ---
echo "== pip install (Comfy reqs + HF + Jupyter + Fixes) =="
"$VENV/bin/pip" install -r "$COMFY_DIR/requirements.txt" || true
"$VENV/bin/pip" install "huggingface_hub>=0.39,<1.0" "safetensors>=0.4" "opencv-python-headless" \
    "jupyterlab>=4,<5" "notebook_shim" "jupyter_nbextensions_configurator" \
    "torchsde==0.2.6"

# --- Zielordner vorbereiten ---
MODEL_DIR="$COMFY_DIR/models"
mkdir -p "$MODEL_DIR"/{checkpoints,controlnet,loras,upscale_models,faces} \
         "$COMFY_DIR/custom_nodes" \
         "$COMFY_DIR/user/default/workflows" \
         "$WORKSPACE/scripts"

# --- HF Sync via snapshot_download (mit Snapshot-Cache & Fortschritt) ---
export HF_TOKEN
echo "== HF sync von $HF_REPO_ID =="

"$VENV/bin/python" - <<'PY'
import os, sys, json, time, shutil, pathlib
from huggingface_hub import snapshot_download

repo_id   = os.environ["HF_REPO_ID"]
token     = os.environ["HF_TOKEN"]
target    = os.environ.get("HF_SNAPSHOT_DIR","/workspace/_hf_repo")
comfy     = os.environ.get("COMFY_DIR","/workspace/ComfyUI")
models    = os.path.join(comfy,"models")
wf_dir    = os.path.join(comfy,"user","default","workflows")
cache_dir = "/workspace/_hf_cache"
manifest  = os.path.join(cache_dir, "manifest.json")

path = snapshot_download(
    repo_id,
    token=token,
    repo_type="model",
    local_dir=target,
    local_dir_use_symlinks=False,
    resume_download=True
)

snapshot_id = os.path.basename(path.rstrip("/"))
pathlib.Path(cache_dir).mkdir(parents=True, exist_ok=True)

prev = {}
if os.path.exists(manifest):
    try:
        with open(manifest,"r") as f:
            prev = json.load(f)
    except Exception:
        prev = {}

prev_snap = prev.get("snapshot")
same_snapshot = (prev_snap == snapshot_id)

def list_all_files(base):
    out=[]
    for root,_,files in os.walk(base):
        for f in files:
            full = os.path.join(root,f)
            rel  = os.path.relpath(full, base)
            out.append((rel, full, os.path.getsize(full)))
    return out

def copytree_progress(src, dst, label):
    if not os.path.isdir(src): 
        return (0,0,0)
    files = list_all_files(src)
    total_bytes = sum(sz for _,_,sz in files)
    done_bytes = 0
    copied = 0
    skipped = 0
    t0 = time.time()

    for i,(rel, full, sz) in enumerate(files, 1):
        dest = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.exists(dest):
            try:
                if os.path.getsize(dest)==sz:
                    skipped += 1
                    done_bytes += sz
                    if i % 10 == 0 or i == len(files):
                        pct = 100.0*done_bytes/max(1,total_bytes)
                        print(f"[{label}] {i}/{len(files)}  skipped  {pct:5.1f}%  ({done_bytes/1e9:.2f} / {total_bytes/1e9:.2f} GB)")
                    continue
            except Exception:
                pass
        shutil.copy2(full, dest)
        copied += 1
        done_bytes += sz
        if i % 5 == 0 or i == len(files):
            pct = 100.0*done_bytes/max(1,total_bytes)
            elapsed = time.time()-t0
            rate = done_bytes/max(1,elapsed)
            eta = (total_bytes-done_bytes)/max(1,rate)
            print(f"[{label}] {i}/{len(files)}  copied  {pct:5.1f}%  {rate/1e6:6.1f} MB/s  ETA {eta:5.1f}s")
    return (copied, skipped, total_bytes)

print(f"Snapshot: {snapshot_id} (prev: {prev_snap})  same={same_snapshot}")

def report_block(title, tup):
    c,k,tot = tup
    print(f"  - {title:<12}: copied={c:5d}  skipped={k:5d}  size={tot/1e9:6.2f} GB")

if same_snapshot:
    print("Keine Änderungen im HF-Repo – Kopiervorgang übersprungen.")
else:
    print("Änderungen erkannt – Verteilen der Dateien:")
    totals = {}
    def do(src_sub, dst, label):
        s = os.path.join(path, src_sub)
        os.makedirs(dst, exist_ok=True)
        res = copytree_progress(s, dst, label)
        totals[label]=res

    do("checkpoints",    os.path.join(models,"checkpoints"), "checkpoints")
    do("controlnet",     os.path.join(models,"controlnet"),  "controlnet")
    do("loras",          os.path.join(models,"loras"),       "loras")
    do("upscale_models", os.path.join(models,"upscale_models"), "upscalers")
    do("faces",          os.path.join(models,"faces"),       "faces")
    do("custom_nodes",   os.path.join(comfy,"custom_nodes"), "custom_nodes")
    # Workflows korrekt in ComfyUI-User-Verzeichnis:
    do("workflows",      os.path.join(comfy,"user","default","workflows"), "workflows")
    do("scripts",        "/workspace/scripts",               "scripts")

    print("\n== Zusammenfassung (dieser Lauf) ==")
    for k,v in totals.items():
        report_block(k, v)

    # Manifest aktualisieren
    with open(manifest,"w") as f:
        json.dump({"snapshot": snapshot_id}, f)

# Minimal-Check: existieren die Kernmodelle?
must = [
    os.path.join(models,"checkpoints","sd_xl_base_1.0.safetensors"),
    os.path.join(models,"upscale_models","4x-UltraSharp.pth"),
]
missing = [m for m in must if not os.path.exists(m)]
if missing:
    print("\nWARN: Folgende Kernmodelle fehlen noch:")
    for m in missing: print("  •", m)
else:
    print("\nKernmodelle vorhanden ✔")

print("HF sync done")
PY

# --- Custom-Node requirements installieren (optional) ---
REQS=$(find "${COMFY_DIR}/custom_nodes" -maxdepth 2 -type f -iname "requirements.txt" || true)
if [[ -n "$REQS" ]]; then
  echo "== pip install custom_nodes requirements =="
  while IFS= read -r req; do
    echo "  - $req"
    "$VENV/bin/pip" install -r "$req" || true
  done <<< "$REQS"
else
  echo "== custom_nodes requirements == (keine gefunden)"
fi

# --- Jupyter starten ---
if ! pgrep -f "jupyter-lab.*--port=${JUPYTER_PORT}" >/dev/null 2>&1; then
  echo "== starte JupyterLab :${JUPYTER_PORT} =="
  nohup "$VENV/bin/jupyter" lab \
    --ip=0.0.0.0 --port="${JUPYTER_PORT}" --no-browser --allow-root \
    --ServerApp.token='' --ServerApp.password='' \
    > "$LOG_DIR/jupyter.log" 2>&1 &
else
  echo "== starte JupyterLab == (läuft bereits)"
fi

# --- ComfyUI starten ---
if ! pgrep -f "python.*main.py.*--port ${COMFYUI_PORT}" >/dev/null 21; then
  echo "== starte ComfyUI :${COMFYUI_PORT} =="
  nohup "$VENV/bin/python" "$COMFY_DIR/main.py" \
    --listen 0.0.0.0 --port "${COMFYUI_PORT}" \
    > "$LOG_DIR/comfyui.log" 2>&1 &
else
  echo "== starte ComfyUI == (läuft bereits)"
fi

echo "== URLs =="
echo "Jupyter : http://127.0.0.1:${JUPYTER_PORT}"
echo "ComfyUI : http://127.0.0.1:${COMFYUI_PORT}"

echo "== Tail Logs =="
tail -F "$LOG_DIR"/jupyter.log "$LOG_DIR"/comfyui.log

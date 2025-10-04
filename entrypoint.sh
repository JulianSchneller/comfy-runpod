\
    #!/usr/bin/env bash
    set -Eeuo pipefail

    # ========= Konfig / Umgebungsvariablen =========
    COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
    HF_REPO_ID="${HF_REPO_ID:-}"
    HF_TOKEN="${HF_TOKEN:-}"
    ENABLE_JUPYTER="${ENABLE_JUPYTER:-0}"
    PORT="${PORT:-8188}"
    HOST="${HOST:-0.0.0.0}"

    log() { echo -e "[entrypoint] $*"; }

    # ========= Warten bis ComfyUI da ist =========
    if [[ ! -d "$COMFY_DIR" ]]; then
      log "ComfyUI nicht gefunden unter $COMFY_DIR … warte 3s"
      sleep 3 || true
    fi
    if [[ ! -d "$COMFY_DIR" ]]; then
      log "⚠️  ComfyUI fehlt weiterhin. Ich lege Ordner an."
      mkdir -p "$COMFY_DIR"
    fi

    # ========= Python ok? =========
    if ! command -v python3 >/dev/null 2>&1; then
      log "❌ python3 nicht gefunden."
      exit 1
    fi

    # ========= HF Sync: nur, wenn HF_REPO_ID gesetzt =========
    if [[ -n "$HF_REPO_ID" ]]; then
      log "⬇️  HF Sync aus $HF_REPO_ID (nur benötigte Pfade) …"

      python3 - <<'PY'
import os, shutil, hashlib
from pathlib import Path
from huggingface_hub import snapshot_download

HF_REPO_ID = os.environ.get("HF_REPO_ID","").strip()
HF_TOKEN   = os.environ.get("HF_TOKEN","").strip()
COMFY_DIR  = os.environ.get("COMFY_DIR","/workspace/ComfyUI").strip()

stage = Path("/workspace/hf_bundle").resolve()
stage.mkdir(parents=True, exist_ok=True)

# Nur benötigte Inhalte ziehen (schneller & sparsamer)
allow = [
    "custom_nodes/ComfyUI-Advanced-ControlNet/**",
    "custom_nodes/comfyui_controlnet_aux/**",
    "annotators/ckpts/body_pose_model.pth",
    "annotators/ckpts/hand_pose_model.pth",
    "annotators/ckpts/dw-ll_ucoco_384.pth",
    "annotators/ckpts/yolox_l.onnx",
    "web_extensions/userstyle/**",
    "workflows/*.json",
]

path = snapshot_download(
    repo_id=HF_REPO_ID,
    token=(HF_TOKEN or None),
    local_dir=str(stage),
    local_dir_use_symlinks=False,
    allow_patterns=allow,
    ignore_patterns=None,
    repo_type="model"
)

def copy_tree(src:Path, dst:Path):
    dst.mkdir(parents=True, exist_ok=True)
    for root, dirs, files in os.walk(src):
        r = Path(root)
        rel = r.relative_to(src)
        (dst/rel).mkdir(parents=True, exist_ok=True)
        for f in files:
            s = r/f
            d = (dst/rel)/f
            if d.exists():
                # nur überschreiben, wenn Inhalt anders
                if os.path.getsize(s)==os.path.getsize(d):
                    with open(s,'rb') as sf, open(d,'rb') as df:
                        if hashlib.md5(sf.read()).hexdigest()==hashlib.md5(df.read()).hexdigest():
                            continue
            shutil.copy2(s, d)

stage = Path(path)

# custom_nodes
for cn in ["ComfyUI-Advanced-ControlNet", "comfyui_controlnet_aux"]:
    src = stage/"custom_nodes"/cn
    if src.exists():
        copy_tree(src, Path(COMFY_DIR)/"custom_nodes"/cn)

# annotators ckpts → symlink unter models/annotators/ckpts
ck = stage/"annotators"/"ckpts"
models_ck = Path(COMFY_DIR)/"models"/"annotators"/"ckpts"
models_ck.parent.mkdir(parents=True, exist_ok=True)
if models_ck.is_symlink() or models_ck.exists():
    pass
else:
    if ck.exists():
        try:
            os.symlink(str(ck), str(models_ck))
        except Exception:
            # Fallback: kopieren
            ck_dst = models_ck
            ck_dst.mkdir(parents=True, exist_ok=True)
            copy_tree(ck, ck_dst)

# web_extensions
we = stage/"web_extensions"
if we.exists():
    copy_tree(we, Path(COMFY_DIR)/"web_extensions")

# workflows
wfs = stage/"workflows"
if wfs.exists():
    copy_tree(wfs, Path(COMFY_DIR)/"workflows")
PY

      log "✅ HF Sync done."
    else
      log "ℹ️ HF_REPO_ID ist leer – überspringe HF Sync."
    fi

    # ========= NSFW-Bypass Patch (defensiv, idempotent) =========
    log "🛡️  NSFW-Bypass Patch anwenden (wenn Ziele existieren) …"
    python3 - <<'PY'
import re, os
from pathlib import Path

COMFY_DIR = Path(os.environ.get("COMFY_DIR","/workspace/ComfyUI"))

targets = []
# Sicherheits-/Filter-Dateien, je nach Build vorhanden/anders benannt
candidates = [
    COMFY_DIR/"comfy"/"safety.py",
    COMFY_DIR/"comfy"/"safety_check.py",
    COMFY_DIR/"custom_nodes"/"comfyui_controlnet_aux"/"safety.py",
]

for p in candidates:
    if p.exists():
        targets.append(p)

def patch_text(txt:str)->str:
    out = txt
    # 1) Funktionen, die "unsafe" markieren, neutralisieren → geben einfach original zurück
    out = re.sub(r"def\s+is_nsfw[^\:]*:[\s\S]+?return\s+.+", "def is_nsfw(*args, **kwargs):\n    return False\n", out, flags=re.M)
    out = re.sub(r"def\s+filter_nsfw[^\:]*:[\s\S]+?return\s+.+", "def filter_nsfw(image,*a,**k):\n    return image\n", out, flags=re.M)
    # 2) block_nsfw Default → False
    out = re.sub(r"block_nsfw\s*:\s*Optional\[bool\]\s*=\s*None", "block_nsfw: Optional[bool] = False", out)
    # 3) Harte Filter-Returns umgehen
    out = re.sub(r"return\s+None\s*#\s*nsfw.*", "return image", out, flags=re.I)
    return out

for p in targets:
    try:
        s = p.read_text(encoding="utf-8")
        patched = patch_text(s)
        if patched != s:
            p.write_text(patched, encoding="utf-8")
            print(f"patched: {p}")
    except Exception as e:
        print(f"skip {p}: {e}")
PY

    # ========= Optional: Jupyter =========
    if [[ "${ENABLE_JUPYTER}" == "1" ]]; then
      log "📓 Starte Jupyter (optional) …"
      nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root >/workspace/jupyter.log 2>&1 &
    else
      log "ℹ️ ENABLE_JUPYTER=0 – Jupyter wird nicht gestartet."
    fi

    # ========= ComfyUI starten =========
    cd "$COMFY_DIR"
    log "🚀 Starte ComfyUI auf ${HOST}:${PORT}"
    exec python3 main.py --listen "$HOST" --port "$PORT"

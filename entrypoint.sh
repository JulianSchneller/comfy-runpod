#!/usr/bin/env bash
set -Eeuo pipefail

# ====== Basispfade (wie in v7) ======
export WORKSPACE="${WORKSPACE:-/workspace}"
export COMFY_DIR="$WORKSPACE/ComfyUI"
export MODELS_DIR="$COMFY_DIR/models"
export LOG_DIR="$WORKSPACE/logs"
export CNODES="$COMFY_DIR/custom_nodes"
export CKPTS="$MODELS_DIR/annotators/ckpts"
export HF_DIR="${HF_DIR:-$WORKSPACE/hf_bundle}"

mkdir -p "$LOG_DIR" "$CNODES" "$CKPTS"
mkdir -p "$MODELS_DIR"/{checkpoints,loras,controlnet,upscale_models,faces,vae,clip_vision,style_models,embeddings,diffusers,vae_approx}
mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/web/extensions" "$HF_DIR"

log(){ printf "[%s] %s\n" "$(date -u +'%F %T UTC')" "$*"; }

# ====== ENV / Ports ======
export HF_REPO_ID="${HF_REPO_ID:-}"      # z.B. Floorius/comfyui-model-bundle
export HF_TOKEN="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"
export HF_REQUIRE_TOKEN="${HF_REQUIRE_TOKEN:-1}"  # 1: Token Pflicht (vermeidet 401 in privaten Repos)
export COMFYUI_PORT="${COMFYUI_PORT:-8188}"
export JUPYTER_ENABLE="${JUPYTER_ENABLE:-0}"
export JUPYTER_PORT="${JUPYTER_PORT:-8888}"

# ====== NSFW-Bypass via sitecustomize.py ======
PY_PATCH_DIR="$WORKSPACE/py_patches"
mkdir -p "$PY_PATCH_DIR"
cat > "$PY_PATCH_DIR/sitecustomize.py" <<'PY'
# Neutralisiert Diffusers SafetyChecker & entfernt safety_checker-Instanz in SD/SDXL-Pipelines.
try:
    from importlib import import_module
    try:
        sc_mod = import_module("diffusers.pipelines.stable_diffusion.safety_checker")
        _Orig = getattr(sc_mod, "StableDiffusionSafetyChecker", None)
    except Exception:
        _Orig = None
    if _Orig is not None:
        class _Bypass(_Orig):  # type: ignore
            def forward(self, *args, **kwargs):
                images = kwargs.get("images", None)
                if images is None and args:
                    images = args[-1]
                return images, [False] * (len(images) if hasattr(images, "__len__") else 1)
            __call__ = forward
        sc_mod.StableDiffusionSafetyChecker = _Bypass

    def _nullify(modpath):
        try:
            pm = import_module(modpath)
            for name in dir(pm):
                cls = getattr(pm, name, None)
                if getattr(cls, "__init__", None) and hasattr(cls.__init__, "__code__"):
                    if "safety_checker" in cls.__init__.__code__.co_varnames:
                        _init = cls.__init__
                        def _wrap(self, *a, **k):
                            _init(self, *a, **k)
                            try: setattr(self, "safety_checker", None)
                            except Exception: pass
                        cls.__init__ = _wrap
        except Exception:
            pass

    for p in [
        "diffusers.pipelines.stable_diffusion.pipeline_stable_diffusion",
        "diffusers.pipelines.stable_diffusion.pipeline_stable_diffusion_xl",
        "diffusers.pipelines.auto_pipeline",
    ]:
        _nullify(p)
except Exception:
    pass
PY
export PYTHONPATH="$PY_PATCH_DIR:$PYTHONPATH"

# ====== Helper ======
copy_into(){ # rsync (wenn da) sonst cp -rn
  local src="$1" dst="$2"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --ignore-existing "$src"/ "$dst"/
  else
    shopt -s dotglob || true
    cp -rn "$src"/* "$dst"/ 2>/dev/null || true
  fi
}

dl_if_missing(){
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then log "✔ vorhanden: $out"; return 0; fi
  log "⬇ $out"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    curl -L --fail --retry 5 --connect-timeout 15 -H "Authorization: Bearer $HF_TOKEN" "$url" -o "$out"
  else
    curl -L --fail --retry 5 --connect-timeout 15 "$url" -o "$out"
  fi
}

clone_or_update(){
  local url="$1" dir="$2"
  if [[ ! -d "$dir/.git" ]]; then
    log "⬇ $url → $dir"
    git clone --depth=1 "$url" "$dir" || true
  else
    log "↻ pull $dir"
    (cd "$dir" && git pull --ff-only || true)
  fi
}

# ====== Custom Node: nur ControlNet-Aux (kein Advanced/InstantID) ======
log "== 🧩 Custom Nodes: comfyui_controlnet_aux =="
clone_or_update "https://github.com/Fannovel16/comfyui_controlnet_aux.git" "$CNODES/comfyui_controlnet_aux"
if command -v pip >/dev/null 2>&1; then
  pip install --no-cache-dir -r "$CNODES/comfyui_controlnet_aux/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
fi

# ====== HF Bundle Sync (Workflows/Models/Web-Extensions) ======
if [[ -n "${HF_REPO_ID:-}" ]]; then
  if [[ "$HF_REQUIRE_TOKEN" = "1" && -z "${HF_TOKEN:-}" ]]; then
    log "HF Sync übersprungen (HF_TOKEN fehlt & REQUIRE_TOKEN=1)"
  else
    python - <<'PY' || true
import os
from pathlib import Path
from huggingface_hub import snapshot_download

repo = os.environ.get("HF_REPO_ID","")
token = os.environ.get("HF_TOKEN") or None
stage = Path(os.environ.get("HF_DIR","/workspace/hf_bundle"))
stage.mkdir(parents=True, exist_ok=True)
print("[HF] snapshot_download:", repo, "→", stage)

snapshot_download(
    repo_id=repo,
    revision="main",
    local_dir=str(stage),
    token=token,
    local_dir_use_symlinks=False
)
print("[HF] snapshot OK")
PY
    # Kopieren in Comfy-Struktur
    if [[ -d "$HF_DIR/models" ]]; then
      copy_into "$HF_DIR/models" "$MODELS_DIR";      log "✔ Modelle synchronisiert"
    fi
    if [[ -d "$HF_DIR/workflows" ]]; then
      copy_into "$HF_DIR/workflows" "$COMFY_DIR/user/default/workflows"; log "✔ Workflows synchronisiert"
    fi
    if [[ -d "$HF_DIR/web_extensions" ]]; then
      copy_into "$HF_DIR/web_extensions" "$COMFY_DIR/web/extensions"; log "✔ Web-Extensions synchronisiert"
    fi
  fi
else
  log "HF_REPO_ID nicht gesetzt → kein HF Sync"
fi

# ====== Annotator-CKPT Symlinks für controlnet_aux ======
# 1) Zielpfade, die von controlnet_aux erwartet werden
AUX1="$CNODES/comfyui_controlnet_aux/ckpts"
AUX2="$CNODES/comfyui_controlnet_aux/annotator/ckpts"
mkdir -p "$(dirname "$AUX1")" "$(dirname "$AUX2")"
ln -sf "$CKPTS" "$AUX1" || true
ln -sf "$CKPTS" "$AUX2" || true

# ====== OpenPose/DWPose: nur Fallback-Download, falls HF-Bundle nichts geliefert hat ======
need_any=0
for f in \
  "$CKPTS/body_pose_model.pth" \
  "$CKPTS/hand_pose_model.pth" \
  "$CKPTS/facenet.pth" \
  "$CKPTS/dw-ll_ucoco_384.pth" \
  "$CKPTS/yolox_l.onnx" \
  "$CKPTS/yolox_l.torchscript"
do
  [[ -f "$f" ]] || need_any=1
done

if [[ $need_any -eq 1 ]]; then
  log "== 🧠 OpenPose/DWPose Fallback-Downloads =="
  dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/body_pose_model.pth" "$CKPTS/body_pose_model.pth" || true
  dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/hand_pose_model.pth" "$CKPTS/hand_pose_model.pth" || true
  # facenet ist optional; wenn 404/privat → ignorieren
  dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/facenet.pth" "$CKPTS/facenet.pth" || true
  dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth" "$CKPTS/dw-ll_ucoco_384.pth" || true
  dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"        "$CKPTS/yolox_l.onnx" || true
  # torchscript ist optional – wenn privat/404, egal
  dl_if_missing "https://huggingface.co/monster-labs/controlnet_aux_models/resolve/main/yolox_l.torchscript" "$CKPTS/yolox_l.torchscript" || true
fi

# ====== Optional: Jupyter ======
if [[ "${JUPYTER_ENABLE}" == "1" ]]; then
  log "== 🧪 Starte JupyterLab (Port ${JUPYTER_PORT}) =="
  nohup jupyter-lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser >"$LOG_DIR/jupyter.log" 2>&1 &
fi

# ====== Sanity Log: NSFW-Patch ======
python - <<'PY' || true
try:
    from diffusers.pipelines.stable_diffusion.safety_checker import StableDiffusionSafetyChecker
    print("[NSFW] SafetyChecker:", StableDiffusionSafetyChecker.__name__)
except Exception as e:
    print("[NSFW] diffusers Checker nicht importierbar (ok falls nicht genutzt):", e)
PY

# ====== Start ComfyUI ======
cd "$COMFY_DIR"
log "== 🚀 Starte ComfyUI (Port ${COMFYUI_PORT}) =="
exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >>"$LOG_DIR/comfyui.log" 2>&1

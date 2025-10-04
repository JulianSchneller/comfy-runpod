\
    #!/usr/bin/env bash
    set -Eeuo pipefail

    # ====== Basispfade ======
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
    export HF_TOKEN="${HF_TOKEN:-}"          # hf_*
    export COMFYUI_PORT="${COMFYUI_PORT:-8188}"
    export JUPYTER_ENABLE="${JUPYTER_ENABLE:-0}"
    export JUPYTER_PORT="${JUPYTER_PORT:-8888}"

    # ====== Kopier-Helper ======
    copy_into(){ # copy src/ -> dst/ (rsync wenn da, sonst cp -rn)
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
      if [[ -f "$out" ]]; then echo "✔️  vorhanden: $out"; return 0; fi
      echo "⬇️  $out"
      if [[ -n "${HF_TOKEN:-}" ]]; then
        curl -L --fail --retry 5 --connect-timeout 15 -H "Authorization: Bearer $HF_TOKEN" "$url" -o "$out"
      else
        curl -L --fail --retry 5 --connect-timeout 15 "$url" -o "$out"
      fi
    }

    clone_or_update(){
      local url="$1" dir="$2"
      if [[ ! -d "$dir/.git" ]]; then
        echo "⬇️  $url → $dir"
        git clone --depth=1 "$url" "$dir" || true
      else
        echo "↻  pull $dir"
        (cd "$dir" && git pull --ff-only || true)
      fi
    }

    # ====== NSFW-Sicherheit global deaktivieren (sitecustomize.py) ======
    PY_PATCH_DIR="$WORKSPACE/py_patches"
    mkdir -p "$PY_PATCH_DIR"
    cat > "$PY_PATCH_DIR/sitecustomize.py" <<'PY'
import sys
# Diffusers Safety Checker neutralisieren (falls installiert/benutzt)
try:
    import types
    from importlib import import_module

    try:
        sc_mod = import_module("diffusers.pipelines.stable_diffusion.safety_checker")
        _Orig = getattr(sc_mod, "StableDiffusionSafetyChecker", None)
    except Exception:
        _Orig = None

    if _Orig is not None:
        class _Bypass(_Orig):  # type: ignore
            # Bewusst sehr tolerant bzgl. Signatur
            def forward(self, *args, **kwargs):
                images = None
                if args:
                    images = args[-1]
                if images is None:
                    images = kwargs.get("images", None)
                # Rückgabe wie erwartet: (images, has_nsfw_concept)
                return images, [False] * (len(images) if hasattr(images, "__len__") else 1)

            __call__ = forward

        sc_mod.StableDiffusionSafetyChecker = _Bypass

    # Pipelines versuchen wir zusätzlich zu entkoppeln
    def _nullify(attr):
        try:
            pm = import_module(attr)
            for cls_name in dir(pm):
                try:
                    cls = getattr(pm, cls_name)
                    if hasattr(cls, "__init__") and "safety_checker" in (cls.__init__.__code__.co_varnames if hasattr(cls.__init__, "__code__") else ()):
                        _init = cls.__init__
                        def _wrap(self, *a, **k):
                            _init(self, *a, **k)
                            try:
                                setattr(self, "safety_checker", None)
                            except Exception:
                                pass
                        cls.__init__ = _wrap  # type: ignore
                except Exception:
                    pass
        except Exception:
            pass

    for pipe in [
        "diffusers.pipelines.stable_diffusion.pipeline_stable_diffusion",
        "diffusers.pipelines.stable_diffusion.pipeline_stable_diffusion_xl",
        "diffusers.pipelines.auto_pipeline",
    ]:
        _nullify(pipe)
except Exception:
    pass
PY
    export PYTHONPATH="$PY_PATCH_DIR:$PYTHONPATH"

    echo "== 🧩 Custom Nodes (ControlNet/Aux) =="
    clone_or_update "https://github.com/Kosinkadink/ComfyUI-Advanced-ControlNet.git" "$CNODES/ComfyUI-Advanced-ControlNet"
    clone_or_update "https://github.com/Fannovel16/comfyui_controlnet_aux.git"       "$CNODES/comfyui_controlnet_aux"

    if command -v pip >/dev/null 2>&1; then
      pip install --no-cache-dir -r "$CNODES/comfyui_controlnet_aux/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
      if [[ -f "$CNODES/ComfyUI-Advanced-ControlNet/requirements.txt" ]]; then
        pip install --no-cache-dir -r "$CNODES/ComfyUI-Advanced-ControlNet/requirements.txt" >>"$LOG_DIR/pip.log" 2>&1 || true
      fi
    fi

    echo "== 🧠 OpenPose/DWPose CKPTs =="
    dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/body_pose_model.pth" "$CKPTS/body_pose_model.pth" || true
    dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/hand_pose_model.pth" "$CKPTS/hand_pose_model.pth" || true
    dl_if_missing "https://huggingface.co/lllyasviel/ControlNet/resolve/main/annotator/ckpts/facenet.pth" "$CKPTS/facenet.pth" || true
    dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.pth" "$CKPTS/dw-ll_ucoco_384.pth" || true
    dl_if_missing "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"        "$CKPTS/yolox_l.onnx" || true
    dl_if_missing "https://huggingface.co/monster-labs/controlnet_aux_models/resolve/main/yolox_l.torchscript" "$CKPTS/yolox_l.torchscript" || true

    echo "== 📦 HF Bundle Sync (${HF_REPO_ID:-<none>}) =="
    if [[ -n "${HF_REPO_ID:-}" && -n "${HF_TOKEN:-}" ]]; then
      python - <<'PY' || true
import os
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download, login

repo = os.environ['HF_REPO_ID']
token = os.environ['HF_TOKEN']
stage = Path(os.environ.get('HF_DIR','/workspace/hf_bundle'))
login(token=token, add_to_git_credential=False)
api = HfApi()
stage.mkdir(parents=True, exist_ok=True)

files = api.list_repo_files(repo_id=repo, repo_type="model")
def sync(prefix, dest, allow=None):
    d = stage/dest; d.mkdir(parents=True, exist_ok=True)
    for f in files:
        if not f.startswith(prefix + "/"): continue
        if allow and not any(f.lower().endswith(ext) for ext in allow): continue
        hf_hub_download(repo_id=repo, filename=f, local_dir=d, local_dir_use_symlinks=False)

sync("checkpoints","models/checkpoints")
sync("loras","models/loras")
sync("controlnet","models/controlnet")
sync("upscale_models","models/upscale_models")
sync("faces","models/faces")
sync("vae","models/vae")
sync("clip_vision","models/clip_vision")
sync("style_models","models/style_models")
sync("embeddings","models/embeddings")
sync("diffusers","models/diffusers")
sync("vae_approx","models/vae_approx")
sync("workflows","workflows", allow=[".json"])
sync("web_extensions","web_extensions")
print("[HF] sync done →", stage)
PY
    else
      log "HF Direct Download übersprungen (HF_REPO_ID/HF_TOKEN fehlen)."
    fi

    echo "== 📦 Kopiere aus HF Stage =="
    if [[ -d "$HF_DIR/models" ]]; then
      copy_into "$HF_DIR/models" "$MODELS_DIR"
      echo "   ✔ Modelle → $MODELS_DIR"
    else
      echo "   (keine models im HF-Bundle gefunden)"
    fi

    if [[ -d "$HF_DIR/workflows" ]]; then
      mkdir -p "$COMFY_DIR/user/default/workflows"
      copy_into "$HF_DIR/workflows" "$COMFY_DIR/user/default/workflows"
      echo "   ✔ Workflows → $COMFY_DIR/user/default/workflows"
    else
      echo "   (keine workflows im HF-Bundle gefunden)"
    fi

    if [[ -d "$HF_DIR/web_extensions" ]]; then
      copy_into "$HF_DIR/web_extensions" "$COMFY_DIR/web/extensions"
      echo "   ✔ Web-Extensions aktualisiert."
    else
      echo "   (keine web_extensions im HF-Bundle gefunden)"
    fi

    # Optional: Jupyter
    if [[ "${JUPYTER_ENABLE}" == "1" ]]; then
      echo "== 🧪 Starte JupyterLab (Port ${JUPYTER_PORT}) =="
      nohup jupyter-lab --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser >"$LOG_DIR/jupyter.log" 2>&1 &
    fi

    # Kurzer NSFW-Patch-Sanity-Check (falls diffusers installiert ist)
    python - <<'PY' || true
try:
    from diffusers.pipelines.stable_diffusion.safety_checker import StableDiffusionSafetyChecker
    print("[NSFW] SafetyChecker Klasse:", StableDiffusionSafetyChecker.__name__)
except Exception as e:
    print("[NSFW] diffusers nicht vorhanden oder Checker nicht importierbar:", e)
PY

    cd "$COMFY_DIR"
    echo "== 🚀 Starte ComfyUI (Port ${COMFYUI_PORT}) =="
    exec python main.py --listen 0.0.0.0 --port "$COMFYUI_PORT" >"$LOG_DIR/comfyui.log" 2>&1

# comfy-runpod (ComfyUI on RunPod via GHCR)

- **Image**: `ghcr.io/JulianSchneller/comfy-runpod:latest`
- **Start Command (RunPod)**: `/bin/bash -lc "/workspace/start.sh"`

### Environment Variables (RunPod Template)
- `HF_REPO_ID` = Floorius/comfyui-model-bundle   # privates HF-Bundle
- `HF_TOKEN`   = <dein_neuer_HF_Token (read)>
- optional:
  - `COMFYUI_PORT=8188`
  - `JUPYTER_PORT=8888`

### Ports (HTTP)
- 8188 (ComfyUI)
- 8888 (JupyterLab)

### Volumes
- Mount Path: `/workspace`

FROM pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime
# ---- Pip Index & Hf Hub Pin (robust) ----
ENV PIP_INDEX_URL="https://pypi.org/simple" \
    PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu121"

RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    python -m pip install --no-cache-dir "huggingface_hub==0.35.3"
# -----------------------------------------

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    COMFYUI_PORT=8188 \
    JUPYTER_PORT=8888

RUN bash -lc 'mkdir -p /opt/runpod $WORKSPACE/logs && apt-get update && \
    apt-get install -y --no-install-recommends git curl rsync jq tini python3-venv build-essential libglib2.0-0 libgl1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*'

# Startskript ins Image kopieren (außerhalb vom Volume)
COPY start.sh /opt/runpod/start.sh
RUN chmod +x /opt/runpod/start.sh

WORKDIR /workspace

# Start immer über unser Skript
ENTRYPOINT ["/bin/bash","/opt/runpod/start.sh"]

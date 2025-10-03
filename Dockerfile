FROM pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    COMFYUI_PORT=8188 \
    JUPYTER_PORT=8888

# System-Pakete
RUN apt-get update && \
# JupyterLab (für optionales Notebook)
RUN python -m pip install --no-cache-dir --upgrade pip wheel \
    && python -m pip install --no-cache-dir "jupyterlab>=4,<5" "jupyter_server>=2,<3"
    apt-get install -y --no-install-recommends git curl rsync jq python3-venv build-essential libglib2.0-0 libgl1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Pip-Basis & stabile Hub-Version
ENV PIP_INDEX_URL="https://pypi.org/simple" \
    PIP_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu121"
RUN python -m pip install --no-cache-dir -U pip wheel setuptools && \
    python -m pip install --no-cache-dir "huggingface_hub==0.35.3" "rich" "tqdm" "uvicorn[standard]" "fastapi"

WORKDIR /workspace

# Startlogik INS Image
COPY entrypoint.sh /opt/runpod/entrypoint.sh
RUN chmod +x /opt/runpod/entrypoint.sh

ENTRYPOINT ["/opt/runpod/entrypoint.sh"]

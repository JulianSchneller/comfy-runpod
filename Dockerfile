FROM pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=${DEBIAN_FRONTEND} \
    WORKSPACE=/workspace \
    COMFYUI_PORT=8188 \
    JUPYTER_PORT=8888 \
    PYTHONUNBUFFERED=1

# System-Pakete
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git curl rsync jq tini python3-venv build-essential \
        libglib2.0-0 libgl1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Python/Jupyter
RUN python -m pip install --no-cache-dir --upgrade pip wheel && \
    python -m pip install --no-cache-dir "jupyterlab>=4,<5" "jupyter_server>=2,<3"

# Lauf-Skripte (liegen im Repo-Root)
COPY start.sh /opt/runpod/start.sh
COPY entrypoint.sh /opt/runpod/entrypoint.sh
RUN chmod +x /opt/runpod/*.sh

WORKDIR /workspace
ENTRYPOINT ["/opt/runpod/entrypoint.sh"]
CMD ["bash"]

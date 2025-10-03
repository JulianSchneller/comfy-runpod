FROM pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    COMFYUI_PORT=8188 \
    JUPYTER_PORT=8888

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl rsync jq tini python3-venv build-essential \
        libglib2.0-0 libgl1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Python Basis & JupyterLab
RUN python -m pip install --upgrade pip wheel setuptools && \
    python -m pip install --no-cache-dir "jupyterlab>=4,<5" "jupyter_server>=2,<3"

# Laufzeit-Dateien
RUN mkdir -p /opt/runpod /workspace && \
    useradd -m -u 1000 -s /bin/bash app && \
    chown -R app:app /workspace /opt/runpod

COPY entrypoint.sh /opt/runpod/entrypoint.sh
RUN chmod +x /opt/runpod/entrypoint.sh

WORKDIR /workspace
EXPOSE 8188 8888
ENTRYPOINT ["/usr/bin/tini","-g","--"]
CMD ["/opt/runpod/entrypoint.sh"]

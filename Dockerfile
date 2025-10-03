FROM pytorch/pytorch:2.4.0-cuda12.1-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    COMFYUI_PORT=8188 \
    JUPYTER_PORT=8888 \
    PYTHONUNBUFFERED=1

# Systempakete + git-lfs + tini
RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs curl rsync jq tini python3-venv build-essential \
      libglib2.0-0 libgl1 ca-certificates \
    && git lfs install \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Python-Basis + Jupyter
RUN python -m pip install --no-cache-dir --upgrade pip wheel setuptools && \
    python -m pip install --no-cache-dir "jupyterlab>=4,<5" "jupyter_server>=2,<3"

# EntryPoint ablegen
RUN mkdir -p /opt/runpod /workspace
COPY entrypoint.sh /opt/runpod/entrypoint.sh
RUN chmod +x /opt/runpod/entrypoint.sh

WORKDIR /workspace
EXPOSE 8188 8888

# tini als PID1, dann unser EntryPoint
ENTRYPOINT ["/usr/bin/tini","-s","--","/opt/runpod/entrypoint.sh"]
# kein Startcommand nötig; EntryPoint macht alles

FROM runpod/pytorch:2.4.0-py3.10-cuda12.1.105-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    COMFYUI_PORT=8188 \
    JUPYTER_PORT=8888

RUN bash -lc 'mkdir -p $WORKSPACE/logs && apt-get update && \
    apt-get install -y --no-install-recommends git curl rsync jq tini python3-venv build-essential libglib2.0-0 libgl1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*'

# Startskript liegt im Volume und wird beim Start aufgerufen
COPY start.sh /workspace/start.sh
RUN chmod +x /workspace/start.sh

WORKDIR /workspace
CMD ["/bin/bash"]

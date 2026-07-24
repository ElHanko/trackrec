FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1

ARG AUDIO_SEPARATOR_VERSION=0.44.2

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    ffmpeg \
    python3 \
    python3-pip \
  && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install \
  --upgrade \
  pip \
  setuptools \
  wheel

# Fest gepinnter CUDA-12.4-Stack für moderne NVIDIA-GPUs.
RUN python3 -m pip install \
  torch==2.6.0 \
  torchvision==0.21.0 \
  torchaudio==2.6.0 \
  --index-url https://download.pytorch.org/whl/cu124

# Der installierte PyTorch-Stack erfüllt torch>=2.3.
RUN python3 -m pip install \
  "audio-separator[gpu]==${AUDIO_SEPARATOR_VERSION}" \
  "demucs==4.0.0"

RUN python3 -m pip check

# Während docker build steht keine GPU zur Verfügung.
# Deshalb werden nur Imports und Versionsstände geprüft.
RUN python3 - <<'PY'
import torch
import audio_separator

print("PyTorch:", torch.__version__)
print("CUDA Runtime:", torch.version.cuda)
print("audio-separator import: OK")

assert torch.__version__.startswith("2.6.0")
assert torch.version.cuda == "12.4"
PY

ENTRYPOINT ["audio-separator"]

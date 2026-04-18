#!/usr/bin/env bash
set -u
set -o pipefail

# ==========================
#  Basis / Pfade
# ==========================
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==========================
#  CLI Args (optional)
# ==========================
INPUT_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-dir)
      INPUT_DIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Fallback auf altes Verhalten
if [[ -z "$INPUT_DIR" ]]; then
  INPUT="$BASE/input"
else
  INPUT="$INPUT_DIR"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT="$BASE/output"
else
  OUTPUT="$OUTPUT_DIR"
fi

if [[ -n "$INPUT_DIR" ]]; then
  WORK="$INPUT/.stem-work"
else
  WORK="$BASE/work"
fi

# ==========================
#  Optionen (Env)
# ==========================
KEEP_WORK="${KEEP_WORK:-0}"
KEEP_WAV="${KEEP_WAV:-0}"
MODEL="${MODEL:-}"
BUILD="${BUILD:-0}"
USE_DEFAULT_IMAGE="${USE_DEFAULT_IMAGE:-0}"
COPY_TAGS="${COPY_TAGS:-1}"
STEM_CODEC="${STEM_CODEC:-aac}"
ONLY_FLAC="${ONLY_FLAC:-0}"

RUN_LOG="$BASE/run-$(date +%F_%H%M%S).log"

DEFAULT_GPU_IMAGE="beveradb/audio-separator:gpu"
PASCAL_IMAGE="audio-separator:pascal-cu118"
STEMGEN_IMAGE="aclmb/stemgen:v0.4.0"
STEMGEN_IMAGE_CPU="aclmb/stemgen:main-all"

log()   { echo "[INFO] $*" >>"$RUN_LOG"; }
warn()  { echo "[WARN] $*" >>"$RUN_LOG"; }
error() { echo "[ERROR] $*" | tee -a "$RUN_LOG" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { error "'$1' fehlt."; exit 1; }
}

docker_image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

# ==========================
#  Ordner
# ==========================
mkdir -p "$INPUT" "$WORK" "$OUTPUT"

echo "=== STEM TOOL CLEAN ===" | tee -a "$RUN_LOG"

# ==========================
#  Input sammeln (case-insensitive)
# ==========================
shopt -s nullglob nocaseglob
files=( "$INPUT"/*.mp3 "$INPUT"/*.wav "$INPUT"/*.flac )

if [ ${#files[@]} -eq 0 ]; then
  warn "Keine Input-Dateien gefunden."
  exit 0
fi

# ==========================
#  WAV -> FLAC
# ==========================
convert_wav_to_flac() {
  local src="$1"
  local title="$2"
  local dst="$OUTPUT/$title.flac"

  command -v ffmpeg >/dev/null || { error "ffmpeg fehlt"; return 1; }

  ffmpeg -hide_banner -loglevel error -y \
    -i "$src" -map 0:a:0 -c:a flac "$dst"
}

# ==========================
#  Docker Setup
# ==========================
need_cmd docker

if [ "$USE_DEFAULT_IMAGE" = "1" ]; then
  if ! docker_image_exists "$DEFAULT_GPU_IMAGE"; then
    docker pull "$DEFAULT_GPU_IMAGE" || exit 1
  fi
  SEPARATOR_IMAGE="$DEFAULT_GPU_IMAGE"
else
  SEPARATOR_IMAGE="$PASCAL_IMAGE"

  if [ "$BUILD" = "1" ] || ! docker_image_exists "$PASCAL_IMAGE"; then
    echo "[BUILD] Baue Pascal Image..."

    BUILD_DIR="$BASE/.build/pascal"
    mkdir -p "$BUILD_DIR"

    cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM nvidia/cuda:11.8.0-base-ubuntu22.04

# --- direkte Basiswerkzeuge ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg python3 python3-pip git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# --- pip aktuell halten ---
RUN python3 -m pip install --upgrade pip

# --- bewusste Pascal/cu118-Abweichung von Upstream ---
# Upstream will numpy >=2 und torch >=2.3.
# Wir halten hier bewusst an einem konservativen Pascal/cu118-Stack fest.
RUN python3 -m pip install "numpy<2"

RUN python3 -m pip install \
    torch==2.2.2+cu118 \
    torchvision==0.17.2+cu118 \
    torchaudio==2.2.2+cu118 \
    --index-url https://download.pytorch.org/whl/cu118

# --- ONNX Runtime für CUDA 11.x offiziell laut ORT-Doku ---
RUN python3 -m pip install \
    coloredlogs flatbuffers packaging protobuf sympy

RUN python3 -m pip install \
    onnxruntime-gpu \
    --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-11/pypi/simple/

# --- audio-separator selbst ohne automatische Dependency-Auflösung ---
RUN python3 -m pip install --no-deps audio-separator==0.44.1

# --- direkte Runtime-Dependencies aus audio-separator 0.44.1,
#     manuell gesetzt für kontrollierten Legacy-Stack ---
RUN python3 -m pip install \
    "requests>=2" \
    "librosa>=0.10" \
    "samplerate==0.1.0" \
    "six>=1.16" \
    "tqdm" \
    "pydub>=0.25" \
    "julius>=0.2" \
    "diffq>=0.2" \
    "einops>=0.7" \
    "pyyaml" \
    "ml_collections" \
    "resampy>=0.4" \
    "beartype==0.18.5" \
    "rotary-embedding-torch==0.6.1" \
    "scipy>=1.13,<1.14" \
    "soundfile>=0.12"

# --- Demucs bewusst zusätzlich für htdemucs-Workflow ---
RUN python3 -m pip install demucs==4.0.0

# --- echte Checks statt Hoffen ---
RUN python3 -c "import torch; print('torch.cuda.is_available =', torch.cuda.is_available()); raise SystemExit(0 if torch.cuda.is_available() else 1)"

RUN audio-separator --env_info

ENTRYPOINT ["audio-separator"]
EOF

    docker build -t "$PASCAL_IMAGE" "$BUILD_DIR" || exit 1
  fi
fi

# CUDA Check
docker run --rm --gpus all "$SEPARATOR_IMAGE" \
  python3 -c "import torch; exit(0 if torch.cuda.is_available() else 1)" \
  || { error "CUDA nicht verfügbar"; exit 1; }

# ==========================
#  Verarbeitung
# ==========================
for file in "${files[@]}"; do
  name="$(basename "$file")"
  title="${name%.*}"

  stemdir="$WORK/$title"
  out="$OUTPUT/$title.stem.mp4"

  [ -f "$out" ] && continue

  mkdir -p "$stemdir"

  # Separation
  docker run --rm --gpus all \
    -v "$BASE":"$BASE" \
    "$SEPARATOR_IMAGE" "$file" \
    --output_dir "$stemdir" \
    --output_format flac \
    -m "${MODEL:-htdemucs.yaml}" \
    || { error "Separation failed: $title"; continue; }

  # Stems finden
  vocals=$(ls "$stemdir"/*vocal*.flac 2>/dev/null | head -n1)
  drums=$(ls "$stemdir"/*drum*.flac 2>/dev/null | head -n1)
  bass=$(ls "$stemdir"/*bass*.flac 2>/dev/null | head -n1)
  other=$(ls "$stemdir"/*other*.flac 2>/dev/null | head -n1)

  if [ -z "$vocals" ] || [ -z "$drums" ] || [ -z "$bass" ] || [ -z "$other" ]; then
    error "Stems fehlen: $title"
    continue
  fi

  # stemgen image
  if ! docker_image_exists "$STEMGEN_IMAGE"; then
    docker pull "$STEMGEN_IMAGE" || STEMGEN_IMAGE="$STEMGEN_IMAGE_CPU"
  fi

  docker run --rm -v "$BASE":"$BASE" "$STEMGEN_IMAGE" create \
    --mastered "$file" \
    --codec "$STEM_CODEC" \
    --drum "$drums" \
    --bass "$bass" \
    --other "$other" \
    --vocal "$vocals" \
    "$out" \
    || { error "Stemgen failed: $title"; continue; }

  # WAV optional löschen
  if [[ "$file" == *.wav && "$KEEP_WAV" -eq 0 ]]; then
    convert_wav_to_flac "$file" "$title"
    rm -f "$file"
  fi

  [ "$KEEP_WORK" -eq 0 ] && rm -rf "$stemdir"

  echo "[OK] $title"
done

echo "[DONE]"
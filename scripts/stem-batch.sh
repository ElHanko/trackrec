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
      [[ $# -ge 2 ]] || { echo "--input-dir benötigt einen Wert" >&2; exit 2; }
      INPUT_DIR="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "--output-dir benötigt einen Wert" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'HELP'
Nutzung:
  stem-batch.sh [--input-dir ORDNER] [--output-dir ORDNER]

GPU-Profile über Umgebungsvariablen:
  GPU_PROFILE=auto      GPU automatisch erkennen (Standard)
  GPU_PROFILE=pascal    Pascal-Image mit CUDA 11.8
  GPU_PROFILE=modern    Modernes Image mit CUDA 12.4

Kompatibler Alt-Schalter:
  USE_DEFAULT_IMAGE=1   entspricht GPU_PROFILE=modern
  USE_DEFAULT_IMAGE=0   entspricht GPU_PROFILE=pascal

Weitere Optionen:
  BUILD=1               gewähltes Image neu bauen
  KEEP_WORK=1           getrennte FLAC-Stems behalten
  KEEP_WAV=1            WAV-Eingaben nicht nach FLAC konvertieren/löschen
  MODEL=...             Audio-Separator-Modell, Standard: htdemucs.yaml
  STEM_CODEC=aac        Codec des erzeugten .stem.mp4
HELP
      exit 0
      ;;
    *)
      echo "Unbekanntes Argument: $1" >&2
      exit 2
      ;;
  esac
done

# Fallback auf altes Verhalten
INPUT="${INPUT_DIR:-$BASE/input}"
OUTPUT="${OUTPUT_DIR:-$BASE/output}"

mkdir -p "$INPUT" "$OUTPUT"
INPUT="$(realpath "$INPUT")"
OUTPUT="$(realpath "$OUTPUT")"

if [[ -n "$INPUT_DIR" ]]; then
  WORK="$INPUT/.stem-work"
else
  WORK="$BASE/work"
fi

WORK="$(realpath -m "$WORK")"
MODEL_CACHE="$(realpath -m "${MODEL_CACHE:-$BASE/models}")"

# ==========================
#  Optionen (Env)
# ==========================
KEEP_WORK="${KEEP_WORK:-0}"
KEEP_WAV="${KEEP_WAV:-0}"
MODEL="${MODEL:-htdemucs.yaml}"
BUILD="${BUILD:-0}"
COPY_TAGS="${COPY_TAGS:-1}"
STEM_CODEC="${STEM_CODEC:-aac}"
ONLY_FLAC="${ONLY_FLAC:-0}"

# GPU_PROFILE ist der neue Schalter. USE_DEFAULT_IMAGE bleibt kompatibel.
GPU_PROFILE="${GPU_PROFILE:-${STEM_GPU_PROFILE:-}}"
if [[ -z "$GPU_PROFILE" ]]; then
  if [[ -n "${USE_DEFAULT_IMAGE+x}" ]]; then
    case "$USE_DEFAULT_IMAGE" in
      1) GPU_PROFILE="modern" ;;
      0) GPU_PROFILE="pascal" ;;
      *) echo "USE_DEFAULT_IMAGE muss 0 oder 1 sein" >&2; exit 2 ;;
    esac
  else
    GPU_PROFILE="auto"
  fi
fi

RUN_LOG="$BASE/run-$(date +%F_%H%M%S).log"

PASCAL_IMAGE="${PASCAL_IMAGE:-audio-separator:pascal-cu118}"
MODERN_IMAGE="${MODERN_IMAGE:-audio-separator:modern-cu124}"
PASCAL_AUDIO_SEPARATOR_VERSION="${PASCAL_AUDIO_SEPARATOR_VERSION:-0.44.1}"
MODERN_AUDIO_SEPARATOR_VERSION="${MODERN_AUDIO_SEPARATOR_VERSION:-0.44.2}"

STEMGEN_IMAGE="${STEMGEN_IMAGE:-aclmb/stemgen:v0.4.0-cuda}"

log()   { echo "[INFO] $*" >>"$RUN_LOG"; }
warn()  { echo "[WARN] $*" >>"$RUN_LOG"; }
error() { echo "[ERROR] $*" | tee -a "$RUN_LOG" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "'$1' fehlt."
    exit 1
  }
}

docker_image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

# ==========================
#  Ordner
# ==========================
mkdir -p "$INPUT" "$WORK" "$OUTPUT" "$MODEL_CACHE"

echo "=== STEM TOOL CLEAN ===" | tee -a "$RUN_LOG"

# ==========================
#  Input sammeln (case-insensitive)
# ==========================
shopt -s nullglob nocaseglob

if [[ "$ONLY_FLAC" -eq 1 ]]; then
  files=("$INPUT"/*.flac)
else
  files=("$INPUT"/*.mp3 "$INPUT"/*.wav "$INPUT"/*.flac)
fi

if [[ ${#files[@]} -eq 0 ]]; then
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

  command -v ffmpeg >/dev/null || {
    error "ffmpeg fehlt"
    return 1
  }

  ffmpeg -hide_banner -loglevel error -y \
    -i "$src" -map 0:a:0 -c:a flac "$dst"
}

# ==========================
#  Docker Images bauen
# ==========================
build_pascal_image() {
  local build_dir="$BASE/.build/pascal"
  mkdir -p "$build_dir"

  cat > "$build_dir/Dockerfile" <<'DOCKERFILE'
FROM nvidia/cuda:11.8.0-base-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1

ARG AUDIO_SEPARATOR_VERSION=0.44.1

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    ffmpeg \
    git \
    python3 \
    python3-pip \
  && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel

# Bewusst konservativer Pascal-/CUDA-11.8-Stack.
RUN python3 -m pip install "numpy<2"

RUN python3 -m pip install \
    torch==2.2.2+cu118 \
    torchvision==0.17.2+cu118 \
    torchaudio==2.2.2+cu118 \
    --index-url https://download.pytorch.org/whl/cu118

RUN python3 -m pip install \
    coloredlogs \
    flatbuffers \
    packaging \
    protobuf \
    sympy

RUN python3 -m pip install \
    onnxruntime-gpu \
    --index-url https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/onnxruntime-cuda-11/pypi/simple/

RUN python3 -m pip install --no-deps \
    "audio-separator==${AUDIO_SEPARATOR_VERSION}"

RUN python3 -m pip install \
    "requests>=2" \
    "librosa>=0.10" \
    "samplerate==0.1.0" \
    "six>=1.16" \
    tqdm \
    "pydub>=0.25" \
    "julius>=0.2" \
    "diffq>=0.2" \
    "einops>=0.7" \
    pyyaml \
    ml_collections \
    "resampy>=0.4" \
    "beartype==0.18.5" \
    "rotary-embedding-torch==0.6.1" \
    "scipy>=1.13,<1.14" \
    "soundfile>=0.12" \
    "demucs==4.0.0"

# Beim Image-Build ist keine GPU verfügbar. Deshalb nur Imports/Versionen prüfen.
RUN python3 - <<'PY'
import torch
import audio_separator

print("PyTorch:", torch.__version__)
print("CUDA Runtime:", torch.version.cuda)
print("audio-separator import: OK")

assert torch.__version__.startswith("2.2.2")
assert torch.version.cuda == "11.8"
PY

ENTRYPOINT ["audio-separator"]
DOCKERFILE

  echo "[BUILD] Baue Pascal-Image: $PASCAL_IMAGE"
  docker build \
    --build-arg "AUDIO_SEPARATOR_VERSION=$PASCAL_AUDIO_SEPARATOR_VERSION" \
    -t "$PASCAL_IMAGE" \
    "$build_dir"
}

build_modern_image() {
  local build_dir="$BASE/.build/modern-cu124"
  mkdir -p "$build_dir"

  cat > "$build_dir/Dockerfile" <<'DOCKERFILE'
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

RUN python3 -m pip install --upgrade pip setuptools wheel

# Fest gepinnter moderner CUDA-12.4-Stack für aktuelle NVIDIA-GPUs.
RUN python3 -m pip install \
    torch==2.6.0 \
    torchvision==0.21.0 \
    torchaudio==2.6.0 \
    --index-url https://download.pytorch.org/whl/cu124

# Der bereits installierte Torch-Stack erfüllt torch>=2.3 und wird daher nicht ersetzt.
RUN python3 -m pip install \
    "audio-separator[gpu]==${AUDIO_SEPARATOR_VERSION}" \
    "demucs==4.0.0"

RUN python3 -m pip check

# Beim Image-Build ist keine GPU verfügbar. Deshalb nur Imports/Versionen prüfen.
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
DOCKERFILE

  echo "[BUILD] Baue modernes Image: $MODERN_IMAGE"
  docker build \
    --build-arg "AUDIO_SEPARATOR_VERSION=$MODERN_AUDIO_SEPARATOR_VERSION" \
    -t "$MODERN_IMAGE" \
    "$build_dir"
}

# ==========================
#  GPU-Profil wählen
# ==========================
detect_gpu_profile() {
  local compute_cap=""
  local compute_major=""
  local gpu_name=""

  need_cmd nvidia-smi

  compute_cap="$(
    nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
      | head -n1 \
      | tr -d '[:space:]'
  )"

  if [[ "$compute_cap" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    compute_major="${BASH_REMATCH[1]}"

    if (( compute_major <= 6 )); then
      printf '%s\n' "pascal"
    else
      printf '%s\n' "modern"
    fi
    return 0
  fi

  gpu_name="$(
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
      | head -n1
  )"

  case "$gpu_name" in
    *GTX\ 10*|*Quadro\ P*|*Tesla\ P*|*P100*|*P40*|*P4*)
      printf '%s\n' "pascal"
      ;;
    "")
      error "GPU konnte nicht erkannt werden. Setze GPU_PROFILE=pascal oder modern."
      exit 2
      ;;
    *)
      printf '%s\n' "modern"
      ;;
  esac
}

need_cmd docker
need_cmd realpath

if [[ "$GPU_PROFILE" == "auto" ]]; then
  GPU_PROFILE="$(detect_gpu_profile)"
fi

case "$GPU_PROFILE" in
  pascal)
    SEPARATOR_IMAGE="$PASCAL_IMAGE"
    if [[ "$BUILD" -eq 1 ]] || ! docker_image_exists "$SEPARATOR_IMAGE"; then
      build_pascal_image || exit 1
    fi
    ;;
  modern)
    SEPARATOR_IMAGE="$MODERN_IMAGE"
    if [[ "$BUILD" -eq 1 ]] || ! docker_image_exists "$SEPARATOR_IMAGE"; then
      build_modern_image || exit 1
    fi
    ;;
  *)
    error "Ungültiges GPU_PROFILE: $GPU_PROFILE (erlaubt: auto, pascal, modern)"
    exit 2
    ;;
esac

echo "[INFO] GPU-Profil: $GPU_PROFILE" | tee -a "$RUN_LOG"
echo "[INFO] Image     : $SEPARATOR_IMAGE" | tee -a "$RUN_LOG"

# ==========================
#  CUDA-Laufzeittest
# ==========================
docker run --rm \
  --gpus all \
  --entrypoint python3 \
  "$SEPARATOR_IMAGE" \
  -c '
import torch

print("PyTorch:", torch.__version__)
print("CUDA Runtime:", torch.version.cuda)
print("CUDA verfügbar:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))

raise SystemExit(0 if torch.cuda.is_available() else 1)
' || {
  error "CUDA im gewählten Image nicht verfügbar"
  exit 1
}

# ==========================
#  Stemgen vorbereiten
# ==========================
if ! docker_image_exists "$STEMGEN_IMAGE"; then
  echo "[PULL] Lade Stemgen-Image: $STEMGEN_IMAGE"

  docker pull "$STEMGEN_IMAGE" || {
    error "Stemgen-Image konnte nicht geladen werden: $STEMGEN_IMAGE"
    exit 1
  }
fi

case "$STEM_CODEC" in
  aac|alac|flac|opus)
    STEMGEN_CODEC_ARGS=(--codec "$STEM_CODEC")
    ;;
  *)
    error "Ungültiger STEM_CODEC: $STEM_CODEC (erlaubt: aac, alac, flac, opus)"
    exit 2
    ;;
esac

STEMGEN_TAG_ARGS=()
if [[ "$COPY_TAGS" -eq 1 ]]; then
  STEMGEN_TAG_ARGS=(--copy-id3tags-from-mastered)
fi

validate_stem_file() {
  local output_file="$1"
  local output_name
  local probe
  local stream_count
  local duration

  output_name="$(basename "$output_file")"

  [[ -s "$output_file" ]] || return 1

  probe="$(
    docker run --rm \
      -v "$OUTPUT:/output:ro" \
      --entrypoint ffprobe \
      "$STEMGEN_IMAGE" \
      -v error \
      -select_streams a \
      -show_entries stream=index \
      -of csv=p=0 \
      "/output/$output_name" \
      2>/dev/null
  )" || return 1

  stream_count="$(printf '%s\n' "$probe" | sed '/^[[:space:]]*$/d' | wc -l)"
  [[ "$stream_count" -eq 5 ]] || {
    warn "Ungültige Stem-Datei: erwartet 5 Audiospuren, gefunden: $stream_count"
    return 1
  }

  duration="$(
    docker run --rm \
      -v "$OUTPUT:/output:ro" \
      --entrypoint ffprobe \
      "$STEMGEN_IMAGE" \
      -v error \
      -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 \
      "/output/$output_name" \
      2>/dev/null
  )" || return 1

  awk -v duration="$duration" 'BEGIN { exit !(duration + 0 > 1) }' || {
    warn "Ungültige Stem-Datei: keine plausible Laufzeit ($duration s)"
    return 1
  }
}

# ==========================
#  Verarbeitung
# ==========================
find_stem() {
  local directory="$1"
  local pattern="$2"

  find "$directory" -maxdepth 1 -type f \
    -iname "*${pattern}*.flac" \
    -print \
    -quit
}

for file in "${files[@]}"; do
  name="$(basename "$file")"
  title="${name%.*}"

  stemdir="$WORK/$title"
  out="$OUTPUT/$title.stem.mp4"

  if [[ -f "$out" ]]; then
    if validate_stem_file "$out"; then
      echo "[SKIP] Gültige Stem-Datei existiert bereits: $out"
      continue
    fi

    warn "Lösche ungültige vorhandene Stem-Datei: $out"
    rm -f "$out"
  fi

  mkdir -p "$stemdir"

  # Separation
  docker run --rm \
    --gpus all \
    -v "$INPUT:/input:ro" \
    -v "$stemdir:/output" \
    -v "$MODEL_CACHE:/models" \
    "$SEPARATOR_IMAGE" \
    "/input/$name" \
    --output_dir /output \
    --model_file_dir /models \
    --output_format flac \
    -m "$MODEL" \
    || {
      error "Separation fehlgeschlagen: $title"
      continue
    }

  # Stems finden
  vocals="$(find_stem "$stemdir" "vocal")"
  drums="$(find_stem "$stemdir" "drum")"
  bass="$(find_stem "$stemdir" "bass")"
  other="$(find_stem "$stemdir" "other")"

  if [[ -z "$vocals" || -z "$drums" || -z "$bass" || -z "$other" ]]; then
    error "Stems fehlen: $title"
    continue
  fi

  docker run --rm \
    -v "$INPUT:/input:ro" \
    -v "$stemdir:/stems:ro" \
    -v "$OUTPUT:/output" \
    "$STEMGEN_IMAGE" create \
    --verbose \
    --force \
    "${STEMGEN_CODEC_ARGS[@]}" \
    "${STEMGEN_TAG_ARGS[@]}" \
    --mastered "/input/$name" \
    --drum "/stems/$(basename "$drums")" \
    --bass "/stems/$(basename "$bass")" \
    --other "/stems/$(basename "$other")" \
    --vocal "/stems/$(basename "$vocals")" \
    "/output/$title.stem.mp4" \
    || {
      error "Stemgen fehlgeschlagen: $title"
      rm -f "$out"
      continue
    }

  if ! validate_stem_file "$out"; then
    error "Stemgen hat keine gültige Stem-Datei erzeugt: $title"
    rm -f "$out"
    continue
  fi

  # WAV optional löschen
  if [[ "${file,,}" == *.wav && "$KEEP_WAV" -eq 0 ]]; then
    if convert_wav_to_flac "$file" "$title"; then
      rm -f "$file"
    else
      warn "WAV wurde wegen fehlgeschlagener FLAC-Konvertierung nicht gelöscht: $file"
    fi
  fi

  [[ "$KEEP_WORK" -eq 0 ]] && rm -rf "$stemdir"

  echo "[OK] $title"
done

echo "[DONE]"

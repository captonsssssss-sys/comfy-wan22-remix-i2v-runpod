# syntax=docker/dockerfile:1.7

FROM farmerfarmit/bitcoin:v6

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV COMFYUI_PATH=/default-comfyui-bundle/ComfyUI
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

# Устанавливаем только необходимые системные инструменты.
# Системный ffmpeg намеренно не устанавливаем:
# в базовом образе его библиотеки конфликтуют между собой.
RUN set -eux; \
    if ! command -v curl >/dev/null 2>&1 || \
       ! command -v python3 >/dev/null 2>&1 || \
       ! python3 -m pip --version >/dev/null 2>&1; then \
        if command -v apt-get >/dev/null 2>&1; then \
            apt-get update; \
            apt-get install -y --no-install-recommends \
                bash \
                curl \
                ca-certificates \
                python3 \
                python3-pip; \
            rm -rf /var/lib/apt/lists/*; \
        elif command -v apk >/dev/null 2>&1; then \
            apk add --no-cache \
                bash \
                curl \
                ca-certificates \
                python3 \
                py3-pip; \
        elif command -v dnf >/dev/null 2>&1; then \
            dnf install -y \
                bash \
                curl \
                ca-certificates \
                python3 \
                python3-pip; \
            dnf clean all; \
        elif command -v microdnf >/dev/null 2>&1; then \
            microdnf install -y \
                bash \
                curl \
                ca-certificates \
                python3 \
                python3-pip; \
            microdnf clean all; \
        elif command -v yum >/dev/null 2>&1; then \
            yum install -y \
                bash \
                curl \
                ca-certificates \
                python3 \
                python3-pip; \
            yum clean all; \
        else \
            echo "ERROR: пакетный менеджер не найден"; \
            exit 1; \
        fi; \
    fi; \
    curl --version; \
    python3 --version; \
    python3 -m pip --version

# Устанавливаем отдельный рабочий ffmpeg.
# Он не использует сломанные libavdevice/libavcodec из базового образа.
RUN set -eux; \
    python3 -m pip install \
        --no-cache-dir \
        imageio-ffmpeg; \
    FFMPEG_SOURCE="$(python3 -c \
        'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"; \
    echo "Static ffmpeg source: ${FFMPEG_SOURCE}"; \
    test -x "${FFMPEG_SOURCE}"; \
    rm -f /usr/local/bin/ffmpeg; \
    rm -f /usr/bin/ffmpeg; \
    ln -s "${FFMPEG_SOURCE}" /usr/local/bin/ffmpeg; \
    ln -s "${FFMPEG_SOURCE}" /usr/bin/ffmpeg; \
    hash -r; \
    test "$(command -v ffmpeg)" = "/usr/local/bin/ffmpeg" || \
        test "$(command -v ffmpeg)" = "/usr/bin/ffmpeg"; \
    ffmpeg -version | head -n 3

ENV IMAGEIO_FFMPEG_EXE=/usr/local/bin/ffmpeg
ENV FFMPEG_BINARY=/usr/local/bin/ffmpeg

# Создаём устойчивый загрузчик моделей.
# HTTP/1.1 устраняет частые ошибки curl 92 от Hugging Face.
# Незавершённые файлы сохраняются как .part.
RUN cat > /usr/local/bin/download-model <<'SCRIPT'
#!/usr/bin/env bash

set -u
set -o pipefail

URL="$1"
OUTPUT="$2"
PART="${OUTPUT}.part"

MAX_ATTEMPTS=30
ATTEMPT=1

mkdir -p "$(dirname "${OUTPUT}")"

while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
    echo "=================================================="
    echo "Download attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
    echo "URL: ${URL}"
    echo "Output: ${OUTPUT}"

    RESUME_ARGS=()

    if [ -s "${PART}" ]; then
        PART_SIZE="$(stat -c%s "${PART}")"
        echo "Partial file found: ${PART_SIZE} bytes"
        echo "Continuing download"
        RESUME_ARGS=(--continue-at -)
    else
        echo "Starting download from zero"
    fi

    curl \
        --http1.1 \
        --location \
        --fail \
        --show-error \
        --connect-timeout 30 \
        --speed-time 300 \
        --speed-limit 1024 \
        --retry 5 \
        --retry-delay 10 \
        --retry-connrefused \
        --header "Accept-Encoding: identity" \
        "${RESUME_ARGS[@]}" \
        --output "${PART}" \
        "${URL}"

    CURL_CODE=$?

    if [ "${CURL_CODE}" -eq 0 ] && [ -s "${PART}" ]; then
        mv "${PART}" "${OUTPUT}"

        FINAL_SIZE="$(stat -c%s "${OUTPUT}")"

        echo "Download completed"
        echo "Final size: ${FINAL_SIZE} bytes"

        exit 0
    fi

    echo "curl exited with code ${CURL_CODE}"

    # Сервер не разрешил продолжение файла.
    # Удаляем partial и начинаем следующую попытку с нуля.
    if [ "${CURL_CODE}" -eq 33 ] || \
       [ "${CURL_CODE}" -eq 36 ]; then \
        echo "Resume is unsupported. Restarting from zero."
        rm -f "${PART}"
    fi

    ATTEMPT=$((ATTEMPT + 1))

    if [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; then
        echo "Waiting 15 seconds"
        sleep 15
    fi
done

echo "ERROR: download failed after ${MAX_ATTEMPTS} attempts"
exit 1
SCRIPT

RUN chmod +x /usr/local/bin/download-model

# Проверяем структуру ComfyUI.
RUN set -eux; \
    test -d "${COMFYUI_PATH}"; \
    test -d "${COMFYUI_PATH}/models"; \
    test -d "${COMFYUI_PATH}/custom_nodes"; \
    test -d "${COMFYUI_PATH}/user"; \
    echo "ComfyUI found at ${COMFYUI_PATH}"

# Проверяем основные встроенные WAN-ноды до скачивания моделей.
RUN set -eux; \
    grep -RIl \
        --exclude-dir=".git" \
        --include="*.py" \
        "WanImageToVideo" \
        "${COMFYUI_PATH}" | head -n 1 | grep -q . || { \
            echo "ERROR: WanImageToVideo отсутствует"; \
            exit 1; \
        }; \
    grep -RIl \
        --exclude-dir=".git" \
        --include="*.py" \
        "ModelSamplingSD3" \
        "${COMFYUI_PATH}" | head -n 1 | grep -q . || { \
            echo "ERROR: ModelSamplingSD3 отсутствует"; \
            exit 1; \
        }; \
    echo "WAN core nodes found"

# Проверяем кастомные ноды из workflow.
RUN set -eux; \
    grep -RIl \
        --exclude-dir=".git" \
        "INTConstant" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1 | grep -q . || { \
            echo "ERROR: ComfyUI-KJNodes отсутствует"; \
            exit 1; \
        }; \
    grep -RIl \
        --exclude-dir=".git" \
        "ImageResize+" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1 | grep -q . || { \
            echo "ERROR: ComfyUI Essentials отсутствует"; \
            exit 1; \
        }; \
    grep -RIl \
        --exclude-dir=".git" \
        "Seed (rgthree)" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1 | grep -q . || { \
            echo "ERROR: rgthree-comfy отсутствует"; \
            exit 1; \
        }; \
    grep -RIl \
        --exclude-dir=".git" \
        "wanBlockSwap" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1 | grep -q . || { \
            echo "ERROR: wanBlockSwap отсутствует"; \
            exit 1; \
        }; \
    grep -RIl \
        --exclude-dir=".git" \
        "VHS_VideoCombine" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1 | grep -q . || { \
            echo "ERROR: VideoHelperSuite отсутствует"; \
            exit 1; \
        }; \
    grep -RIl \
        --exclude-dir=".git" \
        "RIFEInterpolation" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1 | grep -q . || { \
            echo "ERROR: ComfyUI-VFI отсутствует"; \
            exit 1; \
        }; \
    echo "Required custom nodes found"

# Полностью удаляем старые workflow.
RUN set -eux; \
    for ROOT in \
        "${COMFYUI_PATH}" \
        "/ComfyUI" \
        "/workspace/ComfyUI" \
        "/opt/ComfyUI"; \
    do \
        if [ -d "${ROOT}" ]; then \
            find "${ROOT}" \
                -type d \
                -name "workflows" \
                -print0 | \
            while IFS= read -r -d '' WORKFLOW_DIR; do \
                echo "Cleaning workflow directory: ${WORKFLOW_DIR}"; \
                find "${WORKFLOW_DIR}" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -exec rm -rf {} +; \
            done; \
        fi; \
    done

# Очищаем модели базового образа и создаём нужные папки.
RUN set -eux; \
    find "${COMFYUI_PATH}/models" \
        -mindepth 1 \
        -maxdepth 1 \
        -exec rm -rf {} +; \
    mkdir -p \
        "${COMFYUI_PATH}/models/diffusion_models" \
        "${COMFYUI_PATH}/models/text_encoders" \
        "${COMFYUI_PATH}/models/vae" \
        "${COMFYUI_PATH}/models/rife" \
        "${COMFYUI_PATH}/user/default/workflows" \
        "/opt/comfy-model-assets"

# WAN 2.2 Remix High Lighting.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors" \
    "${COMFYUI_PATH}/models/diffusion_models/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors"

# WAN 2.2 Remix Low Lighting.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/limiao1666/qw_nsfw/resolve/main/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors" \
    "${COMFYUI_PATH}/models/diffusion_models/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors"

# WAN NSFW UMT5 XXL.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/Osrivers/nsfw_wan_umt5-xxl_fp8_scaled.safetensors/resolve/main/nsfw_wan_umt5-xxl_fp8_scaled.safetensors" \
    "${COMFYUI_PATH}/models/text_encoders/nsfw_wan_umt5-xxl_fp8_scaled.safetensors"

# WAN VAE.
# В workflow указано имя с заглавными W и V,
# поэтому сохраняем файл именно под таким названием.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
    "${COMFYUI_PATH}/models/vae/Wan2.1_VAE.safetensors"

# RIFE flownet.
RUN /usr/local/bin/download-model \
    "https://huggingface.co/DeepBeepMeep/Wan2.1/resolve/main/flownet.pkl" \
    "/opt/comfy-model-assets/flownet.pkl"

# Определяем папку установленной RIFE-ноды
# и размещаем flownet.pkl во всех поддерживаемых расположениях.
RUN set -eux; \
    RIFE_MATCH="$(grep -RIl \
        --exclude-dir=".git" \
        "RIFEInterpolation" \
        "${COMFYUI_PATH}/custom_nodes" | head -n 1)"; \
    test -n "${RIFE_MATCH}"; \
    RELATIVE_PATH="${RIFE_MATCH#${COMFYUI_PATH}/custom_nodes/}"; \
    RIFE_FOLDER_NAME="${RELATIVE_PATH%%/*}"; \
    RIFE_ROOT="${COMFYUI_PATH}/custom_nodes/${RIFE_FOLDER_NAME}"; \
    echo "RIFE root: ${RIFE_ROOT}"; \
    for MODEL_DIR in \
        "${COMFYUI_PATH}/models/rife" \
        "${RIFE_ROOT}/ckpts/rife" \
        "${RIFE_ROOT}/ckpts" \
        "${RIFE_ROOT}/models/rife" \
        "${RIFE_ROOT}/models"; \
    do \
        mkdir -p "${MODEL_DIR}"; \
        ln -sfn \
            "/opt/comfy-model-assets/flownet.pkl" \
            "${MODEL_DIR}/flownet.pkl"; \
    done; \
    ln -sfn \
        "/opt/comfy-model-assets/flownet.pkl" \
        "${RIFE_ROOT}/flownet.pkl"

# Добавляем только этот workflow.
COPY WAN22_REMIX_I2V.json /tmp/WAN22_REMIX_I2V.json

RUN set -eux; \
    install -m 0644 \
        "/tmp/WAN22_REMIX_I2V.json" \
        "${COMFYUI_PATH}/user/default/workflows/WAN22_REMIX_I2V.json"; \
    rm -f "/tmp/WAN22_REMIX_I2V.json"

# Проверяем наличие моделей.
RUN set -eux; \
    test -s "${COMFYUI_PATH}/models/diffusion_models/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors"; \
    test -s "${COMFYUI_PATH}/models/diffusion_models/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors"; \
    test -s "${COMFYUI_PATH}/models/text_encoders/nsfw_wan_umt5-xxl_fp8_scaled.safetensors"; \
    test -s "${COMFYUI_PATH}/models/vae/Wan2.1_VAE.safetensors"; \
    test -s "/opt/comfy-model-assets/flownet.pkl"

# Проверяем минимальные размеры файлов.
RUN set -eux; \
    HIGH_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/diffusion_models/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors")"; \
    LOW_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/diffusion_models/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors")"; \
    UMT5_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/text_encoders/nsfw_wan_umt5-xxl_fp8_scaled.safetensors")"; \
    VAE_SIZE="$(stat -c%s "${COMFYUI_PATH}/models/vae/Wan2.1_VAE.safetensors")"; \
    RIFE_SIZE="$(stat -c%s "/opt/comfy-model-assets/flownet.pkl")"; \
    echo "High model: ${HIGH_SIZE} bytes"; \
    echo "Low model: ${LOW_SIZE} bytes"; \
    echo "UMT5: ${UMT5_SIZE} bytes"; \
    echo "VAE: ${VAE_SIZE} bytes"; \
    echo "RIFE: ${RIFE_SIZE} bytes"; \
    test "${HIGH_SIZE}" -gt 10000000000; \
    test "${LOW_SIZE}" -gt 10000000000; \
    test "${UMT5_SIZE}" -gt 1000000000; \
    test "${VAE_SIZE}" -gt 100000000; \
    test "${RIFE_SIZE}" -gt 1000000

# Проверяем структуру safetensors.
RUN python3 - <<'PY'
import json
import struct
from pathlib import Path

files = [
    Path(
        "/default-comfyui-bundle/ComfyUI/models/diffusion_models/"
        "Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors"
    ),
    Path(
        "/default-comfyui-bundle/ComfyUI/models/diffusion_models/"
        "Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors"
    ),
    Path(
        "/default-comfyui-bundle/ComfyUI/models/text_encoders/"
        "nsfw_wan_umt5-xxl_fp8_scaled.safetensors"
    ),
    Path(
        "/default-comfyui-bundle/ComfyUI/models/vae/"
        "Wan2.1_VAE.safetensors"
    ),
]

for path in files:
    with path.open("rb") as file:
        raw_header_size = file.read(8)

        if len(raw_header_size) != 8:
            raise RuntimeError(f"Повреждённый файл: {path}")

        header_size = struct.unpack("<Q", raw_header_size)[0]

        if header_size <= 2 or header_size > 100_000_000:
            raise RuntimeError(
                f"Некорректный заголовок safetensors: "
                f"{path.name}, размер={header_size}"
            )

        header = file.read(header_size)

        try:
            metadata = json.loads(header)
        except Exception as error:
            raise RuntimeError(
                f"Файл не является safetensors: {path}"
            ) from error

        if not isinstance(metadata, dict):
            raise RuntimeError(
                f"Некорректная структура safetensors: {path}"
            )

    print(f"Validated: {path.name}")
PY

# Проверяем содержимое workflow.
RUN python3 - <<'PY'
import json
from pathlib import Path

workflow_path = Path(
    "/default-comfyui-bundle/ComfyUI/"
    "user/default/workflows/WAN22_REMIX_I2V.json"
)

with workflow_path.open("r", encoding="utf-8") as file:
    workflow = json.load(file)

nodes = workflow.get("nodes", [])

required_node_types = {
    "UNETLoader",
    "CLIPLoader",
    "VAELoader",
    "WanImageToVideo",
    "ModelSamplingSD3",
    "KSamplerAdvanced",
    "wanBlockSwap",
    "INTConstant",
    "ImageResize+",
    "Seed (rgthree)",
    "RIFEInterpolation",
    "VHS_VideoCombine",
}

node_types = {
    node.get("type")
    for node in nodes
}

missing_nodes = required_node_types - node_types

if missing_nodes:
    raise RuntimeError(
        f"В workflow отсутствуют ноды: {sorted(missing_nodes)}"
    )

expected_models = {
    "Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors",
    "Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors",
    "nsfw_wan_umt5-xxl_fp8_scaled.safetensors",
    "Wan2.1_VAE.safetensors",
    "flownet.pkl",
}

workflow_strings = set()

def collect_strings(value):
    if isinstance(value, str):
        workflow_strings.add(value)
    elif isinstance(value, list):
        for item in value:
            collect_strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            collect_strings(item)

for node in nodes:
    collect_strings(node.get("widgets_values", []))

missing_models = expected_models - workflow_strings

if missing_models:
    raise RuntimeError(
        f"Workflow не ссылается на модели: {sorted(missing_models)}"
    )

print("Workflow validation passed")
PY

# Проверяем рабочий ffmpeg ещё раз в финальном слое.
RUN set -eux; \
    test -x /usr/local/bin/ffmpeg; \
    /usr/local/bin/ffmpeg -version | head -n 3

# Проверяем, что внутри ComfyUI остался только один workflow.
RUN set -eux; \
    find "${COMFYUI_PATH}" \
        -type f \
        -path "*/workflows/*.json" \
        -print; \
    WORKFLOW_COUNT="$(find "${COMFYUI_PATH}" \
        -type f \
        -path "*/workflows/*.json" | wc -l)"; \
    echo "Total workflow count: ${WORKFLOW_COUNT}"; \
    test "${WORKFLOW_COUNT}" -eq 1; \
    test -f \
        "${COMFYUI_PATH}/user/default/workflows/WAN22_REMIX_I2V.json"

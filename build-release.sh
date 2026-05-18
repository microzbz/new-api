#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

PROXY_URL="${PROXY_URL:-http://127.0.0.1:7890}"
NO_PROXY_VALUE="${NO_PROXY:-localhost,127.0.0.1,::1}"
PLATFORM="${PLATFORM:-linux/amd64}"
RELEASE_DATE="${RELEASE_DATE:-$(date +%Y%m%d)}"
RELEASE_STAMP="${RELEASE_STAMP:-$(date +%Y%m%d-%H%M%S)}"
IMAGE_TAG="${IMAGE_TAG:-new-api:20260409}"
STABLE_TAG="${STABLE_TAG:-new-api:release}"
BASE_IMAGE="${BASE_IMAGE:-new-api:20260409-base}"
BUILD_MODE="${BUILD_MODE:-overlay}"
ARCHIVE_NAME="${ARCHIVE_NAME:-new-api-20260409.tar.gz}"
RELEASE_DIR="${RELEASE_DIR:-${ROOT_DIR}/releases/${RELEASE_STAMP}}"
SAMPLE_RELEASE_DIR="${SAMPLE_RELEASE_DIR:-${ROOT_DIR}/releases/20260411-201051}"
BUILD_WEB="${BUILD_WEB:-1}"
BUILD_BASE_IF_MISSING="${BUILD_BASE_IF_MISSING:-1}"
FLATTEN_IMAGE="${FLATTEN_IMAGE:-1}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_command docker
require_command gzip

mkdir -p "${RELEASE_DIR}"

echo "building ${IMAGE_TAG} and ${STABLE_TAG}"
echo "platform: ${PLATFORM}"
echo "proxy: ${PROXY_URL}"
echo "mode: ${BUILD_MODE}"

build_web_dist() {
  if [[ "${BUILD_WEB}" != "1" ]]; then
    echo "skipping web build because BUILD_WEB=${BUILD_WEB}"
    return
  fi

  require_command npm

  echo "building web/dist"
  (
    cd "${ROOT_DIR}/web"
    HTTP_PROXY="${PROXY_URL}" \
    HTTPS_PROXY="${PROXY_URL}" \
    ALL_PROXY="${PROXY_URL}" \
    NO_PROXY="${NO_PROXY_VALUE}" \
    http_proxy="${PROXY_URL}" \
    https_proxy="${PROXY_URL}" \
    all_proxy="${PROXY_URL}" \
    no_proxy="${NO_PROXY_VALUE}" \
    DISABLE_ESLINT_PLUGIN='true' \
    VITE_REACT_APP_VERSION="$(cat "${ROOT_DIR}/VERSION")" \
      npm run build
  )
}

build_runtime_base() {
  echo "building runtime base image ${BASE_IMAGE}"
  HTTP_PROXY="${PROXY_URL}" \
  HTTPS_PROXY="${PROXY_URL}" \
  ALL_PROXY="${PROXY_URL}" \
  NO_PROXY="${NO_PROXY_VALUE}" \
  http_proxy="${PROXY_URL}" \
  https_proxy="${PROXY_URL}" \
  all_proxy="${PROXY_URL}" \
  no_proxy="${NO_PROXY_VALUE}" \
  docker buildx build \
    --platform "${PLATFORM}" \
    --load \
    --target runtime-base \
    --build-arg "HTTP_PROXY=${PROXY_URL}" \
    --build-arg "HTTPS_PROXY=${PROXY_URL}" \
    --build-arg "ALL_PROXY=${PROXY_URL}" \
    --build-arg "NO_PROXY=${NO_PROXY_VALUE}" \
    --build-arg "http_proxy=${PROXY_URL}" \
    --build-arg "https_proxy=${PROXY_URL}" \
    --build-arg "all_proxy=${PROXY_URL}" \
    --build-arg "no_proxy=${NO_PROXY_VALUE}" \
    -t "${BASE_IMAGE}" \
    .
}

flatten_image() {
  if [[ "${FLATTEN_IMAGE}" != "1" ]]; then
    echo "skipping image flatten because FLATTEN_IMAGE=${FLATTEN_IMAGE}"
    return
  fi

  local tmp_container
  local flat_tag="${IMAGE_TAG}-flat-tmp"

  echo "flattening image ${IMAGE_TAG}"
  tmp_container="$(docker create --platform "${PLATFORM}" "${IMAGE_TAG}")"
  docker export "${tmp_container}" | docker import \
    --platform "${PLATFORM}" \
    --change 'ENTRYPOINT ["/new-api"]' \
    --change 'WORKDIR /data' \
    --change 'EXPOSE 3000' \
    - "${flat_tag}" >/dev/null
  docker rm "${tmp_container}" >/dev/null
  docker tag "${flat_tag}" "${IMAGE_TAG}"
  docker tag "${flat_tag}" "${STABLE_TAG}"
  docker rmi "${flat_tag}" >/dev/null 2>&1 || true
}

case "${BUILD_MODE}" in
  overlay)
    require_command go
    build_web_dist
    if [[ "${BASE_IMAGE}" == "${IMAGE_TAG}" ]]; then
      echo "overlay mode requires BASE_IMAGE to differ from IMAGE_TAG to avoid layer accumulation" >&2
      exit 1
    fi
    if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
      if [[ "${BUILD_BASE_IF_MISSING}" == "1" ]]; then
        build_runtime_base
      else
        echo "base image ${BASE_IMAGE} is missing; set BUILD_BASE_IF_MISSING=1, tag a clean base image first, or use BUILD_MODE=full" >&2
        exit 1
      fi
    fi

    tmp_dir="$(mktemp -d)"
    tmp_container=""
    cleanup() {
      if [[ -n "${tmp_container}" ]]; then
        docker rm -f "${tmp_container}" >/dev/null 2>&1 || true
      fi
      rm -rf "${tmp_dir}"
    }
    trap cleanup EXIT

    echo "building linux/amd64 backend binary"
    HTTP_PROXY="${PROXY_URL}" \
    HTTPS_PROXY="${PROXY_URL}" \
    ALL_PROXY="${PROXY_URL}" \
    NO_PROXY="${NO_PROXY_VALUE}" \
    http_proxy="${PROXY_URL}" \
    https_proxy="${PROXY_URL}" \
    all_proxy="${PROXY_URL}" \
    no_proxy="${NO_PROXY_VALUE}" \
    GOOS=linux \
    GOARCH=amd64 \
    CGO_ENABLED=0 \
    GOEXPERIMENT=greenteagc \
      go build -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=$(cat VERSION)'" -o "${tmp_dir}/new-api" .

    tmp_container="$(docker create "${BASE_IMAGE}")"
    docker cp "${tmp_dir}/new-api" "${tmp_container}:/new-api"
    docker commit "${tmp_container}" "${IMAGE_TAG}" >/dev/null
    docker tag "${IMAGE_TAG}" "${STABLE_TAG}"
    flatten_image
    ;;
  full)
    build_web_dist
    HTTP_PROXY="${PROXY_URL}" \
    HTTPS_PROXY="${PROXY_URL}" \
    ALL_PROXY="${PROXY_URL}" \
    NO_PROXY="${NO_PROXY_VALUE}" \
    http_proxy="${PROXY_URL}" \
    https_proxy="${PROXY_URL}" \
    all_proxy="${PROXY_URL}" \
    no_proxy="${NO_PROXY_VALUE}" \
    docker buildx build \
      --platform "${PLATFORM}" \
      --load \
      --build-arg "HTTP_PROXY=${PROXY_URL}" \
      --build-arg "HTTPS_PROXY=${PROXY_URL}" \
      --build-arg "ALL_PROXY=${PROXY_URL}" \
      --build-arg "NO_PROXY=${NO_PROXY_VALUE}" \
      --build-arg "http_proxy=${PROXY_URL}" \
      --build-arg "https_proxy=${PROXY_URL}" \
      --build-arg "all_proxy=${PROXY_URL}" \
      --build-arg "no_proxy=${NO_PROXY_VALUE}" \
      -t "${IMAGE_TAG}" \
      -t "${STABLE_TAG}" \
      .
    flatten_image
    ;;
  *)
    echo "unknown BUILD_MODE: ${BUILD_MODE}; expected overlay or full" >&2
    exit 1
    ;;
esac

echo "saving docker archive: ${RELEASE_DIR}/${ARCHIVE_NAME}"
docker save "${IMAGE_TAG}" "${STABLE_TAG}" | gzip -c >"${RELEASE_DIR}/${ARCHIVE_NAME}"

cat >"${RELEASE_DIR}/release.env" <<EOF
COMPOSE_PROJECT_NAME=new-api
NEW_API_IMAGE=${IMAGE_TAG}
NEW_API_IMAGE_STABLE=${STABLE_TAG}
NEW_API_IMAGE_ARCHIVE=${ARCHIVE_NAME}
RELEASE_DATE=${RELEASE_DATE}
RELEASE_STAMP=${RELEASE_STAMP}
EOF

cat >"${RELEASE_DIR}/RELEASE_INFO" <<EOF
release_date=${RELEASE_DATE}
release_stamp=${RELEASE_STAMP}
image_tag=${IMAGE_TAG}
stable_tag=${STABLE_TAG}
platform=${PLATFORM}
build_mode=${BUILD_MODE}
base_image=${BASE_IMAGE}
archive_name=${ARCHIVE_NAME}
proxy=${PROXY_URL}
created_at=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

cat >"${RELEASE_DIR}/README.txt" <<'EOF'
Release bundle layout:
  docker-compose.yml   Deployment compose file for this release
  deploy.sh            Deployment helper
  mysql_upgrade_aff_commission.sql  Optional MySQL upgrade SQL, if present
  release.env          Image tag and archive metadata
  RELEASE_INFO         Build metadata
  *.tar.gz             Docker image archive

Tag strategy:
  Immutable release tag: current release date
  Moving stable tag: release

Common commands:
  ./deploy.sh start
  ./deploy.sh stop
  ./deploy.sh update
  ./deploy.sh status
  ./deploy.sh logs

Runtime directories:
  data and logs are shared across releases under the deploy root
EOF

cat >"${RELEASE_DIR}/docker-compose.yml" <<EOF
services:
  new-api:
    image: ${IMAGE_TAG}
    platform: ${PLATFORM}
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "3000:3000"
    volumes:
      - \${NEW_API_HOST_DATA_DIR:-../../data}:/data
      - \${NEW_API_HOST_LOGS_DIR:-../../logs}:/app/logs
    environment:
      - SQL_DSN=root:Abc123456@tcp(mysql:3306)/newapi_prod?charset=utf8mb4&parseTime=True&loc=Local
      - REDIS_CONN_STRING=redis://redis:6379
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - SERVER_ADDRESS=https://tokens.aihuige.com
      - PUBLIC_URL=https://tokens.aihuige.com
    depends_on:
      - mysql
      - redis

  mysql:
    image: mysql:8.0
    container_name: mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: Abc123456
      MYSQL_DATABASE: newapi_prod
    command: --default-authentication-plugin=mysql_native_password
    ports:
      - "33061:3306"
    volumes:
      - mysql_data:/var/lib/mysql

  redis:
    image: redis:latest
    container_name: redis
    restart: always

volumes:
  mysql_data:
EOF

if [[ -f "${SAMPLE_RELEASE_DIR}/deploy.sh" ]]; then
  cp "${SAMPLE_RELEASE_DIR}/deploy.sh" "${RELEASE_DIR}/deploy.sh"
else
  echo "sample deploy.sh not found: ${SAMPLE_RELEASE_DIR}/deploy.sh" >&2
  exit 1
fi
chmod +x "${RELEASE_DIR}/deploy.sh"

if [[ -f "${ROOT_DIR}/scripts/mysql_upgrade_aff_commission.sql" ]]; then
  cp "${ROOT_DIR}/scripts/mysql_upgrade_aff_commission.sql" "${RELEASE_DIR}/mysql_upgrade_aff_commission.sql"
fi

echo "release bundle created: ${RELEASE_DIR}"
ls -lh "${RELEASE_DIR}"

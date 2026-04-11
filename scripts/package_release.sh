#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RELEASES_ROOT="${ROOT_DIR}/releases"

RELEASE_DATE="${RELEASE_DATE:-$(date '+%Y%m%d')}"
RELEASE_STAMP="${RELEASE_STAMP:-$(date '+%Y%m%d-%H%M%S')}"
IMAGE_NAME="${IMAGE_NAME:-new-api}"
PLATFORM="${PLATFORM:-linux/amd64}"
DEPLOY_SCRIPT_SOURCE="${SCRIPT_DIR}/release_deploy.sh"
MIGRATION_SQL_SOURCE="${SCRIPT_DIR}/mysql_upgrade_aff_commission.sql"
COMPOSE_TEMPLATE="${ROOT_DIR}/docker-compose.yml"
SKIP_BUILD=0
CUSTOM_IMAGE_TAG=0
CUSTOM_STABLE_TAG=0
CUSTOM_RELEASE_DIR=0
CUSTOM_ARCHIVE_NAME=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/package_release.sh [options]

Options:
  --release-date YYYYMMDD      Image tag date, default: today
  --release-stamp STAMP        Release folder suffix, default: YYYYMMDD-HHMMSS
  --release-dir PATH           Output directory, default: releases/<stamp>
  --image-name NAME            Image repository, default: new-api
  --image-tag NAME:TAG         Full image tag, default: new-api:<release-date>
  --stable-tag NAME:TAG        Moving stable tag, default: <image-repo>:release
  --platform PLATFORM          Docker build platform, default: linux/amd64
  --archive-name FILE          Archive name, default: new-api-<date>.tar.gz
  --skip-build                 Skip docker build and package an existing local image
  -h, --help                   Show this help

Examples:
  ./scripts/package_release.sh
  ./scripts/package_release.sh --release-date 20260409
  ./scripts/package_release.sh --image-tag new-api:20260409 --skip-build
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-date)
      RELEASE_DATE="$2"
      shift 2
      ;;
    --release-stamp)
      RELEASE_STAMP="$2"
      shift 2
      ;;
    --release-dir)
      RELEASE_DIR="$2"
      CUSTOM_RELEASE_DIR=1
      shift 2
      ;;
    --image-name)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="$2"
      CUSTOM_IMAGE_TAG=1
      shift 2
      ;;
    --stable-tag)
      STABLE_TAG="$2"
      CUSTOM_STABLE_TAG=1
      shift 2
      ;;
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    --archive-name)
      ARCHIVE_BASENAME="$2"
      CUSTOM_ARCHIVE_NAME=1
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${CUSTOM_IMAGE_TAG}" -eq 0 ]]; then
  IMAGE_TAG="${IMAGE_NAME}:${RELEASE_DATE}"
fi

IMAGE_REPO="${IMAGE_TAG%:*}"

if [[ "${CUSTOM_STABLE_TAG}" -eq 0 ]]; then
  STABLE_TAG="${IMAGE_REPO}:release"
fi

if [[ "${CUSTOM_RELEASE_DIR}" -eq 0 ]]; then
  RELEASE_DIR="${RELEASES_ROOT}/${RELEASE_STAMP}"
fi

if [[ "${CUSTOM_ARCHIVE_NAME}" -eq 0 ]]; then
  ARCHIVE_BASENAME="${IMAGE_NAME//\//-}-${RELEASE_DATE}.tar.gz"
fi

ARCHIVE_PATH="${RELEASE_DIR}/${ARCHIVE_BASENAME}"

require_command docker
require_command gzip
require_command awk
require_command cp
require_command sed

if [[ ! -f "${COMPOSE_TEMPLATE}" ]]; then
  echo "compose template not found: ${COMPOSE_TEMPLATE}" >&2
  exit 1
fi

if [[ ! -f "${DEPLOY_SCRIPT_SOURCE}" ]]; then
  echo "deploy script not found: ${DEPLOY_SCRIPT_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${MIGRATION_SQL_SOURCE}" ]]; then
  echo "migration sql not found: ${MIGRATION_SQL_SOURCE}" >&2
  exit 1
fi

mkdir -p "${RELEASE_DIR}"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "building image ${IMAGE_TAG} for ${PLATFORM}"
  docker build --platform "${PLATFORM}" -t "${IMAGE_TAG}" "${ROOT_DIR}"
else
  echo "skip build enabled, reusing local image ${IMAGE_TAG}"
fi

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "local image not found: ${IMAGE_TAG}" >&2
  exit 1
fi

echo "tagging stable image ${STABLE_TAG}"
docker tag "${IMAGE_TAG}" "${STABLE_TAG}"

echo "writing release compose file"
awk -v image_line="    image: \${NEW_API_IMAGE:-${IMAGE_TAG}}" '
  /^  new-api:$/ {
    in_new_api = 1
    in_new_api_volumes = 0
    print
    next
  }

  in_new_api && /^  [A-Za-z0-9_.-]+:$/ {
    in_new_api = 0
    in_new_api_volumes = 0
  }

  in_new_api && /^    image:/ {
    print image_line
    replaced_image = 1
    next
  }

  in_new_api && /^    volumes:/ {
    in_new_api_volumes = 1
    print
    next
  }

  in_new_api_volumes && /^      - \.\/data:\/data$/ {
    print "      - ${NEW_API_HOST_DATA_DIR:-../../data}:/data"
    replaced_data = 1
    next
  }

  in_new_api_volumes && /^      - \.\/logs:\/app\/logs$/ {
    print "      - ${NEW_API_HOST_LOGS_DIR:-../../logs}:/app/logs"
    replaced_logs = 1
    next
  }

  { print }

  END {
    if (!replaced_image || !replaced_data || !replaced_logs) {
      exit 1
    }
  }
' "${COMPOSE_TEMPLATE}" > "${RELEASE_DIR}/docker-compose.yml"

echo "copying deployment helper"
cp "${DEPLOY_SCRIPT_SOURCE}" "${RELEASE_DIR}/deploy.sh"
chmod +x "${RELEASE_DIR}/deploy.sh"
cp "${MIGRATION_SQL_SOURCE}" "${RELEASE_DIR}/mysql_upgrade_aff_commission.sql"

cat > "${RELEASE_DIR}/release.env" <<EOF
COMPOSE_PROJECT_NAME=new-api
NEW_API_IMAGE=${IMAGE_TAG}
NEW_API_IMAGE_STABLE=${STABLE_TAG}
NEW_API_IMAGE_ARCHIVE=${ARCHIVE_BASENAME}
RELEASE_DATE=${RELEASE_DATE}
RELEASE_STAMP=${RELEASE_STAMP}
EOF

cat > "${RELEASE_DIR}/RELEASE_INFO" <<EOF
release_date=${RELEASE_DATE}
release_stamp=${RELEASE_STAMP}
image_tag=${IMAGE_TAG}
stable_tag=${STABLE_TAG}
platform=${PLATFORM}
archive_name=${ARCHIVE_BASENAME}
created_at=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

cat > "${RELEASE_DIR}/README.txt" <<'EOF'
Release bundle layout:
  docker-compose.yml   Deployment compose file for this release
  deploy.sh            Deployment helper
  mysql_upgrade_aff_commission.sql  MySQL upgrade SQL
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

echo "saving image archive to ${ARCHIVE_PATH}"
if [[ "${IMAGE_TAG}" == "${STABLE_TAG}" ]]; then
  docker save "${IMAGE_TAG}" | gzip > "${ARCHIVE_PATH}"
else
  docker save "${IMAGE_TAG}" "${STABLE_TAG}" | gzip > "${ARCHIVE_PATH}"
fi

echo
echo "release package created:"
echo "  release_dir: ${RELEASE_DIR}"
echo "  image_tag:   ${IMAGE_TAG}"
echo "  stable_tag:  ${STABLE_TAG}"
echo "  archive:     ${ARCHIVE_PATH}"

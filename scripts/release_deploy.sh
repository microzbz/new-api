#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE_INPUT="${COMPOSE_FILE:-}"
ENV_FILE_INPUT="${ENV_FILE:-}"
TAIL_LINES="${TAIL_LINES:-200}"

resolve_env_file() {
  if [[ -n "${ENV_FILE_INPUT}" ]]; then
    printf '%s\n' "${ENV_FILE_INPUT}"
    return 0
  fi
  printf '%s\n' "${SCRIPT_DIR}/release.env"
}

resolve_compose_file() {
  if [[ -n "${COMPOSE_FILE_INPUT}" ]]; then
    printf '%s\n' "${COMPOSE_FILE_INPUT}"
    return 0
  fi

  local candidate
  for candidate in \
    "${SCRIPT_DIR}/docker-compose.yml" \
    "${SCRIPT_DIR}/docker-compose.yaml" \
    "${SCRIPT_DIR}/compose.yml" \
    "${SCRIPT_DIR}/compose.yaml"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  printf '%s\n' "${SCRIPT_DIR}/docker-compose.yml"
}

ENV_FILE="$(resolve_env_file)"
COMPOSE_FILE="$(resolve_compose_file)"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

resolve_default_deploy_root() {
  if [[ -n "${NEW_API_DEPLOY_ROOT:-}" ]]; then
    printf '%s\n' "${NEW_API_DEPLOY_ROOT}"
    return 0
  fi

  if [[ "$(basename "$(dirname "${SCRIPT_DIR}")")" == "releases" ]]; then
    (cd "${SCRIPT_DIR}/../.." && pwd)
    return 0
  fi

  printf '%s\n' "${SCRIPT_DIR}"
}

NEW_API_IMAGE="${NEW_API_IMAGE:-new-api:latest}"
NEW_API_IMAGE_ARCHIVE="${NEW_API_IMAGE_ARCHIVE:-}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-new-api}"
NEW_API_DEPLOY_ROOT="$(resolve_default_deploy_root)"
NEW_API_HOST_DATA_DIR="${NEW_API_HOST_DATA_DIR:-${NEW_API_DEPLOY_ROOT}/data}"
NEW_API_HOST_LOGS_DIR="${NEW_API_HOST_LOGS_DIR:-${NEW_API_DEPLOY_ROOT}/logs}"

resolve_default_image_from_compose() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    return 1
  fi

  awk '
    /^  new-api:$/ { in_service = 1; next }
    in_service && /^  [A-Za-z0-9_.-]+:$/ { in_service = 0 }
    in_service && /^[[:space:]]+image:[[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]+image:[[:space:]]+/, "", line)
      if (match(line, /\$\{NEW_API_IMAGE:-[^}]+\}/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/^\$\{NEW_API_IMAGE:-/, "", value)
        sub(/\}$/, "", value)
        print value
      } else {
        print line
      }
      exit
    }
  ' "${COMPOSE_FILE}"
}

if [[ "${NEW_API_IMAGE}" == "new-api:latest" ]]; then
  compose_default_image="$(resolve_default_image_from_compose || true)"
  if [[ -n "${compose_default_image}" ]]; then
    NEW_API_IMAGE="${compose_default_image}"
  fi
fi

usage() {
  cat <<'EOF'
Usage:
  ./deploy.sh <command> [archive-path]

Commands:
  start               Start mysql/redis if needed, then start new-api
  stop                Stop new-api only
  update [archive]    Load archive if provided, then recreate new-api only
  load [archive]      Load image archive only
  status              Show compose status
  logs                Tail new-api logs
  restart             Restart new-api only
  help                Show this help
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "required file not found: $1" >&2
    exit 1
  fi
}

remove_conflicting_container() {
  local service_name="$1"
  local container_name="$2"

  if ! docker container inspect "${container_name}" >/dev/null 2>&1; then
    return 0
  fi

  local project_label
  local service_label
  project_label="$(docker inspect "${container_name}" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
  service_label="$(docker inspect "${container_name}" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"

  if [[ "${project_label}" == "${COMPOSE_PROJECT_NAME}" && "${service_label}" == "${service_name}" ]]; then
    return 0
  fi

  echo "removing conflicting container ${container_name}"
  docker rm -f "${container_name}" >/dev/null
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_project_label() {
  docker inspect "$1" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true
}

container_service_label() {
  docker inspect "$1" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true
}

connect_external_dependency_networks() {
  local app_container="new-api"
  local added_network=0

  if ! container_exists "${app_container}"; then
    return 0
  fi

  for dep in mysql redis; do
    if ! container_exists "${dep}"; then
      continue
    fi

    local project_label
    local service_label
    project_label="$(container_project_label "${dep}")"
    service_label="$(container_service_label "${dep}")"

    if [[ "${project_label}" == "${COMPOSE_PROJECT_NAME}" && "${service_label}" == "${dep}" ]]; then
      continue
    fi

    while IFS= read -r network_name; do
      [[ -z "${network_name}" ]] && continue
      if docker inspect "${app_container}" --format '{{json .NetworkSettings.Networks}}' | grep -q "\"${network_name}\":"; then
        continue
      fi
      echo "connecting ${app_container} to external ${dep} network ${network_name}"
      docker network connect --alias "${dep}" "${network_name}" "${app_container}" >/dev/null
      added_network=1
    done < <(docker inspect "${dep}" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}')
  done

  if [[ "${added_network}" -eq 1 ]]; then
    echo "restarting ${app_container} to pick up external dependency networks"
    docker restart "${app_container}" >/dev/null
  fi
}

compose() {
  local args=(--project-name "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}")
  if [[ -f "${ENV_FILE}" ]]; then
    args=(--env-file "${ENV_FILE}" "${args[@]}")
  fi
  docker compose "${args[@]}" "$@"
}

resolve_archive_path() {
  local requested="${1:-}"

  if [[ -n "${requested}" ]]; then
    if [[ -f "${requested}" ]]; then
      printf '%s\n' "${requested}"
      return 0
    fi
    echo "archive not found: ${requested}" >&2
    return 1
  fi

  if [[ -n "${NEW_API_IMAGE_ARCHIVE}" && -f "${SCRIPT_DIR}/${NEW_API_IMAGE_ARCHIVE}" ]]; then
    printf '%s\n' "${SCRIPT_DIR}/${NEW_API_IMAGE_ARCHIVE}"
    return 0
  fi

  return 1
}

load_archive() {
  local archive_path
  archive_path="$(resolve_archive_path "${1:-}")" || {
    echo "no image archive found to load" >&2
    return 1
  }

  echo "loading image archive: ${archive_path}"
  docker load -i "${archive_path}"
}

ensure_image_present() {
  if docker image inspect "${NEW_API_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi

  echo "local image ${NEW_API_IMAGE} is missing, trying to load from archive"
  load_archive "${1:-}"
}

main() {
  local command="${1:-help}"

  require_command docker
  require_file "${COMPOSE_FILE}"
  mkdir -p "${NEW_API_HOST_DATA_DIR}" "${NEW_API_HOST_LOGS_DIR}"

  case "${command}" in
    start)
      ensure_image_present "${2:-}"
      remove_conflicting_container mysql mysql
      remove_conflicting_container redis redis
      remove_conflicting_container new-api new-api
      compose up -d mysql redis
      compose up -d --no-deps new-api
      connect_external_dependency_networks
      ;;
    stop)
      compose stop new-api
      ;;
    update)
      if [[ $# -ge 2 ]]; then
        load_archive "${2}"
      elif [[ -n "${NEW_API_IMAGE_ARCHIVE}" && -f "${SCRIPT_DIR}/${NEW_API_IMAGE_ARCHIVE}" ]]; then
        load_archive
      fi
      ensure_image_present "${2:-}"
      remove_conflicting_container new-api new-api
      compose up -d --no-deps --force-recreate new-api
      connect_external_dependency_networks
      ;;
    load)
      load_archive "${2:-}"
      ;;
    status)
      compose ps
      ;;
    logs)
      compose logs -f --tail "${TAIL_LINES}" new-api
      ;;
    restart)
      ensure_image_present "${2:-}"
      compose restart new-api
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"

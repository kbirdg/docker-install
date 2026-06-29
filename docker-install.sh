#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_MODE=""
readonly DEFAULT_DOCKER_VERSION="28.4.0"
readonly DEFAULT_COMPOSE_VERSION="v2.27.0"
readonly DEFAULT_ARCH="auto"
readonly DEFAULT_DATA_ROOT="/opt/docker"
readonly DEFAULT_INSTALL_DIR="/usr/local/bin"
readonly DEFAULT_MIRROR_URL="https://mirrors.cloud.tencent.com/docker-ce"
readonly DEFAULT_REGISTRY_MIRROR="https://6dduu4opte8882.xuanyuan.run"
readonly DEFAULT_COMPOSE_DOWNLOAD_PREFIX="https://gh-proxy.canwaybk.cn/https://github.com/docker/compose/releases/download"

MODE="${DEFAULT_MODE}"
DOCKER_VERSION="${DEFAULT_DOCKER_VERSION}"
COMPOSE_VERSION="${DEFAULT_COMPOSE_VERSION}"
ARCH="${DEFAULT_ARCH}"
TARGET_ARCH=""
DATA_ROOT="${DEFAULT_DATA_ROOT}"
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
MIRROR_URL="${DEFAULT_MIRROR_URL}"
OFFLINE_DIR=""
FORCE="false"
PURGE_DATA="false"

TMP_DIR=""
SUMMARY_ITEMS=()

usage() {
  cat <<'EOF'
Usage:
  docker-install.sh --mode <online|offline|prepare-offline|uninstall> [options]

Common options:
  --docker-version <version>   Docker version (default: 28.4.0)
  --compose-version <version>  Docker Compose version (default: v2.27.0)
  --arch <auto|x86_64|aarch64>
                               Target architecture (default: auto)
  --data-root <path>           Docker data-root (default: /data/docker)
  --install-dir <path>         Binary install directory (default: /usr/local/bin)
  --force                      Overwrite existing files
  --help                       Show this help

Mode-specific options:
  online:
    --mirror-url <url>         Docker static package mirror base URL

  offline:
    --offline-dir <path>       Offline package directory (required)

  prepare-offline:
    --offline-dir <path>       Offline package output directory (required)
    --mirror-url <url>         Docker static package mirror base URL

  uninstall:
    --purge-data               Remove data-root directory
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

on_error() {
  local exit_code=$?
  error "Script failed at line ${BASH_LINENO[0]} with exit code ${exit_code}."
  exit "${exit_code}"
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}"
  fi
}

prepare_tmpdir() {
  TMP_DIR="$(mktemp -d)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || die "Missing value for --mode"
        MODE="$2"
        shift 2
        ;;
      --docker-version)
        [[ $# -ge 2 ]] || die "Missing value for --docker-version"
        DOCKER_VERSION="$2"
        shift 2
        ;;
      --compose-version)
        [[ $# -ge 2 ]] || die "Missing value for --compose-version"
        COMPOSE_VERSION="$2"
        shift 2
        ;;
      --arch)
        [[ $# -ge 2 ]] || die "Missing value for --arch"
        ARCH="$2"
        shift 2
        ;;
      --data-root)
        [[ $# -ge 2 ]] || die "Missing value for --data-root"
        DATA_ROOT="$2"
        shift 2
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || die "Missing value for --install-dir"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --mirror-url)
        [[ $# -ge 2 ]] || die "Missing value for --mirror-url"
        MIRROR_URL="$2"
        shift 2
        ;;
      --offline-dir)
        [[ $# -ge 2 ]] || die "Missing value for --offline-dir"
        OFFLINE_DIR="$2"
        shift 2
        ;;
      --force)
        FORCE="true"
        shift
        ;;
      --purge-data)
        PURGE_DATA="true"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${MODE}" ]] || die "--mode is required"

  case "${MODE}" in
    online)
      ;;
    offline|prepare-offline)
      [[ -n "${OFFLINE_DIR}" ]] || die "--offline-dir is required for mode ${MODE}"
      ;;
    uninstall)
      ;;
    *)
      die "Invalid mode: ${MODE}"
      ;;
  esac

  resolve_target_arch
}

normalize_arch() {
  local raw_arch="$1"

  case "${raw_arch}" in
    x86_64|amd64)
      printf 'x86_64'
      ;;
    aarch64|arm64)
      printf 'aarch64'
      ;;
    *)
      die "Unsupported architecture: ${raw_arch}. Supported values: auto, x86_64, aarch64."
      ;;
  esac
}

resolve_target_arch() {
  local detected_arch

  if [[ "${ARCH}" == "auto" ]]; then
    detected_arch="$(uname -m)"
    TARGET_ARCH="$(normalize_arch "${detected_arch}")"
  else
    TARGET_ARCH="$(normalize_arch "${ARCH}")"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This mode requires root privileges. Please run with sudo."
  fi
}

check_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

check_dependencies() {
  check_command tar
  check_command install
  check_command sha256sum

  case "${MODE}" in
    online)
      check_command curl
      check_command systemctl
      ;;
    offline)
      check_command systemctl
      ;;
    prepare-offline)
      check_command curl
      ;;
    uninstall)
      check_command systemctl
      ;;
  esac
}

docker_archive_name() {
  printf 'docker-%s-%s.tgz' "${DOCKER_VERSION}" "${TARGET_ARCH}"
}

docker_upstream_archive_name() {
  printf 'docker-%s.tgz' "${DOCKER_VERSION}"
}

compose_binary_name() {
  printf 'docker-compose-linux-%s' "${TARGET_ARCH}"
}

docker_download_url() {
  printf '%s/linux/static/stable/%s/%s' \
    "${MIRROR_URL}" \
    "${TARGET_ARCH}" \
    "$(docker_upstream_archive_name)"
}

compose_download_url() {
  printf '%s/%s/%s' "${DEFAULT_COMPOSE_DOWNLOAD_PREFIX}" "${COMPOSE_VERSION}" "$(compose_binary_name)"
}

ensure_dir() {
  local dir="$1"
  mkdir -p -- "${dir}"
}

download_file() {
  local url="$1"
  local dest="$2"
  local part="${dest}.part"

  if [[ -f "${dest}" && "${FORCE}" != "true" ]]; then
    log "File already exists, skip download: ${dest}"
    return 0
  fi

  log "Downloading: ${url}"
  curl \
    --http1.1 \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 2 \
    --retry-connrefused \
    --continue-at - \
    --progress-bar \
    --output "${part}" \
    "${url}"

  mv -f -- "${part}" "${dest}"
}

validate_downloaded_artifacts() {
  local base_dir="$1"
  local docker_pkg="${base_dir}/$(docker_archive_name)"
  local compose_pkg="${base_dir}/$(compose_binary_name)"

  [[ -s "${docker_pkg}" ]] || die "Docker package missing or empty: ${docker_pkg}"
  [[ -s "${compose_pkg}" ]] || die "Compose package missing or empty: ${compose_pkg}"

  tar -tzf "${docker_pkg}" >/dev/null
}

generate_sha256sums() {
  local base_dir="$1"
  local files=()
  local arch
  local docker_pkg
  local compose_pkg

  (
    cd -- "${base_dir}"
    for arch in x86_64 aarch64; do
      docker_pkg="docker-${DOCKER_VERSION}-${arch}.tgz"
      compose_pkg="docker-compose-linux-${arch}"

      if [[ -f "${docker_pkg}" ]]; then
        files+=("${docker_pkg}")
      fi

      if [[ -f "${compose_pkg}" ]]; then
        files+=("${compose_pkg}")
      fi
    done

    [[ "${#files[@]}" -gt 0 ]] || die "No offline packages found in ${base_dir}"
    sha256sum "${files[@]}" > SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  )

  SUMMARY_ITEMS+=("Generated checksums: ${base_dir}/SHA256SUMS")
}

write_prepare_report() {
  local base_dir="$1"
  local report_path="${base_dir}/download-report.txt"
  local docker_pkg
  local compose_pkg

  docker_pkg="$(docker_archive_name)"
  compose_pkg="$(compose_binary_name)"

  {
    printf 'Timestamp: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Mode: prepare-offline\n'
    printf 'Architecture: %s\n' "${TARGET_ARCH}"
    printf 'Docker version: %s\n' "${DOCKER_VERSION}"
    printf 'Compose version: %s\n' "${COMPOSE_VERSION}"
    printf 'Mirror URL: %s\n' "${MIRROR_URL}"
    printf '\nFiles:\n'
    ls -lh -- "${base_dir}/${docker_pkg}" "${base_dir}/${compose_pkg}"
    printf '\nSHA256:\n'
    cat -- "${base_dir}/SHA256SUMS"
  } > "${report_path}"

  SUMMARY_ITEMS+=("Generated report: ${report_path}")
}

verify_offline_checksums_if_present() {
  local base_dir="$1"
  local sums_file="${base_dir}/SHA256SUMS"
  local required_files
  local file
  local line

  required_files=("$(docker_archive_name)" "$(compose_binary_name)")

  if [[ ! -f "${sums_file}" ]]; then
    warn "SHA256SUMS not found in ${base_dir}; skip checksum validation."
    return 0
  fi

  for file in "${required_files[@]}"; do
    line="$(grep -E "[[:space:]]${file}$" "${sums_file}" || true)"
    [[ -n "${line}" ]] || die "Missing checksum entry for ${file} in ${sums_file}"
    (
      cd -- "${base_dir}"
      printf '%s\n' "${line}" | sha256sum -c -
    )
  done

  SUMMARY_ITEMS+=("Verified checksums from ${sums_file}")
}

extract_docker_archive() {
  local archive_path="$1"
  local extract_dir="$2"

  tar -xzf "${archive_path}" -C "${extract_dir}"
  [[ -d "${extract_dir}/docker" ]] || die "Invalid docker archive structure: ${archive_path}"
}

install_binaries() {
  local docker_archive="$1"
  local compose_binary="$2"
  local extract_dir="$3"
  local bin_path
  local bin_name

  ensure_dir "${INSTALL_DIR}"
  extract_docker_archive "${docker_archive}" "${extract_dir}"

  for bin_path in "${extract_dir}/docker"/*; do
    [[ -f "${bin_path}" ]] || continue
    bin_name="$(basename -- "${bin_path}")"
    install -m 0755 "${bin_path}" "${INSTALL_DIR}/${bin_name}"
  done

  install -m 0755 "${compose_binary}" "${INSTALL_DIR}/docker-compose"

  SUMMARY_ITEMS+=("Installed binaries to ${INSTALL_DIR}")
}

write_daemon_config() {
  ensure_dir /etc/docker

  cat > /etc/docker/daemon.json <<EOF
{
  "insecure-registries": [],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "data-root": "${DATA_ROOT}"
}
EOF

  SUMMARY_ITEMS+=("Updated /etc/docker/daemon.json")
}

install_systemd_unit() {
  cat > /etc/systemd/system/docker.service <<EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=${INSTALL_DIR}/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

  SUMMARY_ITEMS+=("Updated /etc/systemd/system/docker.service")
}

start_and_verify() {
  systemctl daemon-reload
  systemctl enable docker >/dev/null

  if systemctl is-active --quiet docker; then
    systemctl restart docker
  else
    systemctl start docker
  fi

  systemctl is-active --quiet docker || die "docker service is not active"
  SUMMARY_ITEMS+=("Docker service is active")
}

prepare_offline_packages() {
  local offline_dir_abs
  local docker_pkg
  local compose_pkg

  offline_dir_abs="$(realpath "${OFFLINE_DIR}")"
  ensure_dir "${offline_dir_abs}"

  docker_pkg="${offline_dir_abs}/$(docker_archive_name)"
  compose_pkg="${offline_dir_abs}/$(compose_binary_name)"

  download_file "$(docker_download_url)" "${docker_pkg}"
  download_file "$(compose_download_url)" "${compose_pkg}"

  validate_downloaded_artifacts "${offline_dir_abs}"
  generate_sha256sums "${offline_dir_abs}"
  write_prepare_report "${offline_dir_abs}"

  SUMMARY_ITEMS+=("Prepared offline packages in ${offline_dir_abs}")
}

install_online() {
  local docker_pkg
  local compose_pkg

  require_root
  prepare_tmpdir

  ensure_dir "${DATA_ROOT}"

  docker_pkg="${TMP_DIR}/$(docker_archive_name)"
  compose_pkg="${TMP_DIR}/$(compose_binary_name)"

  download_file "$(docker_download_url)" "${docker_pkg}"
  download_file "$(compose_download_url)" "${compose_pkg}"

  validate_downloaded_artifacts "${TMP_DIR}"
  install_binaries "${docker_pkg}" "${compose_pkg}" "${TMP_DIR}"
  write_daemon_config
  install_systemd_unit
  start_and_verify
}

install_offline() {
  local offline_dir_abs
  local docker_pkg
  local compose_pkg

  require_root
  prepare_tmpdir

  offline_dir_abs="$(realpath "${OFFLINE_DIR}")"
  docker_pkg="${offline_dir_abs}/$(docker_archive_name)"
  compose_pkg="${offline_dir_abs}/$(compose_binary_name)"

  [[ -f "${docker_pkg}" ]] || die "Offline package missing: ${docker_pkg}"
  [[ -f "${compose_pkg}" ]] || die "Offline package missing: ${compose_pkg}"

  verify_offline_checksums_if_present "${offline_dir_abs}"
  ensure_dir "${DATA_ROOT}"

  install_binaries "${docker_pkg}" "${compose_pkg}" "${TMP_DIR}"
  write_daemon_config
  install_systemd_unit
  start_and_verify
}

remove_file_if_exists() {
  local target="$1"
  if [[ -e "${target}" ]]; then
    rm -f -- "${target}"
    SUMMARY_ITEMS+=("Removed ${target}")
  fi
}

remove_dir_if_empty() {
  local target="$1"
  if [[ -d "${target}" ]]; then
    rmdir --ignore-fail-on-non-empty "${target}" 2>/dev/null || true
  fi
}

safe_remove_data_root() {
  local target
  target="$(realpath -m "${DATA_ROOT}")"

  [[ "${target}" != "/" ]] || die "Refuse to purge root directory"
  [[ "${target}" != "/data" ]] || die "Refuse to purge /data directly"

  if [[ -d "${target}" ]]; then
    rm -rf -- "${target}"
    SUMMARY_ITEMS+=("Removed data-root ${target}")
  fi
}

uninstall_docker() {
  local binaries
  local bin

  require_root

  if systemctl list-unit-files | grep -q '^docker\.service'; then
    systemctl stop docker >/dev/null 2>&1 || true
    systemctl disable docker >/dev/null 2>&1 || true
    SUMMARY_ITEMS+=("Stopped and disabled docker.service")
  fi

  remove_file_if_exists /etc/systemd/system/docker.service
  remove_file_if_exists /etc/docker/daemon.json
  remove_dir_if_empty /etc/docker

  binaries=(
    containerd
    containerd-shim
    containerd-shim-runc-v2
    ctr
    docker
    docker-compose
    docker-init
    docker-proxy
    dockerd
    runc
  )

  for bin in "${binaries[@]}"; do
    remove_file_if_exists "${INSTALL_DIR}/${bin}"
  done

  systemctl daemon-reload

  if [[ "${PURGE_DATA}" == "true" ]]; then
    safe_remove_data_root
  else
    SUMMARY_ITEMS+=("Preserved data-root ${DATA_ROOT}")
  fi
}

print_summary() {
  local item
  printf '\n=== Execution Summary ===\n'
  printf 'Mode: %s\n' "${MODE}"
  printf 'Architecture: %s\n' "${TARGET_ARCH}"
  for item in "${SUMMARY_ITEMS[@]}"; do
    printf ' - %s\n' "${item}"
  done
}

main() {
  trap on_error ERR
  trap cleanup EXIT

  parse_args "$@"
  check_dependencies

  case "${MODE}" in
    online)
      install_online
      ;;
    offline)
      install_offline
      ;;
    prepare-offline)
      prepare_offline_packages
      ;;
    uninstall)
      uninstall_docker
      ;;
  esac

  print_summary
}

main "$@"

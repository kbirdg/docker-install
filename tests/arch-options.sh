#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

fake_bin="${tmp_dir}/bin"
mkdir -p -- "${fake_bin}"

cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

url=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --*)
      if [[ "$1" == "--continue-at" || "$1" == "--retry" || "$1" == "--retry-delay" ]]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

[[ -n "${output}" ]] || {
  printf 'missing output\n' >&2
  exit 1
}

mkdir -p -- "$(dirname -- "${output}")"
printf '%s\n' "${url}" >> "${FAKE_CURL_LOG}"

if [[ "${url}" == *"/docker-"*".tgz" ]]; then
  work_dir="$(mktemp -d)"
  mkdir -p -- "${work_dir}/docker"
  printf '#!/usr/bin/env sh\n' > "${work_dir}/docker/docker"
  tar -czf "${output}" -C "${work_dir}" docker
  rm -rf -- "${work_dir}"
else
  printf '#!/usr/bin/env sh\n' > "${output}"
fi
EOF
chmod +x "${fake_bin}/curl"

run_prepare_offline_arch_case() {
  local arch="$1"
  local offline_dir="$2"
  local curl_log="${tmp_dir}/curl-${arch}.log"

  mkdir -p -- "${offline_dir}"

  FAKE_CURL_LOG="${curl_log}" PATH="${fake_bin}:${PATH}" \
    bash "${repo_root}/docker-install.sh" \
      --mode prepare-offline \
      --arch "${arch}" \
      --docker-version 28.4.0 \
      --compose-version v2.27.0 \
      --offline-dir "${offline_dir}" \
      --mirror-url https://download.docker.com

  [[ -s "${offline_dir}/docker-28.4.0-${arch}.tgz" ]]
  [[ -s "${offline_dir}/docker-compose-linux-${arch}" ]]
  grep -q "/linux/static/stable/${arch}/docker-28.4.0.tgz$" "${curl_log}"
  grep -q "/v2.27.0/docker-compose-linux-${arch}$" "${curl_log}"
  grep -q "Architecture: ${arch}" "${offline_dir}/download-report.txt"
}

combined_offline_dir="${tmp_dir}/offline-combined"
run_prepare_offline_arch_case x86_64 "${combined_offline_dir}"
run_prepare_offline_arch_case aarch64 "${combined_offline_dir}"

grep -q 'docker-28.4.0-x86_64.tgz$' "${combined_offline_dir}/SHA256SUMS"
grep -q 'docker-compose-linux-x86_64$' "${combined_offline_dir}/SHA256SUMS"
grep -q 'docker-28.4.0-aarch64.tgz$' "${combined_offline_dir}/SHA256SUMS"
grep -q 'docker-compose-linux-aarch64$' "${combined_offline_dir}/SHA256SUMS"
(
  cd -- "${combined_offline_dir}"
  sha256sum -c SHA256SUMS >/dev/null
)

printf 'arch-options: ok\n'

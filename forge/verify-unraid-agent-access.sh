#!/usr/bin/env bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly FORGE_IP="${FORGE_IP:-192.168.50.179}"
readonly MAX_ROOT_MINUTES="${MAX_ROOT_MINUTES:-480}"
readonly AUTHORIZED="${AUTHORIZED:-/boot/config/ssh/root/authorized_keys}"
readonly AUDIT_LOG="${AUDIT_LOG:-/boot/config/ssh/root/forge-agent-root-access.log}"
readonly READONLY_MARKER=forge-agent-unraid-readonly
readonly LEGACY_MARKER=forge-codex-unraid-readonly
readonly UNMANAGED_LEGACY_MARKER=forge-codex-readonly
readonly ROOT_MARKER=forge-agent-unraid-root
SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
  pwd -P
)"
readonly SCRIPT_DIR
REPO_ROOT="$(
  git -C "${SCRIPT_DIR}" rev-parse --show-toplevel
)"
readonly REPO_ROOT
readonly MAP="${SCRIPT_DIR}/unraid-agent-access.map"

mode=live

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-unraid-agent-access.sh [--live | --source-only]

--live verifies tracked sources, their Arc live paths, authorized-key
restrictions, and root-audit-log permissions. It is the default.

--source-only verifies repository paths, Git executable modes, Bash syntax,
and the map without reading Arc runtime state.
EOF
  exit 2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

verify_head_bytes() {
  local path=$1
  local working_file="${REPO_ROOT}/${path}"
  local head_oid working_oid

  head_oid="$(git -C "${REPO_ROOT}" rev-parse "HEAD:${path}")"
  [[ -n "${head_oid}" ]] || die "No committed HEAD object for ${path}"
  working_oid="$(git -C "${REPO_ROOT}" hash-object -- "${working_file}")"
  [[ "${working_oid}" == "${head_oid}" ]] ||
    die "Working-tree bytes differ from committed HEAD: ${path}"
}

if [[ $# -gt 1 ]]; then
  usage
fi
case "${1:---live}" in
  --live) mode=live ;;
  --source-only) mode=source-only ;;
  *) usage ;;
esac

[[ -f "${MAP}" && ! -L "${MAP}" ]] ||
  die "Missing or unsafe installed/source map: ${MAP}"
map_header="$(head -n 1 "${MAP}")"
[[ "${map_header}" == $'# source_path\tlive_path\towner\tmode\trole' ]] ||
  die "Unexpected map header."

declare -A seen_sources=()
declare -A seen_live=()
mapped_count=0

while IFS=$'\t' read -r source_path live_path expected_owner expected_mode role
do
  [[ -n "${source_path}" && "${source_path}" != \#* ]] || continue
  (( mapped_count += 1 ))

  [[ "${source_path}" == forge/* && "${source_path}" != *..* ]] ||
    die "Unsafe source path in map: ${source_path}"
  [[ "${live_path}" == /mnt/user/appdata/unraid-docker-lab/forge/* &&
     "${live_path}" != *..* ]] ||
    die "Unsafe live path in map: ${live_path}"
  [[ "${expected_owner}" == root:root ]] ||
    die "Unexpected owner policy for ${source_path}"
  [[ "${expected_mode}" == 755 ]] ||
    die "Unexpected mode policy for ${source_path}"
  [[ -n "${role}" ]] || die "Missing role for ${source_path}"
  [[ -z "${seen_sources[${source_path}]:-}" ]] ||
    die "Duplicate source path: ${source_path}"
  [[ -z "${seen_live[${live_path}]:-}" ]] ||
    die "Duplicate live path: ${live_path}"
  seen_sources["${source_path}"]=1
  seen_live["${live_path}"]=1

  source_file="${REPO_ROOT}/${source_path}"
  [[ -f "${source_file}" && ! -L "${source_file}" ]] ||
    die "Missing or unsafe tracked source: ${source_path}"
  git -C "${REPO_ROOT}" ls-files --error-unmatch -- "${source_path}" \
    >/dev/null ||
    die "Source is not tracked: ${source_path}"
  git_mode="$(
    git -C "${REPO_ROOT}" ls-files -s -- "${source_path}" |
      awk 'NR == 1 { print $1 }'
  )"
  [[ "${git_mode}" == 100755 ]] ||
    die "Tracked mode for ${source_path} is ${git_mode}, expected 100755"
  verify_head_bytes "${source_path}"
  bash -n "${source_file}"

  if [[ "${mode}" == live ]]; then
    [[ -f "${live_path}" && ! -L "${live_path}" ]] ||
      die "Missing or unsafe Arc live path: ${live_path}"
    [[ "$(stat -c '%U:%G' "${live_path}")" == "${expected_owner}" ]] ||
      die "Unexpected owner for ${live_path}"
    [[ "$(stat -c '%a' "${live_path}")" == "${expected_mode}" ]] ||
      die "Unexpected mode for ${live_path}"
    source_resolved="$(readlink -f -- "${source_file}")"
    live_resolved="$(readlink -f -- "${live_path}")"
    if [[ "${source_resolved}" != "${live_resolved}" ]]; then
      cmp -s -- "${source_file}" "${live_path}" ||
        die "Source/live content differs: ${source_path} -> ${live_path}"
    fi
  fi

  note "mapped=ok source=${source_path} live=${live_path} role=${role}"
done <"${MAP}"

[[ "${mapped_count}" -eq 3 ]] ||
  die "Expected exactly three access-tool mappings, found ${mapped_count}"

git -C "${REPO_ROOT}" ls-files --error-unmatch -- \
  forge/unraid-agent-access.map \
  forge/restart-unraid-docker-clean-env.sh \
  forge/verify-unraid-agent-access.sh >/dev/null ||
  die "Map, Docker restart helper, or verifier is not tracked."
verify_head_bytes forge/unraid-agent-access.map
verify_head_bytes forge/restart-unraid-docker-clean-env.sh
verify_head_bytes forge/verify-unraid-agent-access.sh
[[ "$(
  git -C "${REPO_ROOT}" ls-files -s -- \
    forge/restart-unraid-docker-clean-env.sh |
    awk 'NR == 1 { print $1 }'
)" == 100755 ]] || die "Docker restart helper must be tracked executable."
[[ "$(
  git -C "${REPO_ROOT}" ls-files -s -- \
    forge/verify-unraid-agent-access.sh |
    awk 'NR == 1 { print $1 }'
)" == 100755 ]] || die "Verifier must be tracked executable."
bash -n "${SCRIPT_DIR}/restart-unraid-docker-clean-env.sh"
bash -n "${SCRIPT_DIR}/verify-unraid-agent-access.sh"

for expected in \
  'MARKER=forge-agent-unraid-root' \
  ': "${MAX_MINUTES:=480}"' \
  ': "${AUTHORIZED:=/boot/config/ssh/root/authorized_keys}"' \
  ': "${AUDIT_LOG:=/boot/config/ssh/root/forge-agent-root-access.log}"'
do
  grep -qxF -- "${expected}" \
    "${REPO_ROOT}/forge/manage-unraid-agent-root.sh" ||
    die "Root manager is missing policy line: ${expected}"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=warning \
    "${REPO_ROOT}/forge/unraid-readonly-wrapper.sh" \
    "${REPO_ROOT}/forge/authorize-unraid-agent-key.sh" \
    "${REPO_ROOT}/forge/manage-unraid-agent-root.sh" \
    "${REPO_ROOT}/forge/restart-unraid-docker-clean-env.sh" \
    "${REPO_ROOT}/forge/verify-unraid-agent-access.sh"
  note 'shellcheck=passed'
else
  note 'shellcheck=not-installed (run separately before merge)'
fi

if [[ "${mode}" == source-only ]]; then
  note 'source_control=verified'
  exit 0
fi

[[ "${EUID}" -eq 0 ]] ||
  die "--live must run as root to inspect Arc SSH authorization."
for protected_source in \
  "${SCRIPT_DIR}/restart-unraid-docker-clean-env.sh" \
  "${SCRIPT_DIR}/verify-unraid-agent-access.sh"
do
  [[ "$(stat -c '%U:%G' "${protected_source}")" == root:root ]] ||
    die "Protected helper is not root-owned: ${protected_source}"
  protected_mode="$(stat -c '%a' "${protected_source}")"
  (( (8#${protected_mode} & 8#022) == 0 )) ||
    die "Protected helper is group/world writable: ${protected_source}"
done
[[ -f "${AUTHORIZED}" && ! -L "${AUTHORIZED}" ]] ||
  die "Missing or unsafe authorized-keys file: ${AUTHORIZED}"
[[ "$(stat -c '%U:%G' "${AUTHORIZED}")" == root:root ]] ||
  die "Unexpected owner for ${AUTHORIZED}"
[[ "$(stat -c '%a' "${AUTHORIZED}")" == 600 ]] ||
  die "Unexpected mode for ${AUTHORIZED}"

mapfile -t readonly_entries < <(
  grep -E " ${READONLY_MARKER}$" "${AUTHORIZED}" || true
)
[[ "${#readonly_entries[@]}" -eq 1 ]] ||
  die "Expected one ${READONLY_MARKER} entry; found ${#readonly_entries[@]}"

readonly_entry="${readonly_entries[0]}"
readonly_options="${readonly_entry%% ssh-ed25519 *}"
readonly_rest="${readonly_entry#* ssh-ed25519 }"
readonly_key="${readonly_rest%% *}"
readonly_comment="${readonly_rest#* }"
readonly_wrapper=/mnt/user/appdata/unraid-docker-lab/forge/unraid-readonly-wrapper.sh
expected_readonly_options="from=\"${FORGE_IP}\",restrict,command=\"${readonly_wrapper}\""
[[ "${readonly_options}" == "${expected_readonly_options}" ]] ||
  die "Standing key has unexpected restrictions."
[[ "${readonly_key}" =~ ^[A-Za-z0-9+/=]+$ ]] ||
  die "Standing key has malformed public material."
[[ "${readonly_comment}" == "${READONLY_MARKER}" ]] ||
  die "Standing key has unexpected marker."
note "standing_readonly=verified source=${FORGE_IP} forced_command=${readonly_wrapper}"

legacy_count="$(
  grep -Ec " (${LEGACY_MARKER}|${UNMANAGED_LEGACY_MARKER})$" \
    "${AUTHORIZED}" || true
)"
[[ "${legacy_count}" -eq 0 ]] ||
  die "Legacy Forge read-only authorization remains installed (${legacy_count})."
note 'legacy_readonly_entries=0'

mapfile -t root_entries < <(
  grep -E " ${ROOT_MARKER}$" "${AUTHORIZED}" || true
)
case "${#root_entries[@]}" in
  0)
    note 'temporary_root=inactive'
    ;;
  1)
    root_entry="${root_entries[0]}"
    root_options="${root_entry%% ssh-ed25519 *}"
    root_rest="${root_entry#* ssh-ed25519 }"
    root_key="${root_rest%% *}"
    root_comment="${root_rest#* }"
    expiry_prefix="from=\"${FORGE_IP}\",restrict,expiry-time=\""
    [[ "${root_options}" == "${expiry_prefix}"*'"' ]] ||
      die "Temporary root entry has unexpected restrictions."
    expiry="${root_options#"${expiry_prefix}"}"
    expiry="${expiry%\"}"
    [[ "${expiry}" =~ ^[0-9]{14}Z$ ]] ||
      die "Temporary root entry has malformed expiry."
    [[ "${root_key}" =~ ^[A-Za-z0-9+/=]+$ ]] ||
      die "Temporary root entry has malformed public material."
    [[ "${root_comment}" == "${ROOT_MARKER}" ]] ||
      die "Temporary root entry has unexpected marker."
    now="$(date -u +%Y%m%d%H%M%SZ)"
    if [[ "${expiry}" < "${now}" ]]; then
      die "Expired temporary root entry remains installed (expiry ${expiry})."
    fi
    maximum_expiry="$(
      date -u -d "+${MAX_ROOT_MINUTES} minutes" +%Y%m%d%H%M%SZ
    )"
    if [[ "${expiry}" > "${maximum_expiry}" ]]; then
      die "Temporary root expiry exceeds ${MAX_ROOT_MINUTES} minutes."
    fi
    note "temporary_root=active source=${FORGE_IP} expiry=${expiry}"
    ;;
  *)
    die "Multiple ${ROOT_MARKER} entries are installed."
    ;;
esac

if [[ -e "${AUDIT_LOG}" ]]; then
  [[ -f "${AUDIT_LOG}" && ! -L "${AUDIT_LOG}" ]] ||
    die "Unsafe root-access audit log: ${AUDIT_LOG}"
  [[ "$(stat -c '%U:%G' "${AUDIT_LOG}")" == root:root ]] ||
    die "Unexpected audit-log owner."
  [[ "$(stat -c '%a' "${AUDIT_LOG}")" == 600 ]] ||
    die "Unexpected audit-log mode."
  note "root_audit_log=verified path=${AUDIT_LOG}"
else
  note "root_audit_log=absent (created by first manager invocation)"
fi

note 'live_access_boundary=verified'

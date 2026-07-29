#!/usr/bin/bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly FORGE_IP=192.168.50.179
readonly MAX_ROOT_MINUTES=480
readonly AUTHORIZED=/boot/config/ssh/root/authorized_keys
readonly AUTHORIZED_LOCK="${AUTHORIZED}.forge-agent.lock"
readonly AUDIT_LOG=/boot/config/ssh/root/forge-agent-root-access.log
readonly PROTECTED_ROOT=/boot/config/custom/forge-agent-access
readonly PROTECTED_MANIFEST="${PROTECTED_ROOT}/forge/unraid-agent-access.sha256"
readonly PROTECTED_MAP="${PROTECTED_ROOT}/forge/unraid-agent-access.map"
readonly PROTECTED_VERIFIER="${PROTECTED_ROOT}/forge/verify-unraid-agent-access.sh"
readonly UPDATE_LOCK="${PROTECTED_ROOT}/.update.lock"
readonly SOURCE_PIN="${PROTECTED_ROOT}/source.pin"
readonly READONLY_MARKER=forge-agent-unraid-readonly
readonly LEGACY_MARKER=forge-codex-unraid-readonly
readonly UNMANAGED_LEGACY_MARKER=forge-codex-readonly
readonly ROOT_MARKER=forge-agent-unraid-root

mode=live

usage() {
  /usr/bin/cat >&2 <<'EOF'
Usage:
  verify-unraid-agent-access.sh [--live | --source-only]

--live must run from the root-protected /boot bundle. It validates protected
ancestry and manifest pins before inspecting runtime authorization.

--source-only validates the repository sources, committed-HEAD bytes, manifest,
map, Bash syntax, and ShellCheck without reading Arc runtime state.
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

assert_safe_chain() {
  local requested=$1
  local current=/
  local component owner path_mode normalized
  normalized="$(/usr/bin/readlink -m -- "${requested}")"
  [[ "${normalized}" == "${requested}" ]] ||
    die "Path is not normalized: ${requested}"
  IFS=/ read -r -a components <<<"${requested#/}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ -e "${current}" && ! -L "${current}" ]] ||
      die "Missing or symlinked protected path: ${current}"
    owner="$(/usr/bin/stat -Lc '%U:%G' "${current}")"
    path_mode="$(/usr/bin/stat -Lc '%a' "${current}")"
    [[ "${owner}" == root:root ]] ||
      die "Non-root owner in protected path: ${current}"
    (( (8#${path_mode} & 8#022) == 0 )) ||
      die "Group/world-writable protected path: ${current}"
  done
}

validate_root_file() {
  local path=$1
  [[ -f "${path}" && ! -L "${path}" ]] ||
    die "Missing or unsafe regular file: ${path}"
  [[ "$(/usr/bin/stat -Lc '%U:%G' "${path}")" == root:root ]] ||
    die "File is not root-owned: ${path}"
  local file_mode
  file_mode="$(/usr/bin/stat -Lc '%a' "${path}")"
  (( (8#${file_mode} & 8#022) == 0 )) ||
    die "File is group/world writable: ${path}"
}

verify_map() {
  local map=$1
  local expected_root=$2
  local count=0
  local source_path protected_path protected_basename owner expected_mode role
  local -A seen_sources=()
  local -A seen_protected=()
  local map_header

  map_header="$(/usr/bin/head -n 1 "${map}")"
  [[ "${map_header}" == \
    $'# source_path\tprotected_path\towner\tmode\trole' ]] ||
    die "Unexpected access map header."
  while IFS=$'\t' read -r \
    source_path protected_path owner expected_mode role
  do
    [[ -n "${source_path}" && "${source_path}" != \#* ]] || continue
    (( count += 1 ))
    [[ "${source_path}" =~ ^forge/[A-Za-z0-9._-]+$ ]] ||
      die "Unsafe mapped source: ${source_path}"
    protected_basename="${protected_path#"${expected_root}/forge/"}"
    [[ "${protected_path}" == "${expected_root}/forge/"* &&
       "${protected_basename}" =~ ^[A-Za-z0-9._-]+$ ]] ||
      die "Unsafe mapped protected path: ${protected_path}"
    [[ "${owner}" == root:root && "${expected_mode}" == 500 &&
       -n "${role}" ]] ||
      die "Unsafe map policy for ${source_path}"
    [[ -z "${seen_sources[${source_path}]:-}" &&
       -z "${seen_protected[${protected_path}]:-}" ]] ||
      die "Duplicate source or protected path in map."
    seen_sources["${source_path}"]=1
    seen_protected["${protected_path}"]=1
  done <"${map}"
  [[ "${count}" -eq 3 ]] ||
    die "Expected three mapped access tools, found ${count}."
}

if [[ $# -gt 1 ]]; then
  usage
fi
case "${1:---live}" in
  --live) mode=live ;;
  --source-only) mode=source-only ;;
  *) usage ;;
esac

if [[ "${mode}" == source-only ]]; then
  script_dir="$(
    cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")"
    pwd -P
  )"
  repo_root="$(/usr/bin/git -C "${script_dir}" rev-parse --show-toplevel)"
  manifest="${repo_root}/forge/unraid-agent-access.sha256"
  map="${repo_root}/forge/unraid-agent-access.map"

  verify_head_bytes() {
    local relative=$1
    local working="${repo_root}/${relative}"
    local head_oid working_oid
    head_oid="$(
      /usr/bin/git -C "${repo_root}" rev-parse "HEAD:${relative}"
    )"
    working_oid="$(
      /usr/bin/git -C "${repo_root}" hash-object -- "${working}"
    )"
    [[ "${working_oid}" == "${head_oid}" ]] ||
      die "Working bytes differ from committed HEAD: ${relative}"
  }

  for required in \
    forge/unraid-readonly-wrapper.sh \
    forge/authorize-unraid-agent-key.sh \
    forge/manage-unraid-agent-root.sh \
    forge/restart-unraid-docker-clean-env.sh \
    forge/update-unraid-agent-access.sh \
    forge/verify-unraid-agent-access.sh \
    forge/unraid-agent-access.map \
    forge/unraid-agent-access.sha256
  do
    /usr/bin/git -C "${repo_root}" \
      ls-files --error-unmatch -- "${required}" >/dev/null ||
      die "Required source is not tracked: ${required}"
    verify_head_bytes "${required}"
  done

  verify_map "${map}" "${PROTECTED_ROOT}"
  declare -A manifest_paths=()
  manifest_count=0
  while read -r expected_sha relative_path extra; do
    [[ -z "${extra:-}" ]] || die "Malformed source manifest entry."
    [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ &&
       "${relative_path}" =~ ^forge/[A-Za-z0-9._-]+$ ]] ||
      die "Unsafe source manifest entry."
    [[ -z "${manifest_paths[${relative_path}]:-}" ]] ||
      die "Duplicate source manifest path: ${relative_path}"
    manifest_paths["${relative_path}"]=1
    actual_sha="$(
      /usr/bin/sha256sum "${repo_root}/${relative_path}" |
        /usr/bin/awk '{print $1}'
    )"
    [[ "${actual_sha}" == "${expected_sha}" ]] ||
      die "Manifest hash mismatch: ${relative_path}"
    verify_head_bytes "${relative_path}"
    (( manifest_count += 1 ))
  done <"${manifest}"
  [[ "${manifest_count}" -eq 7 ]] ||
    die "Expected seven manifest entries, found ${manifest_count}."
  [[ -n "${manifest_paths[forge/unraid-agent-access.map]:-}" ]] ||
    die "Protected manifest omits the access map."

  while IFS= read -r shell_source; do
    /usr/bin/bash -n "${repo_root}/${shell_source}"
  done < <(
    /usr/bin/printf '%s\n' "${!manifest_paths[@]}" |
      /usr/bin/grep -E '\.sh$' |
      /usr/bin/sort
  )

  if command -v shellcheck >/dev/null 2>&1; then
    /usr/bin/shellcheck --severity=warning \
      "${repo_root}/forge/unraid-readonly-wrapper.sh" \
      "${repo_root}/forge/authorize-unraid-agent-key.sh" \
      "${repo_root}/forge/manage-unraid-agent-root.sh" \
      "${repo_root}/forge/restart-unraid-docker-clean-env.sh" \
      "${repo_root}/forge/update-unraid-agent-access.sh" \
      "${repo_root}/forge/verify-unraid-agent-access.sh"
    note shellcheck=passed
  else
    note 'shellcheck=not-installed (required separately before merge)'
  fi
  note source_control=verified
  exit 0
fi

[[ "${EUID}" -eq 0 ]] ||
  die "--live must run as root on Arc/Unraid."
invoked_path="$(/usr/bin/readlink -m -- "${BASH_SOURCE[0]}")"
[[ "${invoked_path}" == "${PROTECTED_VERIFIER}" &&
   ! -L "${PROTECTED_VERIFIER}" ]] ||
  die "--live must run the protected verifier: ${PROTECTED_VERIFIER}"
assert_safe_chain "${PROTECTED_ROOT}"
validate_root_file "${UPDATE_LOCK}"
exec {update_lock_fd}<>"${UPDATE_LOCK}"
/usr/bin/flock -s "${update_lock_fd}"

validate_root_file "${PROTECTED_MANIFEST}"
validate_root_file "${PROTECTED_MAP}"
validate_root_file "${SOURCE_PIN}"
mapfile -t source_pin_lines <"${SOURCE_PIN}"
[[ "${#source_pin_lines[@]}" -eq 2 &&
   "${source_pin_lines[0]}" =~ ^commit=[0-9a-f]{40}$ &&
   "${source_pin_lines[1]}" =~ ^manifest_sha256=[0-9a-f]{64}$ ]] ||
  die "Malformed protected source pin."
protected_manifest_sha="$(
  /usr/bin/sha256sum "${PROTECTED_MANIFEST}" |
    /usr/bin/awk '{print $1}'
)"
[[ "${source_pin_lines[1]}" == \
  "manifest_sha256=${protected_manifest_sha}" ]] ||
  die "Protected manifest differs from the recorded independent pin."
verify_map "${PROTECTED_MAP}" "${PROTECTED_ROOT}"
protected_count=0
while read -r expected_sha relative_path extra; do
  [[ -z "${extra:-}" ]] || die "Malformed protected manifest entry."
  [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ &&
     "${relative_path}" =~ ^forge/[A-Za-z0-9._-]+$ ]] ||
    die "Unsafe protected manifest entry."
  protected_file="${PROTECTED_ROOT}/${relative_path}"
  validate_root_file "${protected_file}"
  actual_sha="$(
    /usr/bin/sha256sum "${protected_file}" |
      /usr/bin/awk '{print $1}'
  )"
  [[ "${actual_sha}" == "${expected_sha}" ]] ||
    die "Protected manifest mismatch: ${relative_path}"
  (( protected_count += 1 ))
done <"${PROTECTED_MANIFEST}"
[[ "${protected_count}" -eq 7 ]] ||
  die "Expected seven protected manifest entries, found ${protected_count}."
note "protected_bundle=verified ${source_pin_lines[0]} manifest_pin=yes"

while IFS=$'\t' read -r \
  source_path protected_path owner expected_mode role
do
  [[ -n "${source_path}" && "${source_path}" != \#* ]] || continue
  validate_root_file "${protected_path}"
  [[ "$(/usr/bin/stat -Lc '%U:%G' "${protected_path}")" == "${owner}" ]]
  [[ "$(/usr/bin/stat -Lc '%a' "${protected_path}")" == "${expected_mode}" ]]
  note "protected=ok path=${protected_path} role=${role}"
done <"${PROTECTED_MAP}"

validate_root_file "${AUTHORIZED}"
assert_safe_chain "$(/usr/bin/dirname "${AUTHORIZED}")"
[[ "$(/usr/bin/stat -Lc '%a' "${AUTHORIZED}")" == 600 ]] ||
  die "Unexpected authorized_keys mode."
if [[ -e "${AUTHORIZED_LOCK}" ]]; then
  validate_root_file "${AUTHORIZED_LOCK}"
fi

mapfile -t readonly_entries < <(
  /usr/bin/grep -E " ${READONLY_MARKER}$" "${AUTHORIZED}" || true
)
[[ "${#readonly_entries[@]}" -eq 1 ]] ||
  die "Expected one ${READONLY_MARKER} entry; found ${#readonly_entries[@]}."
readonly_entry="${readonly_entries[0]}"
readonly_options="${readonly_entry%% ssh-ed25519 *}"
readonly_rest="${readonly_entry#* ssh-ed25519 }"
readonly_key="${readonly_rest%% *}"
readonly_comment="${readonly_rest#* }"
expected_options="from=\"${FORGE_IP}\",restrict,command=\"${PROTECTED_ROOT}/forge/unraid-readonly-wrapper.sh\""
[[ "${readonly_options}" == "${expected_options}" ]] ||
  die "Standing key does not use the protected forced-command path."
[[ "${readonly_key}" =~ ^[A-Za-z0-9+/=]+$ &&
   "${readonly_comment}" == "${READONLY_MARKER}" ]] ||
  die "Standing key is malformed."
note "standing_readonly=verified source=${FORGE_IP} protected_command=yes"

legacy_count="$(
  /usr/bin/grep -Ec \
    " (${LEGACY_MARKER}|${UNMANAGED_LEGACY_MARKER})$" \
    "${AUTHORIZED}" || true
)"
[[ "${legacy_count}" -eq 0 ]] ||
  die "Legacy Forge read-only authorization remains (${legacy_count})."
note legacy_readonly_entries=0

mapfile -t root_entries < <(
  /usr/bin/grep -E " ${ROOT_MARKER}$" "${AUTHORIZED}" || true
)
case "${#root_entries[@]}" in
  0)
    note temporary_root=inactive
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
    [[ "${expiry}" =~ ^[0-9]{14}Z$ &&
       "${root_key}" =~ ^[A-Za-z0-9+/=]+$ &&
       "${root_comment}" == "${ROOT_MARKER}" ]] ||
      die "Temporary root entry is malformed."
    now="$(/usr/bin/date -u +%Y%m%d%H%M%SZ)"
    [[ "${expiry}" > "${now}" ]] ||
      die "Expired temporary root entry remains installed."
    maximum_expiry="$(
      /usr/bin/date -u -d \
        "+${MAX_ROOT_MINUTES} minutes" +%Y%m%d%H%M%SZ
    )"
    [[ "${expiry}" < "${maximum_expiry}" ||
       "${expiry}" == "${maximum_expiry}" ]] ||
      die "Temporary root expiry exceeds ${MAX_ROOT_MINUTES} minutes."
    note "temporary_root=active source=${FORGE_IP} expiry=${expiry}"
    ;;
  *)
    die "Multiple ${ROOT_MARKER} entries are installed."
    ;;
esac

if [[ -e "${AUDIT_LOG}" ]]; then
  validate_root_file "${AUDIT_LOG}"
  [[ "$(/usr/bin/stat -Lc '%a' "${AUDIT_LOG}")" == 600 ]] ||
    die "Unexpected root-audit-log mode."
  note root_audit_log=verified
else
  note 'root_audit_log=absent (created by first manager invocation)'
fi

note live_access_boundary=verified

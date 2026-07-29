#!/usr/bin/bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly PROTECTED_ROOT=/boot/config/custom/forge-agent-access
readonly MANIFEST_RELATIVE=forge/unraid-agent-access.sha256
readonly SELF_PATH="${PROTECTED_ROOT}/forge/update-unraid-agent-access.sh"
readonly UPDATE_LOCK="${PROTECTED_ROOT}/.update.lock"
readonly SOURCE_PIN="${PROTECTED_ROOT}/source.pin"

usage() {
  cat >&2 <<'EOF'
Usage:
  update-unraid-agent-access.sh update REPO_ROOT EXPECTED_COMMIT EXPECTED_MANIFEST_SHA256

Execute only the already protected copy under /boot/config/custom. For initial
bootstrap, copy this helper to a root-only temporary path, verify that snapshot
against an independently obtained SHA-256 value, and execute that snapshot.
Never execute a privileged helper directly from /mnt/user.
EOF
  exit 2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_safe_chain() {
  local requested=$1
  local current=/
  local component owner mode normalized
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
    mode="$(/usr/bin/stat -Lc '%a' "${current}")"
    [[ "${owner}" == root:root ]] ||
      die "Non-root owner in protected path: ${current}"
    (( (8#${mode} & 8#022) == 0 )) ||
      die "Group/world-writable protected path: ${current}"
  done
}

atomic_install() {
  local source=$1
  local target=$2
  local mode=$3
  local temporary
  temporary="$(/usr/bin/mktemp "${target}.XXXXXX")"
  if ! /usr/bin/install -o root -g root -m "${mode}" \
    "${source}" "${temporary}"
  then
    /usr/bin/rm -f -- "${temporary}"
    return 1
  fi
  if ! /usr/bin/mv -f -- "${temporary}" "${target}"; then
    /usr/bin/rm -f -- "${temporary}"
    return 1
  fi
}

repo_git() {
  /usr/bin/setpriv \
    --reuid=99 \
    --regid=100 \
    --clear-groups \
    --no-new-privs \
    /usr/bin/env -i \
      PATH=/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/nonexistent \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_OPTIONAL_LOCKS=0 \
      GIT_TERMINAL_PROMPT=0 \
      /usr/bin/git \
        -c safe.directory="${repo_root}" \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        -C "${repo_root}" "$@"
}

[[ "${EUID}" -eq 0 ]] || die "Run this helper as root on Arc/Unraid."
[[ $# -eq 4 && "$1" == update ]] || usage
repo_root=$2
expected_commit=$3
expected_manifest_sha=$4

[[ "${expected_commit}" =~ ^[0-9a-f]{40}$ ]] ||
  die "EXPECTED_COMMIT must be a full lowercase Git commit ID."
[[ "${expected_manifest_sha}" =~ ^[0-9a-f]{64}$ ]] ||
  die "EXPECTED_MANIFEST_SHA256 must be a lowercase SHA-256 digest."
[[ -d "${repo_root}" && ! -L "${repo_root}" ]] ||
  die "Repository root is missing or a symlink."
[[ "$(repo_git rev-parse HEAD)" == "${expected_commit}" ]] ||
  die "Repository HEAD does not match EXPECTED_COMMIT."

assert_safe_chain /boot/config/custom
/usr/bin/install -d -o root -g root -m 0700 \
  "${PROTECTED_ROOT}" "${PROTECTED_ROOT}/forge"
assert_safe_chain "${PROTECTED_ROOT}"

if [[ "${BASH_SOURCE[0]}" != "${SELF_PATH}" ]]; then
  [[ "${FORGE_AGENT_ACCESS_BOOTSTRAP:-}" == 1 ]] ||
    die "Updater must run from ${SELF_PATH}; initial bootstrap requires the explicit trusted-snapshot procedure."
fi

if [[ -e "${UPDATE_LOCK}" ]]; then
  [[ -f "${UPDATE_LOCK}" && ! -L "${UPDATE_LOCK}" ]] ||
    die "Unsafe updater lock file."
  [[ "$(/usr/bin/stat -Lc '%U:%G' "${UPDATE_LOCK}")" == root:root ]] ||
    die "Updater lock is not root-owned."
else
  ( set -o noclobber; : >"${UPDATE_LOCK}" ) 2>/dev/null || true
fi
/usr/bin/chown root:root "${UPDATE_LOCK}"
/usr/bin/chmod 0600 "${UPDATE_LOCK}"
exec {update_lock_fd}<>"${UPDATE_LOCK}"
/usr/bin/flock -x "${update_lock_fd}"

staging="$(
  /usr/bin/mktemp -d \
    /boot/config/custom/.forge-agent-access-stage.XXXXXX
)"
trap '/usr/bin/rm -rf -- "${staging}"' EXIT
/usr/bin/install -d -o root -g root -m 0700 "${staging}/forge"

manifest_source="${repo_root}/${MANIFEST_RELATIVE}"
[[ -f "${manifest_source}" && ! -L "${manifest_source}" ]] ||
  die "Manifest source is missing or unsafe."
/usr/bin/install -o root -g root -m 0400 \
  "${manifest_source}" "${staging}/${MANIFEST_RELATIVE}"
actual_manifest_sha="$(
  /usr/bin/sha256sum "${staging}/${MANIFEST_RELATIVE}" |
    /usr/bin/awk '{print $1}'
)"
[[ "${actual_manifest_sha}" == "${expected_manifest_sha}" ]] ||
  die "Manifest digest does not match the independently supplied pin."

entry_count=0
while read -r expected_sha relative_path extra; do
  [[ -z "${extra:-}" ]] || die "Malformed manifest entry."
  [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] ||
    die "Malformed manifest digest."
  [[ "${relative_path}" =~ ^forge/[A-Za-z0-9._-]+$ ]] ||
    die "Unsafe manifest path: ${relative_path}"
  source_path="${repo_root}/${relative_path}"
  [[ -f "${source_path}" && ! -L "${source_path}" ]] ||
    die "Missing or unsafe source path: ${relative_path}"
  /usr/bin/install -o root -g root -m 0400 \
    "${source_path}" "${staging}/${relative_path}"
  (( entry_count += 1 ))
done <"${staging}/${MANIFEST_RELATIVE}"
[[ "${entry_count}" -eq 7 ]] ||
  die "Expected seven protected-source entries, found ${entry_count}."
(
  cd "${staging}"
  /usr/bin/sha256sum -c "${MANIFEST_RELATIVE}"
)

# The update lock is shared with the verifier. Each validated snapshot replaces
# one complete file atomically; the updater and manifest are installed last.
while read -r _ relative_path _; do
  [[ "${relative_path}" != forge/update-unraid-agent-access.sh ]] || continue
  target="${PROTECTED_ROOT}/${relative_path}"
  mode=0500
  [[ "${relative_path}" == forge/unraid-agent-access.map ]] && mode=0400
  atomic_install "${staging}/${relative_path}" "${target}" "${mode}"
done <"${staging}/${MANIFEST_RELATIVE}"
atomic_install \
  "${staging}/forge/update-unraid-agent-access.sh" \
  "${SELF_PATH}" 0500
atomic_install \
  "${staging}/${MANIFEST_RELATIVE}" \
  "${PROTECTED_ROOT}/${MANIFEST_RELATIVE}" 0400
pin_tmp="$(/usr/bin/mktemp "${PROTECTED_ROOT}/.source.pin.XXXXXX")"
trap '/usr/bin/rm -f -- "${pin_tmp}"' EXIT
printf 'commit=%s\nmanifest_sha256=%s\n' \
  "${expected_commit}" "${expected_manifest_sha}" >"${pin_tmp}"
/usr/bin/chown root:root "${pin_tmp}"
/usr/bin/chmod 0400 "${pin_tmp}"
/usr/bin/mv -f -- "${pin_tmp}" "${SOURCE_PIN}"
trap - EXIT

(
  cd "${PROTECTED_ROOT}"
  /usr/bin/sha256sum -c "${MANIFEST_RELATIVE}"
)
printf 'Protected Arc agent-access bundle updated from commit %s.\n' \
  "${expected_commit}"
printf '%s\n' \
  'No authorization entry was created, removed, or rewritten.'

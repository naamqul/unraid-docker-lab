#!/usr/bin/bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

FORGE_IP=192.168.50.179
MARKER=forge-agent-unraid-readonly
LEGACY_MARKER=forge-codex-unraid-readonly
UNMANAGED_LEGACY_MARKER=forge-codex-readonly
rotate=false

if [[ ${1:-} == --rotate ]]; then
  rotate=true
  shift
fi
PUBKEY_FILE="${1:?Usage: authorize-unraid-agent-key.sh [--rotate] /path/to/public-key}"
[[ $# -eq 1 ]] || {
  echo "Usage: authorize-unraid-agent-key.sh [--rotate] /path/to/public-key" >&2
  exit 2
}
AUTHORIZED=/boot/config/ssh/root/authorized_keys
AUTHORIZED_LOCK="${AUTHORIZED}.forge-agent.lock"
WRAPPER=/boot/config/custom/forge-agent-access/forge/unraid-readonly-wrapper.sh
EXPECTED_SELF=/boot/config/custom/forge-agent-access/forge/authorize-unraid-agent-key.sh
LEGACY_WRAPPER=/mnt/user/appdata/unraid-docker-lab/forge/unraid-readonly-wrapper.sh

[[ ${EUID} -eq 0 ]] || {
  echo "Run this helper as root on Arc/Unraid." >&2
  exit 1
}

validate_root_file() {
  local path=$1
  [[ -f "${path}" && ! -L "${path}" ]] || {
    echo "Missing or unsafe regular file: ${path}" >&2
    exit 1
  }
  [[ "$(/usr/bin/stat -c '%U' "${path}")" == root ]] || {
    echo "File must be owned by root: ${path}" >&2
    exit 1
  }
  local mode
  mode="$(/usr/bin/stat -c '%a' "${path}")"
  (( (8#${mode} & 8#022) == 0 )) || {
    echo "File must not be writable by group/other: ${path}" >&2
    exit 1
  }
}

assert_safe_chain() {
  local requested=$1
  local current=/
  local component owner mode normalized
  normalized="$(/usr/bin/readlink -m -- "${requested}")"
  [[ "${normalized}" == "${requested}" ]] || {
    echo "Path is not normalized: ${requested}" >&2
    exit 1
  }
  IFS=/ read -r -a components <<<"${requested#/}"
  for component in "${components[@]}"; do
    [[ -n "${component}" ]] || continue
    current="${current%/}/${component}"
    [[ -e "${current}" && ! -L "${current}" ]] || {
      echo "Missing or symlinked protected path: ${current}" >&2
      exit 1
    }
    owner="$(/usr/bin/stat -Lc '%U:%G' "${current}")"
    mode="$(/usr/bin/stat -Lc '%a' "${current}")"
    [[ "${owner}" == root:root ]] || {
      echo "Non-root owner in protected path: ${current}" >&2
      exit 1
    }
    (( (8#${mode} & 8#022) == 0 )) || {
      echo "Group/world-writable protected path: ${current}" >&2
      exit 1
    }
  done
}

invoked_path="$(/usr/bin/readlink -m -- "${BASH_SOURCE[0]}")"
[[ "${invoked_path}" == "${EXPECTED_SELF}" &&
   ! -L "${EXPECTED_SELF}" ]] || {
  echo "Run only the protected helper: ${EXPECTED_SELF}" >&2
  exit 1
}
assert_safe_chain "${EXPECTED_SELF}"
assert_safe_chain "${WRAPPER}"
assert_safe_chain "$(/usr/bin/dirname "${AUTHORIZED}")"
validate_root_file "${PUBKEY_FILE}"
validate_root_file "${WRAPPER}"
[[ -x "${WRAPPER}" ]] || {
  echo "Forced-command wrapper is not executable: ${WRAPPER}" >&2
  exit 1
}

key_snapshot="$(/usr/bin/mktemp /tmp/forge-agent-readonly-key.XXXXXX)"
trap '/usr/bin/rm -f -- "${key_snapshot}"' EXIT
source_fd=
exec {source_fd}<"${PUBKEY_FILE}"
source_identity="$(/usr/bin/stat -Lc '%d:%i' "${PUBKEY_FILE}")"
opened_identity="$(
  /usr/bin/stat -Lc '%d:%i' "/proc/self/fd/${source_fd}"
)"
opened_owner="$(
  /usr/bin/stat -Lc '%U' "/proc/self/fd/${source_fd}"
)"
opened_mode="$(
  /usr/bin/stat -Lc '%a' "/proc/self/fd/${source_fd}"
)"
[[ "${source_identity}" == "${opened_identity}" &&
   "${opened_owner}" == root &&
   ! -L "${PUBKEY_FILE}" ]] || {
  echo "Public-key file changed while it was being opened." >&2
  exit 1
}
(( (8#${opened_mode} & 8#022) == 0 )) || {
  echo "Opened public-key file is group/world writable." >&2
  exit 1
}
/usr/bin/cat <&"${source_fd}" >"${key_snapshot}"
final_identity="$(/usr/bin/stat -Lc '%d:%i' "${PUBKEY_FILE}")"
exec {source_fd}<&-
[[ "${source_identity}" == "${final_identity}" &&
   ! -L "${PUBKEY_FILE}" ]] || {
  echo "Public-key file changed while it was being snapshotted." >&2
  exit 1
}
/usr/bin/chown root:root "${key_snapshot}"
/usr/bin/chmod 0600 "${key_snapshot}"

[[ "$(/usr/bin/grep -cve '^[[:space:]]*$' "${key_snapshot}")" -eq 1 ]]
read -r key_type key_body key_comment <"${key_snapshot}"
[[ "${key_type}" == ssh-ed25519 ]]
[[ "${key_body}" =~ ^[A-Za-z0-9+/=]+$ ]]
[[ "${key_comment}" == "${MARKER}" ]]

fingerprint="$(
  /usr/bin/ssh-keygen -lf "${key_snapshot}" |
    /usr/bin/awk '{print $2}'
)"
[[ "${fingerprint}" == SHA256:* ]]

entry='from="'"${FORGE_IP}"'",restrict,command="'"${WRAPPER}"'" ssh-ed25519 '"${key_body}"' '"${MARKER}"
expected_options='from="'"${FORGE_IP}"'",restrict,command="'"${WRAPPER}"'"'
legacy_options='from="'"${FORGE_IP}"'",restrict,command="'"${LEGACY_WRAPPER}"'"'

/usr/bin/install -d -o root -g root -m 0700 \
  "$(/usr/bin/dirname "${AUTHORIZED}")"
if [[ -e "${AUTHORIZED}" || -L "${AUTHORIZED}" ]]; then
  validate_root_file "${AUTHORIZED}"
fi
if [[ -e "${AUTHORIZED_LOCK}" ]]; then
  validate_root_file "${AUTHORIZED_LOCK}"
else
  ( umask 077; set -o noclobber; : >"${AUTHORIZED_LOCK}" ) 2>/dev/null || true
  validate_root_file "${AUTHORIZED_LOCK}"
fi
exec {authorized_lock_fd}<>"${AUTHORIZED_LOCK}"
/usr/bin/flock -x "${authorized_lock_fd}"

/usr/bin/touch "${AUTHORIZED}"
/usr/bin/chown root:root "${AUTHORIZED}"
/usr/bin/chmod 0600 "${AUTHORIZED}"

mapfile -t marked_entries < <(
  /usr/bin/grep -E " (${MARKER}|${LEGACY_MARKER})$" \
    "${AUTHORIZED}" || true
)
mapfile -t unmanaged_legacy_entries < <(
  /usr/bin/grep -E " ${UNMANAGED_LEGACY_MARKER}$" \
    "${AUTHORIZED}" || true
)

[[ "${#unmanaged_legacy_entries[@]}" -eq 0 ]] || {
  echo "Unmanaged legacy ${UNMANAGED_LEGACY_MARKER} authorization exists; review and remove it explicitly before using this helper." >&2
  exit 1
}
[[ "${#marked_entries[@]}" -le 1 ]] || {
  echo "Multiple marked or legacy Forge agent keys exist; review them manually." >&2
  exit 1
}

key_occurrences="$(
  /usr/bin/awk -v key="${key_body}" '
    {
      for (field = 1; field <= NF; field += 1) {
        if ($field == key) {
          count += 1
        }
      }
    }
    END { print count + 0 }
  ' "${AUTHORIZED}"
)"
[[ "${key_occurrences}" -le 1 ]] || {
  echo "The Forge key appears multiple times; review authorized_keys manually." >&2
  exit 1
}

if [[ "${key_occurrences}" -eq 1 &&
      "${#marked_entries[@]}" -eq 1 &&
      "${marked_entries[0]}" == "${entry}" ]]; then
  :
else
  old_entry=
  if [[ "${#marked_entries[@]}" -gt 0 ]]; then
    old_entry="${marked_entries[0]}"
    read -r old_options old_type old_body old_comment <<<"${old_entry}"
    [[ ( "${old_options}" == "${expected_options}" ||
         "${old_options}" == "${legacy_options}" ) &&
       "${old_type}" == ssh-ed25519 &&
       "${old_body}" =~ ^[A-Za-z0-9+/=]+$ &&
       ( "${old_comment}" == "${MARKER}" ||
         "${old_comment}" == "${LEGACY_MARKER}" ) ]] || {
      echo "The existing marked Forge key has unsafe restrictions." >&2
      exit 1
    }
    if [[ "${key_occurrences}" -eq 1 &&
          "${old_body}" != "${key_body}" ]]; then
      echo "The new key already exists outside the marked Forge entry." >&2
      exit 1
    fi
    [[ "${rotate}" == true ]] || {
      echo "A different Forge agent key exists; rerun with --rotate after review." >&2
      exit 1
    }
  elif [[ "${key_occurrences}" -eq 1 ]]; then
    echo "The Forge key already exists without the managed marker." >&2
    exit 1
  fi

  temporary="$(/usr/bin/mktemp "${AUTHORIZED}.XXXXXX")"
  old_key_file="$(/usr/bin/mktemp /tmp/forge-agent-old-key.XXXXXX)"
  trap '/usr/bin/rm -f -- "${key_snapshot}" "${temporary}" "${old_key_file}"' EXIT
  if [[ -n "${old_entry}" ]]; then
    /usr/bin/grep -vxF -- \
      "${old_entry}" "${AUTHORIZED}" >"${temporary}" || true
    printf 'ssh-ed25519 %s %s\n' \
      "${old_body}" "${old_comment}" >"${old_key_file}"
    old_fingerprint="$(
      /usr/bin/ssh-keygen -lf "${old_key_file}" |
        /usr/bin/awk '{print $2}'
    )"
  else
    /usr/bin/cat "${AUTHORIZED}" >"${temporary}"
    old_fingerprint=none
  fi
  [[ ! -s "${temporary}" ]] || printf '\n' >>"${temporary}"
  printf '%s\n' "${entry}" >>"${temporary}"
  /usr/bin/chown root:root "${temporary}"
  /usr/bin/chmod 0600 "${temporary}"
  /usr/bin/mv -f -- "${temporary}" "${AUTHORIZED}"
  /usr/bin/rm -f -- "${old_key_file}"
  trap - EXIT
  printf 'Previous marked fingerprint: %s\n' "${old_fingerprint}"
fi

/usr/bin/rm -f -- "${key_snapshot}"
trap - EXIT
printf 'Authorized %s from %s through %s\n' \
  "${fingerprint}" "${FORGE_IP}" "${WRAPPER}"

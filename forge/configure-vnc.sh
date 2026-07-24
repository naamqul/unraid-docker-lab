#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
  echo "Run this script as root." >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
network=termix-private
subnet=172.23.0.0/24
gateway=172.23.0.1
source_xml="${script_dir}/Forge.xml"
runtime_xml="$(mktemp /tmp/Forge.runtime.XXXXXX)"
secret_dir=/boot/config/secrets
password_file=${secret_dir}/forge-vnc-password
vnc_marker="    <!-- FORGE_VNC_RUNTIME_PLACEHOLDER -->"
expected_uuid=1528c7a1-af0a-2d8c-11eb-6c9e2a0faeb0
expected_mac=52:54:00:c7:1f:f3

chmod 0600 "${runtime_xml}"
trap 'rm -f -- "${runtime_xml}"' EXIT

if state="$(virsh domstate Forge 2>/dev/null)"; then
  [[ "${state}" == "shut off" ]] || {
    echo "Forge must be fully shut off before changing its VNC definition." >&2
    exit 1
  }
fi

if state="$(virsh domstate Forge-Legacy 2>/dev/null)"; then
  [[ "${state}" == "shut off" ]] || {
    echo "Forge-Legacy must remain off while assigning canonical Forge access." >&2
    exit 1
  }
fi

grep -Fq "<uuid>${expected_uuid}</uuid>" "${source_xml}" || {
  echo "Tracked Forge UUID does not match the canonical replacement VM." >&2
  exit 1
}
grep -Fq "<mac address='${expected_mac}'/>" "${source_xml}" || {
  echo "Tracked Forge MAC does not match the reserved network identity." >&2
  exit 1
}

if docker network inspect "${network}" >/dev/null 2>&1; then
  docker network inspect "${network}" |
    jq -e \
      --arg subnet "${subnet}" \
      --arg gateway "${gateway}" \
      '.[0].Internal == true
       and .[0].IPAM.Config[0].Subnet == $subnet
       and .[0].IPAM.Config[0].Gateway == $gateway' \
      >/dev/null || {
        echo "Existing ${network} does not match the required subnet." >&2
        exit 1
      }
else
  docker network create \
    --driver bridge \
    --internal \
    --subnet "${subnet}" \
    --gateway "${gateway}" \
    "${network}" >/dev/null
fi

install -d -o root -g root -m 0700 "${secret_dir}"
if [[ ! -s "${password_file}" ]]; then
  umask 077
  openssl rand -base64 6 >"${password_file}"
fi
chown root:root "${password_file}"
chmod 0600 "${password_file}"

password="$(tr -d '\r\n' <"${password_file}")"
[[ "${password}" =~ ^[[:alnum:]+/]{8}$ ]] || {
  echo "Forge VNC password must contain exactly eight Base64 characters." >&2
  exit 1
}

[[ "$(grep -Fxc "${vnc_marker}" "${source_xml}")" -eq 1 ]] || {
  echo "Expected exactly one Forge VNC runtime placeholder." >&2
  exit 1
}
if grep -q "<graphics type='vnc'" "${source_xml}" ||
   grep -q "passwd=" "${source_xml}"; then
  echo "Tracked Forge XML unexpectedly contains a live VNC definition." >&2
  exit 1
fi

while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" == "${vnc_marker}" ]]; then
    printf "    <graphics type='vnc' port='5909' autoport='no' listen='172.23.0.1' passwd='%s' sharePolicy='allow-exclusive'>\n" \
      "${password}"
    printf "      <listen type='address' address='172.23.0.1'/>\n"
    printf "    </graphics>\n"
  else
    printf '%s\n' "${line}"
  fi
done <"${source_xml}" >"${runtime_xml}"

if [[ "$(grep -c "passwd=" "${runtime_xml}")" -ne 1 ]] ||
   grep -Fq "${vnc_marker}" "${runtime_xml}"; then
  echo "Failed to inject exactly one runtime VNC password." >&2
  exit 1
fi
xmllint --noout "${runtime_xml}"
virsh define "${runtime_xml}" >/dev/null

echo "Termix private network and password-protected Forge VNC definition configured."

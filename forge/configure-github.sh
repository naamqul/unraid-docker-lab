#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly EXPECTED_USER=luqmaan
readonly EXPECTED_LOGIN=naamqul
readonly PAT_REFERENCE='op://Homelab/Github PAT/credential'
: "${OP:=${HOME}/.local/bin/op}"
: "${GH:=/usr/bin/gh}"
readonly OP GH

[[ "$(id -un)" == "${EXPECTED_USER}" ]] || {
  echo "Run this script directly as ${EXPECTED_USER} on Forge." >&2
  exit 1
}
[[ -x "${OP}" && -x "${GH}" ]] || {
  echo "Install the Forge 1Password and GitHub CLIs first." >&2
  exit 1
}

umask 077
temporary_dir="$(mktemp -d)"
temporary_config="${temporary_dir}/hosts.yml"
token=
cleanup() {
  unset token
  rm -f -- "${temporary_config}"
  rmdir -- "${temporary_dir}" 2>/dev/null || true
}
trap cleanup EXIT

token="$("${OP}" read "${PAT_REFERENCE}")"
[[ -n "${token}" ]] || {
  echo "The GitHub PAT field is empty." >&2
  exit 1
}
cat >"${temporary_config}" <<EOF
github.com:
    git_protocol: https
    users:
        ${EXPECTED_LOGIN}:
            oauth_token: ${token}
    oauth_token: ${token}
    user: ${EXPECTED_LOGIN}
EOF

# Validate the 1Password value through an isolated gh configuration before
# replacing the normal one. Forge's gh 2.46 needs both oauth_token entries.
login="$(
  env -u GH_TOKEN -u GITHUB_TOKEN \
    GH_CONFIG_DIR="${temporary_dir}" \
    "${GH}" api user --jq .login
)"
[[ "${login}" == "${EXPECTED_LOGIN}" ]] || {
  echo "The GitHub PAT does not authenticate as ${EXPECTED_LOGIN}." >&2
  exit 1
}
for repo in homelab-agent-docs unraid-docker-lab; do
  name_with_owner="$(
    env -u GH_TOKEN -u GITHUB_TOKEN \
      GH_CONFIG_DIR="${temporary_dir}" \
      "${GH}" repo view "${EXPECTED_LOGIN}/${repo}" \
        --json nameWithOwner \
        --jq .nameWithOwner
  )"
  [[ "${name_with_owner}" == "${EXPECTED_LOGIN}/${repo}" ]] || {
    echo "The GitHub PAT cannot access ${EXPECTED_LOGIN}/${repo}." >&2
    exit 1
  }
done

config_dir="${HOME}/.config/gh"
install -d -m 0700 "${config_dir}"
install -m 0600 "${temporary_config}" "${config_dir}/hosts.yml"
unset token

env -u GH_TOKEN -u GITHUB_TOKEN \
  "${GH}" config set git_protocol https --host github.com
env -u GH_TOKEN -u GITHUB_TOKEN "${GH}" auth setup-git
login="$(
  env -u GH_TOKEN -u GITHUB_TOKEN "${GH}" api user --jq .login
)"
[[ "${login}" == "${EXPECTED_LOGIN}" ]]

stat -c '%U:%G %a %n' "${config_dir}/hosts.yml"
printf 'Authenticated GitHub CLI and HTTPS Git as %s.\n' "${login}"

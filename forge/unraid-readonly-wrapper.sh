#!/usr/bin/bash
set -Eeuo pipefail

if [[ "${1:-}" != --sanitized ]]; then
  command_name="${SSH_ORIGINAL_COMMAND:-}"
  exec /usr/bin/env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    SSH_ORIGINAL_COMMAND="${command_name}" \
    /usr/bin/bash "${BASH_SOURCE[0]}" --sanitized
fi
shift

readonly REPO=/mnt/user/appdata/unraid-docker-lab
readonly command_name="${SSH_ORIGINAL_COMMAND:-}"

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
        -c safe.directory="${REPO}" \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        -c diff.external= \
        -C "${REPO}" "$@"
}

case "${command_name}" in
  host-summary)
    /bin/hostname
    /usr/bin/date -Is
    /usr/bin/uptime
    /usr/bin/free -h
    /usr/bin/df -h /mnt/cache /mnt/user
    ;;

  docker-ps)
    /usr/bin/docker ps \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    ;;

  docker-stats)
    /usr/bin/docker stats --no-stream \
      --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
    ;;

  vm-list)
    /usr/bin/virsh list --all
    ;;

  "vm-info Forge")
    /usr/bin/virsh dominfo Forge
    ;;

  "vm-info Kubuntu")
    /usr/bin/virsh dominfo Kubuntu
    ;;

  "vm-info win11-capture")
    /usr/bin/virsh dominfo win11-capture
    ;;

  repo-status)
    repo_git status --short --branch
    ;;

  repo-diff-stat)
    repo_git diff --stat
    repo_git diff --cached --stat
    ;;

  repo-log)
    repo_git log -n 10 \
      --date=iso-strict \
      --pretty=format:'%h %ad %an %s'
    ;;

  *)
    cat >&2 <<'EOF'
Allowed commands:
  host-summary
  docker-ps
  docker-stats
  vm-list
  vm-info Forge
  vm-info Kubuntu
  vm-info win11-capture
  repo-status
  repo-diff-stat
  repo-log
EOF
    exit 64
    ;;
esac

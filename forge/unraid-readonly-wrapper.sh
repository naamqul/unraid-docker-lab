#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/mnt/user/appdata/unraid-docker-lab"
command_name="${SSH_ORIGINAL_COMMAND:-}"

case "${command_name}" in
  host-summary)
    hostname
    date -Is
    uptime
    free -h
    df -h /mnt/cache /mnt/user
    ;;

  docker-ps)
    docker ps \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    ;;

  docker-stats)
    docker stats --no-stream \
      --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'
    ;;

  vm-list)
    virsh list --all
    ;;

  "vm-info Forge")
    virsh dominfo Forge
    ;;

  "vm-info Kubuntu")
    virsh dominfo Kubuntu
    ;;

  "vm-info win11-capture")
    virsh dominfo win11-capture
    ;;

  repo-status)
    git -C "${REPO}" status --short --branch
    ;;

  repo-diff-stat)
    git -C "${REPO}" diff --stat
    git -C "${REPO}" diff --cached --stat
    ;;

  repo-log)
    git -C "${REPO}" log -n 10 \
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

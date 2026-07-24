#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
  echo "Run this script as root."
  exit 1
}

# Kubuntu 26.04 on this platform has a reproducible fwupd-triggered total
# userspace collapse involving CET user shadow stacks.
install -d -m 0755 /etc/default/grub.d
cat >/etc/default/grub.d/99-forge-usershstk.cfg <<'EOF'
case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
  *" nousershstk "*) ;;
  *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:+${GRUB_CMDLINE_LINUX_DEFAULT} }nousershstk" ;;
esac
EOF

systemctl disable --now fwupd-refresh.timer 2>/dev/null || true
systemctl stop fwupd.service fwupd-refresh.service 2>/dev/null || true
systemctl mask \
  fwupd.service \
  fwupd-refresh.service \
  fwupd-refresh.timer

# Q35's internal iTCO watchdog can remain armed after driver unbind and reset
# the guest. A blacklist alone does not reject an explicit modprobe.
cat >/etc/modprobe.d/99-forge-watchdog-safety.conf <<'EOF'
blacklist iTCO_wdt
install iTCO_wdt /bin/false
blacklist i6300esb
EOF

# Forge uses a plain 2D VirtIO display. Leave Kubuntu's supported Wayland
# greeter/session default intact; Plasma X11 is installed only as a fallback.

# Forge is an always-on workspace, not a laptop.
systemctl mask \
  sleep.target \
  suspend.target \
  hibernate.target \
  hybrid-sleep.target

install -d -m 0755 /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/99-forge-always-on.conf <<'EOF'
[Login]
HandlePowerKey=poweroff
HandlePowerKeyLongPress=poweroff
HandleRebootKey=ignore
HandleRebootKeyLongPress=ignore
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
HandleHibernateKeyLongPress=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

update-grub
update-initramfs -u -k all
systemctl daemon-reload

echo "Forge platform containment applied; reboot after provisioning."

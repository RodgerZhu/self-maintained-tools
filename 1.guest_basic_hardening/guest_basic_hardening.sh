#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./guest_basic_hardening.sh --user USER (--pubkey 'KEY' | --pubkey-file FILE) [--drop-ttyS0-console]

Description:
  Configure a guest OS for key-only SSH access, disable SSH password login,
  lock local passwords, and disable console getty services.

Options:
  --user USER             Target login user. Use root or an existing normal user.
  --pubkey KEY            SSH public key content.
  --pubkey-file FILE      File containing the SSH public key.
  --drop-ttyS0-console    Remove console=ttyS0 from GRUB kernel cmdline and run update-grub.
  -h, --help              Show this help.

Notes:
  - Run this script inside the guest as root.
  - Passwords for root and the target user will be locked, but SSH key login remains available.
  - serial-getty@hvc0 and serial-getty@ttyS0 will be disabled and masked.
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root." >&2
        exit 1
    fi
}

write_managed_sshd_block() {
    local sshd_config="/etc/ssh/sshd_config"
    local temp_file

    temp_file="$(mktemp)"

    awk '
        BEGIN { skip = 0 }
        /^# BEGIN guest_basic_hardening$/ { skip = 1; next }
        /^# END guest_basic_hardening$/ { skip = 0; next }
        skip == 0 { print }
    ' "${sshd_config}" > "${temp_file}"

    cp "${sshd_config}" "${sshd_config}.bak.key-only"

    cat > "${sshd_config}" <<EOF
# BEGIN guest_basic_hardening
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
$(if [[ "${user_name}" == "root" ]]; then echo "PermitRootLogin yes"; else echo "PermitRootLogin no"; fi)
UsePAM yes
# END guest_basic_hardening

EOF

    cat "${temp_file}" >> "${sshd_config}"
    rm -f "${temp_file}"
}

user_name=""
pubkey=""
pubkey_file=""
drop_ttys0_console=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            user_name="${2-}"
            shift 2
            ;;
        --pubkey)
            pubkey="${2-}"
            shift 2
            ;;
        --pubkey-file)
            pubkey_file="${2-}"
            shift 2
            ;;
        --drop-ttyS0-console)
            drop_ttys0_console=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

require_root

if [[ -z "${user_name}" ]]; then
    echo "--user is required." >&2
    usage
    exit 1
fi

if [[ -n "${pubkey}" && -n "${pubkey_file}" ]]; then
    echo "Specify only one of --pubkey or --pubkey-file." >&2
    exit 1
fi

if [[ -z "${pubkey}" && -z "${pubkey_file}" ]]; then
    echo "One of --pubkey or --pubkey-file is required." >&2
    exit 1
fi

if [[ -n "${pubkey_file}" ]]; then
    if [[ ! -f "${pubkey_file}" ]]; then
        echo "Public key file not found: ${pubkey_file}" >&2
        exit 1
    fi
    pubkey="$(<"${pubkey_file}")"
fi

if ! id "${user_name}" >/dev/null 2>&1; then
    echo "User does not exist: ${user_name}" >&2
    exit 1
fi

target_home="/root"
target_group="root"
if [[ "${user_name}" != "root" ]]; then
    target_home="$(getent passwd "${user_name}" | cut -d: -f6)"
    target_group="$(id -gn "${user_name}")"
fi

if [[ -z "${target_home}" || ! -d "${target_home}" ]]; then
    echo "Unable to determine home directory for ${user_name}." >&2
    exit 1
fi

install -d -m 700 -o "${user_name}" -g "${target_group}" "${target_home}/.ssh"
printf '%s\n' "${pubkey}" > "${target_home}/.ssh/authorized_keys"
chown "${user_name}:${target_group}" "${target_home}/.ssh/authorized_keys"
chmod 600 "${target_home}/.ssh/authorized_keys"

install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/90-key-only.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
$(if [[ "${user_name}" == "root" ]]; then echo "PermitRootLogin prohibit-password"; else echo "PermitRootLogin no"; fi)
EOF

write_managed_sshd_block

passwd -l root >/dev/null
if [[ "${user_name}" != "root" ]]; then
    passwd -l "${user_name}" >/dev/null
fi

for service_name in serial-getty@hvc0.service serial-getty@ttyS0.service getty@tty1.service; do
    systemctl disable --now "${service_name}" >/dev/null 2>&1 || true
    systemctl mask "${service_name}" >/dev/null 2>&1 || true
done

if [[ "${drop_ttys0_console}" -eq 1 && -f /etc/default/grub ]]; then
    cp /etc/default/grub /etc/default/grub.bak.key-only
    sed -i -E 's/(^GRUB_CMDLINE_LINUX(_DEFAULT)?="[^"]*) console=ttyS0([^\"]*)"/\1\3"/' /etc/default/grub
    update-grub
fi

if command -v sshd >/dev/null 2>&1; then
    sshd -t
fi

if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl restart ssh
elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl restart sshd
else
    echo "Warning: ssh service not found. Verify SSH server installation manually." >&2
fi

echo "Configuration complete."
echo "Target user: ${user_name}"
echo "SSH password login: disabled"
echo "Console getty: disabled for hvc0, ttyS0, and tty1"
if [[ "${drop_ttys0_console}" -eq 1 ]]; then
    echo "Kernel cmdline: console=ttyS0 removed from GRUB"
fi
if command -v sshd >/dev/null 2>&1; then
    echo "Effective sshd settings:"
    sshd -T | grep -E '^(authenticationmethods|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin) '
fi
echo "Verify SSH key login from another session before closing your current access."
#!/usr/bin/env bash
# One-time (re-runnable) setup of a fresh Ubuntu Server 24.04 host for UltraDoc AI.
#
# Usage (as root, or with sudo, from the account you SSH in with):
#   sudo DEPLOY_USER=deploy scripts/server-setup.sh
#
# What it does (every step is idempotent: safe to run again):
#   1. base packages + unattended security upgrades
#   2. "deploy" user with passwordless sudo and your SSH key
#   3. SSH hardening: key-only login, no root login
#   4. UFW firewall: allow 22, 80, 443 only
#   5. fail2ban for SSH brute force
#   6. Docker Engine (official repo) with log rotation
#   7. Terraform (HashiCorp repo) and AWS CLI v2
#   8. swap file
#   9. /opt/ultradoc directory layout + logrotate
#
# Settings (env vars):
#   DEPLOY_USER   user that runs the app and the GitHub runner (default: deploy)
#   SSH_PUBKEY    public key to authorize; otherwise copied from the sudo
#                 user's ~/.ssh/authorized_keys
#   SWAP_SIZE     swap file size if no swap exists (default: 2G)
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
ULTRADOC_HOME="/opt/ultradoc"
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---- Preflight ---------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
# shellcheck source=/dev/null
. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
  || info "warning: tested on Ubuntu 24.04, this is $PRETTY_NAME"

ARCH="$(dpkg --print-architecture)"   # amd64 / arm64

# ---- 1. Base packages + unattended upgrades ----------------------------------

step "Installing base packages"
apt-get update -q
apt-get install -y -q \
  ca-certificates curl gnupg lsb-release git jq unzip \
  ufw fail2ban python3-systemd \
  unattended-upgrades apt-listchanges logrotate cron

step "Enabling unattended security upgrades"
# Ubuntu's default 50unattended-upgrades already limits itself to the
# -security pocket; this file just switches the daily timer on.
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades >/dev/null

# ---- 2. Deploy user -----------------------------------------------------------

step "Creating user '$DEPLOY_USER'"
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  info "already exists"
else
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi

# The account has no password, so sudo must be passwordless to be usable.
# Validate with visudo before installing: a broken sudoers file locks you out.
sudoers_tmp="$(mktemp)"
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" >"$sudoers_tmp"
visudo -cf "$sudoers_tmp" >/dev/null
install -m 440 "$sudoers_tmp" "/etc/sudoers.d/90-$DEPLOY_USER"
rm -f "$sudoers_tmp"

deploy_home="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$deploy_home/.ssh"
auth_keys="$deploy_home/.ssh/authorized_keys"
touch "$auth_keys"

# Key source: $SSH_PUBKEY, else whoever ran sudo, else root.
if [[ -n "${SSH_PUBKEY:-}" ]]; then
  key_source="$(mktemp)"; echo "$SSH_PUBKEY" >"$key_source"
  trap 'rm -f "$key_source"' EXIT
elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "$DEPLOY_USER" ]]; then
  key_source="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
else
  key_source="/root/.ssh/authorized_keys"
fi
if [[ -s "$key_source" ]]; then
  # Append only keys that aren't there yet (idempotent).
  while IFS= read -r key; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    grep -qxF "$key" "$auth_keys" || echo "$key" >>"$auth_keys"
  done <"$key_source"
fi
chown "$DEPLOY_USER:$DEPLOY_USER" "$auth_keys"
chmod 600 "$auth_keys"
info "$(grep -c . "$auth_keys" || true) key(s) authorized for $DEPLOY_USER"

# ---- 3. SSH hardening ---------------------------------------------------------

step "Hardening SSH"
# sshd keeps the FIRST value it reads for each option and includes
# sshd_config.d/*.conf in name order. Ubuntu ships 50-cloud-init.conf with
# "PasswordAuthentication yes", so this file must sort before it.
ssh_conf=/etc/ssh/sshd_config.d/01-ultradoc-hardening.conf
if [[ -s "$auth_keys" ]]; then
  cat >"$ssh_conf" <<'EOF'
# Managed by scripts/server-setup.sh
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
  sshd -t || die "sshd config test failed; not reloading"
  # 24.04 socket-activates sshd, so the service may not be running yet.
  systemctl try-reload-or-restart ssh
  info "key-only login enabled; root login disabled"
else
  # Guard: turning off passwords with no key installed would lock you out.
  info "SKIPPED: $DEPLOY_USER has no SSH key. Re-run with SSH_PUBKEY=\"ssh-ed25519 ...\""
fi

# ---- 4. Firewall --------------------------------------------------------------

step "Configuring UFW"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw limit 22/tcp comment 'SSH (rate limited)' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw --force enable >/dev/null
# Note: ports published by Docker bypass UFW (Docker writes its own iptables
# rules). Only nginx publishes 80/443; LocalStack binds to 127.0.0.1 only.
ufw status | sed 's/^/    /'

# ---- 5. fail2ban --------------------------------------------------------------

step "Configuring fail2ban"
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
# Managed by scripts/server-setup.sh
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban >/dev/null
systemctl restart fail2ban

# ---- 6. Docker ----------------------------------------------------------------

step "Installing Docker Engine"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  info "already installed: $(docker --version)"
fi

# Default log rotation for every container (Terraform also sets it per container).
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker
fi
systemctl enable --now docker >/dev/null
usermod -aG docker "$DEPLOY_USER"

# ---- 7. Terraform + AWS CLI --------------------------------------------------

step "Installing Terraform"
if ! command -v terraform >/dev/null 2>&1; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $VERSION_CODENAME main" \
    >/etc/apt/sources.list.d/hashicorp.list
  apt-get update -q
  apt-get install -y -q terraform
else
  info "already installed: $(terraform version | head -n1)"
fi

step "Installing AWS CLI v2"
# Not packaged in Ubuntu 24.04's apt repos; use the official installer.
if ! command -v aws >/dev/null 2>&1; then
  case "$ARCH" in
    amd64) aws_arch=x86_64 ;;
    arm64) aws_arch=aarch64 ;;
    *) die "unsupported architecture for AWS CLI: $ARCH" ;;
  esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o "$tmp/awscliv2.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  "$tmp/aws/install"
  rm -rf "$tmp"
else
  info "already installed: $(aws --version)"
fi

# ---- 8. Swap ------------------------------------------------------------------

step "Configuring swap"
# The API loads ONNX models + Chroma; swap keeps a small VM from OOM-killing it.
if swapon --show --noheadings | grep -q .; then
  info "swap already active: $(swapon --show --noheadings | awk '{print $1, $3}')"
else
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  info "created $SWAP_SIZE /swapfile"
fi
echo 'vm.swappiness=10' >/etc/sysctl.d/99-ultradoc.conf
sysctl -q --system

# ---- 9. App directories -------------------------------------------------------

step "Creating $ULTRADOC_HOME layout"
#   app/      git clone of this repo (scripts for cron live here)
#   certs/    TLS cert + key for nginx
#   state/    Terraform state + deployed image tags (contains secrets: 700)
#   backups/  local backup archives
#   logs/     healthcheck / backup logs
install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$ULTRADOC_HOME"
for dir in app certs backups logs; do
  install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$ULTRADOC_HOME/$dir"
done
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$ULTRADOC_HOME/state"

cat >/etc/logrotate.d/ultradoc <<EOF
$ULTRADOC_HOME/logs/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
    su $DEPLOY_USER $DEPLOY_USER
}
EOF

step "Done"
cat <<EOF
    Next steps (as $DEPLOY_USER; log out and back in so the docker group applies):
      ssh $DEPLOY_USER@<vm-ip>
      git clone <your-repo-url> $ULTRADOC_HOME/app
    Then follow "Bring it up on the VM" in README.md.
EOF

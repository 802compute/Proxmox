#!/usr/bin/env bash

# Copyright (c) 2021-2023 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

if [ "$VERBOSE" = "yes" ]; then set -x; STD=""; else STD="silent"; fi
silent() { "$@" > /dev/null 2>&1; }
if [ "$DISABLEIPV6" == "yes" ]; then echo "net.ipv6.conf.all.disable_ipv6 = 1" >>/etc/sysctl.conf; $STD sysctl -p; fi
YW=$(echo "\033[33m")
RD=$(echo "\033[01;31m")
BL=$(echo "\033[36m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
RETRY_NUM=10
RETRY_EVERY=3
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
BFR="\\r\\033[K"
HOLD="-"
set -Eeuo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
}

function msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

msg_info "Setting up Container OS "
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null
for ((i=RETRY_NUM; i>0; i--)); do
  if [ "$(hostname -I)" != "" ]; then
    break
  fi
  echo 1>&2 -en "${CROSS}${RD} No Network! "
  sleep $RETRY_EVERY
done
if [ "$(hostname -I)" = "" ]; then
  echo 1>&2 -e "\n${CROSS}${RD} No Network After $RETRY_NUM Tries${CL}"
  echo -e " 🖧  Check Network Settings"
  exit 1
fi
msg_ok "Set up Container OS"
msg_ok "Network Connected: ${BL}$(hostname -I)"

set +e
trap - ERR
if ping -c 1 -W 1 1.1.1.1 &> /dev/null; then msg_ok "Internet Connected"; else
  msg_error "Internet NOT Connected"
    read -r -p "Would you like to continue anyway? <y/N> " prompt
    if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]; then
      echo -e " ⚠️  ${RD}Expect Issues Without Internet${CL}"
    else
      echo -e " 🖧  Check Network Settings"
      exit 1
    fi
fi
RESOLVEDIP=$(getent hosts github.com | awk '{ print $1 }')
if [[ -z "$RESOLVEDIP" ]]; then msg_error "DNS Lookup Failure"; else msg_ok "DNS Resolved github.com to ${BL}$RESOLVEDIP${CL}"; fi
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

msg_info "Updating Container OS"
$STD apt-get update
$STD apt-get -y upgrade
msg_ok "Updated Container OS"

msg_info "Installing Dependencies"
$STD apt-get update
$STD apt-get -qqy install \
  git \
  build-essential \
  pkgconf \
  libssl-dev \
  libmariadb-dev-compat \
  libpq-dev \
  curl \
  sudo \
  mc
msg_ok "Installed Dependencies"

WEBVAULT=$(curl -s https://api.github.com/repos/dani-garcia/bw_web_builds/releases/latest |
  grep "tag_name" |
  awk '{print substr($2, 2, length($2)-3) }')

VAULT=$(curl -s https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest |
  grep "tag_name" |
  awk '{print substr($2, 2, length($2)-3) }')

msg_info "Installing Rust"
wget -qL https://sh.rustup.rs
$STD bash index.html -y --profile minimal
echo 'export PATH=~/.cargo/bin:$PATH' >>~/.bashrc
export PATH=~/.cargo/bin:$PATH
rm index.html
msg_ok "Installed Rust"

msg_info "Building Vaultwarden ${VAULT} (Patience)"
$STD git clone https://github.com/dani-garcia/vaultwarden
cd vaultwarden
$STD cargo build --features "sqlite,mysql,postgresql" --release
msg_ok "Built Vaultwarden ${VAULT}"

$STD addgroup --system vaultwarden
$STD adduser --system --home /opt/vaultwarden --shell /usr/sbin/nologin --no-create-home --gecos 'vaultwarden' --ingroup vaultwarden --disabled-login --disabled-password vaultwarden
mkdir -p /opt/vaultwarden/bin
mkdir -p /opt/vaultwarden/data
cp target/release/vaultwarden /opt/vaultwarden/bin/

msg_info "Downloading Web-Vault ${WEBVAULT}"
$STD curl -fsSLO https://github.com/dani-garcia/bw_web_builds/releases/download/$WEBVAULT/bw_web_$WEBVAULT.tar.gz
$STD tar -xzf bw_web_$WEBVAULT.tar.gz -C /opt/vaultwarden/
msg_ok "Downloaded Web-Vault ${WEBVAULT}"

cat <<EOF >/opt/vaultwarden/.env
ADMIN_TOKEN=$(openssl rand -base64 48)
ROCKET_ADDRESS=0.0.0.0
DATA_FOLDER=/opt/vaultwarden/data
DATABASE_MAX_CONNS=10
WEB_VAULT_FOLDER=/opt/vaultwarden/web-vault
WEB_VAULT_ENABLED=true
EOF

msg_info "Creating Service"
chown -R vaultwarden:vaultwarden /opt/vaultwarden/
chown root:root /opt/vaultwarden/bin/vaultwarden
chmod +x /opt/vaultwarden/bin/vaultwarden
chown -R root:root /opt/vaultwarden/web-vault/
chmod +r /opt/vaultwarden/.env

service_path="/etc/systemd/system/vaultwarden.service"
echo "[Unit]
Description=Bitwarden Server (Powered by Vaultwarden)
Documentation=https://github.com/dani-garcia/vaultwarden
After=network.target
[Service]
User=vaultwarden
Group=vaultwarden
EnvironmentFile=-/opt/vaultwarden/.env
ExecStart=/opt/vaultwarden/bin/vaultwarden
LimitNOFILE=65535
LimitNPROC=4096
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
DevicePolicy=closed
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictNamespaces=yes
RestrictRealtime=yes
MemoryDenyWriteExecute=yes
LockPersonality=yes
WorkingDirectory=/opt/vaultwarden
ReadWriteDirectories=/opt/vaultwarden/data
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target" >$service_path
systemctl daemon-reload
$STD systemctl enable --now vaultwarden.service
msg_ok "Created Service"

echo "export TERM='xterm-256color'" >>/root/.bashrc
echo -e "$APPLICATION LXC provided by https://tteck.github.io/Proxmox/\n" > /etc/motd
chmod -x /etc/update-motd.d/*
if ! getent shadow root | grep -q "^root:[^\!*]"; then
  msg_info "Customizing Container"
  GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
  mkdir -p $(dirname $GETTY_OVERRIDE)
  cat <<EOF >$GETTY_OVERRIDE
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
  systemctl daemon-reload
  systemctl restart $(basename $(dirname $GETTY_OVERRIDE) | sed 's/\.d//')
  msg_ok "Customized Container"
fi
if [[ "${SSH_ROOT}" == "yes" ]]; then sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/g" /etc/ssh/sshd_config; systemctl restart sshd; fi

msg_info "Cleaning up"
$STD apt-get autoremove
$STD apt-get autoclean
msg_ok "Cleaned"

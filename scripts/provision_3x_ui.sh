#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST="" SSH_PORT=22 SSH_USER=root
PANEL_PORT="" VLESS_PORT="" SOCKS_PORT="" OUTPUT_DIR=""
DRY_RUN=false
RESUME=false

usage() {
  cat <<'EOF'
Usage: provision_3x_ui.sh --host HOST [options]

Required:
  --host HOST             Server IP address or DNS name

Options:
  --ssh-port PORT         SSH port (default: 22)
  --ssh-user USER         SSH user (default: root)
  --panel-port PORT       Preferred panel port for a new installation
  --vless-port PORT       Preferred VLESS TCP port
  --socks-port PORT       Preferred SOCKS5 port
  --output-dir DIR        Directory for result.json and the QR PNG
  --dry-run               Validate inputs and show planned work only
  --resume                Resume the latest unfinished codex-* inbounds
  -h, --help              Show help

Set PROVISION_SSH_PASSWORD or run interactively for a silent password prompt.
Never put the SSH password in a command argument.
EOF
}

log() { printf '[provision-3x-ui] %s\n' "$*" >&2; }
fail() {
  jq -n --arg stage "$1" --arg message "$2" --arg status "${4:-blocked}" \
    '{status:$status,stage:$stage,message:$message}'
  exit "${3:-1}"
}
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

while (( $# )); do
  case "$1" in
    --host) HOST=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    --ssh-user) SSH_USER=${2:-}; shift 2 ;;
    --panel-port) PANEL_PORT=${2:-}; shift 2 ;;
    --vless-port) VLESS_PORT=${2:-}; shift 2 ;;
    --socks-port) SOCKS_PORT=${2:-}; shift 2 ;;
    --output-dir) OUTPUT_DIR=${2:-}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --resume) RESUME=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail arguments "Unknown argument: $1" 64 ;;
  esac
done

[[ -n $HOST ]] || { usage >&2; fail arguments "--host is required" 64; }
valid_port "$SSH_PORT" || fail arguments "Invalid SSH port: $SSH_PORT" 64
[[ -n $SSH_USER && $SSH_USER != *[[:space:]]* ]] || fail arguments "Invalid SSH user" 64
for port in "$PANEL_PORT" "$VLESS_PORT" "$SOCKS_PORT"; do
  [[ -z $port ]] || valid_port "$port" || fail arguments "Invalid port: $port" 64
done
for command_name in bash curl jq ssh base64 perl; do
  command -v "$command_name" >/dev/null 2>&1 || fail prerequisites "$command_name is required" 69
done

if $DRY_RUN; then
  jq -n --arg host "$HOST" --argjson sshPort "$SSH_PORT" --arg sshUser "$SSH_USER" \
    --arg panelPort "${PANEL_PORT:-automatic}" --arg vlessPort "${VLESS_PORT:-automatic}" \
    --arg socksPort "${SOCKS_PORT:-automatic}" \
    '{status:"dry_run",target:{host:$host,sshPort:$sshPort,sshUser:$sshUser},requestedPorts:{panel:$panelPort,vless:$vlessPort,socks5:$socksPort},planned:["verify SSH and prerequisites","reuse 3X-UI or install it when absent","create independent VLESS TCP and SOCKS5 inbounds","test real traffic through both proxies","generate a VLESS QR PNG and delivery JSON"]}'
  exit 0
fi

if [[ -z ${PROVISION_SSH_PASSWORD:-} ]]; then
  [[ -t 0 ]] || fail credentials "Set PROVISION_SSH_PASSWORD or run interactively" 64
  read -r -s -p "SSH password for ${SSH_USER}@${HOST}: " PROVISION_SSH_PASSWORD
  printf '\n' >&2
fi
[[ -n $PROVISION_SSH_PASSWORD ]] || fail credentials "SSH password cannot be empty" 64
export PROVISION_SSH_PASSWORD

umask 077
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/provision-3x-ui.XXXXXX")
KNOWN_HOSTS="$WORK_DIR/known_hosts"
COOKIE_JAR="$WORK_DIR/panel.cookies"
XRAY_PID=""
cleanup() {
  if [[ -n $XRAY_PID ]]; then
    kill "$XRAY_PID" 2>/dev/null || true
    wait "$XRAY_PID" 2>/dev/null || true
  fi
  unset PROVISION_SSH_PASSWORD
  find "$WORK_DIR" -type f -delete 2>/dev/null || true
  find "$WORK_DIR" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ssh_exec() {
  "$SCRIPT_DIR/ssh_with_password.exp" \
    "$HOST" "$SSH_PORT" "$SSH_USER" "$KNOWN_HOSTS" 300 "$1"
}

log "Checking SSH access and root privileges"
ssh_exec "test \"\$(id -u)\" -eq 0" >/dev/null || \
  fail ssh "SSH login failed or the SSH user is not root" 77

cat > "$WORK_DIR/bootstrap.sh" <<'REMOTE_BOOTSTRAP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
installed=false
if command -v x-ui >/dev/null 2>&1 || [[ -x /usr/local/x-ui/x-ui ]]; then installed=true; fi

if ! $installed; then
  . /etc/os-release 2>/dev/null || true
  case "${ID:-}" in
    ubuntu|debian|centos|rhel|almalinux|rocky|fedora|arch) ;;
    *) echo "Unsupported Linux distribution: ${ID:-unknown}" >&2; exit 65 ;;
  esac
  available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
  swap_kb=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
  free_disk_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  (( free_disk_kb >= 1572864 )) || { echo "At least 1.5 GB free disk is required" >&2; exit 70; }
  if (( available_kb < 524288 && swap_kb == 0 )); then
    if command -v fallocate >/dev/null 2>&1; then fallocate -l 1G /swapfile
    else dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
  if [[ ${ID:-} == ubuntu || ${ID:-} == debian ]]; then
    printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99-3x-ui-ipv4
  fi
  public_ip=$(curl -4fsS --connect-timeout 10 --max-time 20 https://api.ipify.org)
  export XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=ip XUI_SERVER_IP="$public_ip"
  [[ -z ${REQUESTED_PANEL_PORT:-} ]] || export XUI_PORT="$REQUESTED_PANEL_PORT"
  curl -4fsSL --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh | bash
fi

systemctl enable x-ui >/dev/null 2>&1 || true
systemctl restart x-ui
for _ in $(seq 1 30); do systemctl is-active --quiet x-ui && break; sleep 1; done
systemctl is-active --quiet x-ui || { echo "x-ui service did not become active" >&2; exit 71; }
if [[ -r /etc/x-ui/install-result.env ]]; then
  sed -n '/^XUI_[A-Z_]*=/p' /etc/x-ui/install-result.env
fi
if [[ -x /usr/local/x-ui/x-ui ]]; then /usr/local/x-ui/x-ui setting -show true
else x-ui setting -show true; fi
REMOTE_BOOTSTRAP

bootstrap_encoded=$(base64 < "$WORK_DIR/bootstrap.sh" | tr -d '\n')
panel_prefix=""
[[ -z $PANEL_PORT ]] || panel_prefix="REQUESTED_PANEL_PORT=$PANEL_PORT "
log "Reusing 3X-UI, or installing it when absent"
if ! SETTINGS_OUTPUT=$(ssh_exec "${panel_prefix}bash -c \"printf '%s' '$bootstrap_encoded' | base64 -d | bash\""); then
  fail installation "3X-UI installation or service startup failed" 70
fi
SETTINGS_OUTPUT=$(printf '%s\n' "$SETTINGS_OUTPUT" | tr -d '\r' | sed $'s/\033\[[0-9;]*m//g')
setting_value() {
  printf '%s\n' "$SETTINGS_OUTPUT" | awk -v key="$1" '
    index(tolower($0), tolower(key) ":") == 1 {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}'
}
env_value() {
  printf '%s\n' "$SETTINGS_OUTPUT" | awk -F= -v key="$1" \
    '$1 == key {sub(/^[^=]*=/, ""); print; exit}'
}
PANEL_USERNAME=$(env_value XUI_USERNAME); PANEL_USERNAME=${PANEL_USERNAME:-$(setting_value Username)}
PANEL_PASSWORD=$(env_value XUI_PASSWORD); PANEL_PASSWORD=${PANEL_PASSWORD:-$(setting_value Password)}
PANEL_PORT_ACTUAL=$(env_value XUI_PANEL_PORT); PANEL_PORT_ACTUAL=${PANEL_PORT_ACTUAL:-$(setting_value Port)}
WEB_BASE_PATH=$(env_value XUI_WEB_BASE_PATH); WEB_BASE_PATH=${WEB_BASE_PATH:-$(setting_value WebBasePath)}
PANEL_URL=$(env_value XUI_ACCESS_URL); PANEL_URL=${PANEL_URL:-$(setting_value "Access URL")}
API_TOKEN=$(env_value XUI_API_TOKEN); API_TOKEN=${API_TOKEN:-$(setting_value "API Token")}
[[ -n $PANEL_USERNAME && -n $PANEL_PASSWORD ]] || \
  fail panel_settings "Could not read panel credentials from 3X-UI" 71
valid_port "$PANEL_PORT_ACTUAL" || fail panel_settings "Could not read the panel port" 71

WEB_BASE_PATH=${WEB_BASE_PATH#/}; WEB_BASE_PATH=${WEB_BASE_PATH%/}
if [[ -z $PANEL_URL ]]; then
  path_suffix=""; [[ -z $WEB_BASE_PATH ]] || path_suffix="/$WEB_BASE_PATH"
  for scheme in https http; do
    candidate="${scheme}://${HOST}:${PANEL_PORT_ACTUAL}${path_suffix}"
    if curl -kfsS --connect-timeout 10 --max-time 20 "$candidate/" >/dev/null; then
      PANEL_URL=$candidate; break
    fi
  done
fi
PANEL_URL=${PANEL_URL%/}
[[ $PANEL_URL == http://* || $PANEL_URL == https://* ]] || \
  fail panel_settings "Could not determine the panel URL" 71

log "Checking panel reachability and TLS"
PANEL_HTTP_OK=false PANEL_TLS_OK=false
curl -kfsS --connect-timeout 10 --max-time 20 "$PANEL_URL/" >/dev/null && PANEL_HTTP_OK=true
$PANEL_HTTP_OK || fail panel_verification "The panel is not reachable at its reported URL" 71
if [[ $PANEL_URL == https://* ]] && curl -fsS --connect-timeout 10 --max-time 20 "$PANEL_URL/" >/dev/null; then
  PANEL_TLS_OK=true
fi

api_get() {
  curl -kfsS --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $API_TOKEN" \
    -H 'Accept: application/json' "$PANEL_URL/panel/api/$1"
}
api_post() {
  curl -kfsS --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $API_TOKEN" \
    -H 'Content-Type: application/json' --data-binary "$2" "$PANEL_URL/panel/api/$1"
}

if [[ -z $API_TOKEN ]] || ! api_get server/status | jq -e '.success == true' >/dev/null 2>&1; then
  log "Creating a dedicated API token through the panel session"
  login_body=$(jq -n --arg u "$PANEL_USERNAME" --arg p "$PANEL_PASSWORD" \
    '{username:$u,password:$p,twoFactorCode:""}')
  login_response=$(curl -kfsS -c "$COOKIE_JAR" -H 'Content-Type: application/json' \
    --data-binary "$login_body" "$PANEL_URL/login") || fail authentication "Panel login request failed" 77
  jq -e '.success == true' <<< "$login_response" >/dev/null || \
    fail authentication "Panel login failed; 2FA may require manual action" 77
  csrf_response=$(curl -kfsS -b "$COOKIE_JAR" "$PANEL_URL/csrf-token") || \
    fail authentication "Could not obtain a CSRF token" 77
  csrf_token=$(jq -r '.obj // empty' <<< "$csrf_response")
  [[ -n $csrf_token ]] || fail authentication "Panel returned an empty CSRF token" 77
  token_name="codex-$(date -u +%Y%m%d-%H%M%S)-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 5 || true)"
  token_response=$(curl -kfsS -b "$COOKIE_JAR" -H "X-CSRF-Token: $csrf_token" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -n --arg name "$token_name" '{name:$name}')" \
    "$PANEL_URL/panel/api/setting/apiTokens/create") || \
    fail authentication "API token creation request failed" 77
  API_TOKEN=$(jq -r 'select(.success == true) | .obj.token // empty' <<< "$token_response")
  [[ -n $API_TOKEN ]] || fail authentication "3X-UI did not return an API token" 77
fi

INBOUNDS_RESPONSE=$(api_get inbounds/list) || fail api "Could not list inbounds" 72
jq -e '.success == true and (.obj | type == "array")' <<< "$INBOUNDS_RESPONSE" >/dev/null || \
  fail api "3X-UI returned an invalid inbound list" 72
PENDING_VLESS=$(jq -c --argjson resume "$RESUME" '
  .obj as $all
  | [$all[]
      | select(.protocol == "vless")
      | select(.remark | startswith("codex-vless-"))
      | . as $v
      | ($v.remark | ltrimstr("codex-vless-")) as $suffix
      | select($resume or (([$all[] | select(.remark == ("codex-socks-" + $suffix))] | length) == 0))
      | select((.clientStats // []) | any(.email | startswith("codex-client-")))
    ]
  | sort_by(.id)
  | last // null' <<< "$INBOUNDS_RESPONSE")
remote_port_free() {
  ! ssh_exec "ss -H -lntup 2>/dev/null | awk '{print \$5}' | grep -Eq '(^|:)$1$'" >/dev/null
}
api_port_free() { ! jq -e --argjson port "$1" '.obj[] | select(.port == $port)' <<< "$INBOUNDS_RESPONSE" >/dev/null; }
choose_port() {
  local preferred=$1 candidate
  if [[ -n $preferred ]] && api_port_free "$preferred" && remote_port_free "$preferred"; then
    printf '%s\n' "$preferred"; return
  fi
  for _ in $(seq 1 80); do
    candidate=$(( 20000 + $(od -An -N4 -tu4 /dev/urandom) % 40000 ))
    if api_port_free "$candidate" && remote_port_free "$candidate"; then printf '%s\n' "$candidate"; return; fi
  done
  return 1
}

REUSE_VLESS=false
if [[ $PENDING_VLESS != null ]]; then
  REUSE_VLESS=true
  VLESS_INBOUND_ID=$(jq -r '.id' <<< "$PENDING_VLESS")
  VLESS_PORT_ACTUAL=$(jq -r '.port' <<< "$PENDING_VLESS")
  VLESS_REMARK=$(jq -r '.remark' <<< "$PENDING_VLESS")
  VLESS_CLIENT=$(jq -r '[.clientStats[] | select(.email | startswith("codex-client-")) | .email] | first' <<< "$PENDING_VLESS")
  suffix=${VLESS_REMARK#codex-vless-}
else
  VLESS_PORT_ACTUAL=$(choose_port "$VLESS_PORT") || fail ports "Could not find a free VLESS port" 73
  suffix="$(date -u +%Y%m%d%H%M%S)-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 5 || true)"
  VLESS_REMARK="codex-vless-$suffix"
  VLESS_CLIENT="codex-client-$suffix"
fi
SOCKS_REMARK="codex-socks-$suffix"
EXISTING_SOCKS=$(jq -c --arg remark "$SOCKS_REMARK" \
  '[.obj[] | select(.remark == $remark and .protocol == "mixed")] | sort_by(.id) | last // null' \
  <<< "$INBOUNDS_RESPONSE")
REUSE_SOCKS=false
if $RESUME && [[ $EXISTING_SOCKS != null ]]; then
  REUSE_SOCKS=true
  SOCKS_INBOUND_ID=$(jq -r '.id' <<< "$EXISTING_SOCKS")
  SOCKS_PORT_ACTUAL=$(jq -r '.port' <<< "$EXISTING_SOCKS")
  SOCKS_USERNAME=$(jq -r '.settings.accounts[0].user // empty' <<< "$EXISTING_SOCKS")
  SOCKS_PASSWORD=$(jq -r '.settings.accounts[0].pass // empty' <<< "$EXISTING_SOCKS")
  [[ -n $SOCKS_USERNAME && -n $SOCKS_PASSWORD ]] || fail socks_resume "Could not read the existing SOCKS5 credentials" 75 partial
else
  SOCKS_PORT_ACTUAL=$(choose_port "$SOCKS_PORT") || fail ports "Could not find a free SOCKS5 port" 73
  while [[ $SOCKS_PORT_ACTUAL == "$VLESS_PORT_ACTUAL" ]]; do
    SOCKS_PORT_ACTUAL=$(choose_port "") || fail ports "Could not find distinct proxy ports" 73
  done
  SOCKS_USERNAME="socks_$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 10 || true)"
  SOCKS_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)
fi

if $REUSE_VLESS; then
  log "Resuming the pending VLESS TCP inbound"
else
  log "Creating VLESS TCP"
  vless_payload=$(jq -n --arg remark "$VLESS_REMARK" --arg host "$HOST" \
    --argjson port "$VLESS_PORT_ACTUAL" \
    '{enable:true,remark:$remark,listen:"",port:$port,protocol:"vless",expiryTime:0,total:0,trafficReset:"never",subSortIndex:1,shareAddrStrategy:"custom",shareAddr:$host,settings:{clients:[],decryption:"none",encryption:"none",fallbacks:[]},streamSettings:{network:"tcp",security:"none",tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}},sniffing:{enabled:false}}')
  vless_add=$(api_post inbounds/add "$vless_payload") || fail vless_create "VLESS inbound request failed" 74
  jq -e '.success == true' <<< "$vless_add" >/dev/null || fail vless_create "3X-UI rejected the VLESS inbound" 74
  INBOUNDS_RESPONSE=$(api_get inbounds/list)
  VLESS_INBOUND_ID=$(jq -r --arg remark "$VLESS_REMARK" \
    '.obj[] | select(.remark == $remark and .protocol == "vless") | .id' <<< "$INBOUNDS_RESPONSE" | tail -n 1)
  [[ $VLESS_INBOUND_ID =~ ^[0-9]+$ ]] || fail vless_create "Could not find the new VLESS inbound" 74 partial
  client_payload=$(jq -n --arg email "$VLESS_CLIENT" --argjson inboundId "$VLESS_INBOUND_ID" \
    '{client:{email:$email,totalGB:0,expiryTime:0,tgId:0,limitIp:0,enable:true,comment:"",reset:0,security:"auto",flow:""},inboundIds:[$inboundId]}')
  client_add=$(api_post clients/add "$client_payload") || fail vless_create "VLESS client request failed" 74 partial
  jq -e '.success == true' <<< "$client_add" >/dev/null || fail vless_create "3X-UI rejected the VLESS client" 74 partial
fi
client_response=$(api_get "clients/get/$VLESS_CLIENT") || fail vless_create "Could not retrieve the VLESS client" 74 partial
VLESS_UUID=$(jq -r '.obj.uuid // .obj.client.uuid // (if (.obj.id | type) == "string" then .obj.id else empty end) // empty' <<< "$client_response")
[[ $VLESS_UUID =~ ^[0-9a-fA-F-]{36}$ ]] || fail vless_create "The VLESS UUID is missing" 74 partial
links_response=$(api_get "clients/links/$VLESS_CLIENT") || fail vless_create "Could not retrieve the VLESS URL" 74 partial
VLESS_URL=$(jq -r '.obj[]? | select(startswith("vless://"))' <<< "$links_response" | head -n 1)
[[ $VLESS_URL == vless://* ]] || fail vless_create "3X-UI returned no VLESS URL" 74 partial

if $REUSE_SOCKS; then
  log "Resuming the existing authenticated SOCKS5-compatible mixed inbound"
else
  log "Creating authenticated SOCKS5-compatible mixed inbound"
  socks_payload=$(jq -n --arg remark "$SOCKS_REMARK" --arg host "$HOST" \
    --arg user "$SOCKS_USERNAME" --arg pass "$SOCKS_PASSWORD" --argjson port "$SOCKS_PORT_ACTUAL" \
    '{enable:true,remark:$remark,listen:"",port:$port,protocol:"mixed",expiryTime:0,total:0,trafficReset:"never",subSortIndex:1,shareAddrStrategy:"custom",shareAddr:$host,settings:{auth:"password",accounts:[{user:$user,pass:$pass}],udp:false,ip:"0.0.0.0"},streamSettings:null,sniffing:{enabled:false}}')
  socks_add=$(api_post inbounds/add "$socks_payload") || fail socks_create "SOCKS5 inbound request failed" 75 partial
  jq -e '.success == true' <<< "$socks_add" >/dev/null || fail socks_create "3X-UI rejected the SOCKS5 inbound" 75 partial
  INBOUNDS_RESPONSE=$(api_get inbounds/list)
  SOCKS_INBOUND_ID=$(jq -r --arg remark "$SOCKS_REMARK" \
    '.obj[] | select(.remark == $remark and .protocol == "mixed") | .id' <<< "$INBOUNDS_RESPONSE" | tail -n 1)
  [[ $SOCKS_INBOUND_ID =~ ^[0-9]+$ ]] || fail socks_create "Could not find the new SOCKS5 inbound" 75 partial
fi

EXPECTED_IP=$(ssh_exec "curl -4fsS --connect-timeout 10 --max-time 20 https://api.ipify.org") || \
  fail verification "Could not determine the server public IP" 76 partial
EXPECTED_IP=$(printf '%s\n' "$EXPECTED_IP" | tr -d '\r' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -n 1)
[[ -n $EXPECTED_IP ]] || fail verification "The server returned no valid public IPv4 address" 76 partial

log "Testing real SOCKS5 traffic"
SOCKS_TEST_IP=""
for _ in $(seq 1 20); do
  SOCKS_TEST_IP=$(curl -4fsS --connect-timeout 10 --max-time 25 \
    --socks5-hostname "$HOST:$SOCKS_PORT_ACTUAL" --proxy-user "$SOCKS_USERNAME:$SOCKS_PASSWORD" \
    https://api.ipify.org 2>/dev/null || true)
  [[ $SOCKS_TEST_IP == "$EXPECTED_IP" ]] && break
  sleep 2
done
[[ $SOCKS_TEST_IP == "$EXPECTED_IP" ]] || \
  fail socks_verification "SOCKS5 traffic failed; check the host firewall or provider security group" 76 partial

find_xray() {
  if command -v xray >/dev/null 2>&1; then command -v xray; return; fi
  local os arch archive
  case $(uname -s) in Darwin) os=macos ;; Linux) os=linux ;; *) return 1 ;; esac
  case $(uname -m) in x86_64|amd64) arch=64 ;; arm64|aarch64) arch=arm64-v8a ;; *) return 1 ;; esac
  archive="$WORK_DIR/xray.zip"
  curl -fL --connect-timeout 15 --max-time 180 -o "$archive" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-${os}-${arch}.zip" >/dev/null 2>&1 || return 1
  command -v unzip >/dev/null 2>&1 || return 1
  unzip -qq "$archive" xray -d "$WORK_DIR/xray-bin" || return 1
  chmod 700 "$WORK_DIR/xray-bin/xray"
  printf '%s\n' "$WORK_DIR/xray-bin/xray"
}

log "Testing real VLESS traffic"
XRAY_BIN=$(find_xray) || fail vless_verification "Could not obtain a local Xray client" 76 partial
LOCAL_SOCKS_PORT=$(( 30000 + $(od -An -N4 -tu4 /dev/urandom) % 20000 ))
jq -n --arg host "$HOST" --arg uuid "$VLESS_UUID" --argjson remotePort "$VLESS_PORT_ACTUAL" \
  --argjson localPort "$LOCAL_SOCKS_PORT" \
  '{log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$localPort,protocol:"socks",settings:{auth:"noauth",udp:false}}],outbounds:[{protocol:"vless",settings:{vnext:[{address:$host,port:$remotePort,users:[{id:$uuid,encryption:"none"}]}]},streamSettings:{network:"tcp",security:"none"}}]}' \
  > "$WORK_DIR/xray-client.json"
chmod 600 "$WORK_DIR/xray-client.json"
"$XRAY_BIN" run -config "$WORK_DIR/xray-client.json" >"$WORK_DIR/xray.log" 2>&1 & XRAY_PID=$!
VLESS_TEST_IP=""
for _ in $(seq 1 20); do
  kill -0 "$XRAY_PID" 2>/dev/null || break
  VLESS_TEST_IP=$(curl -4fsS --connect-timeout 10 --max-time 25 \
    --socks5-hostname "127.0.0.1:$LOCAL_SOCKS_PORT" https://api.ipify.org 2>/dev/null || true)
  [[ $VLESS_TEST_IP == "$EXPECTED_IP" ]] && break
  sleep 2
done
kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true; XRAY_PID=""
[[ $VLESS_TEST_IP == "$EXPECTED_IP" ]] || \
  fail vless_verification "VLESS traffic failed; check the host firewall or provider security group" 76 partial

if [[ -z $OUTPUT_DIR ]]; then
  safe_host=${HOST//[^A-Za-z0-9._-]/_}
  OUTPUT_DIR="$PWD/provision-3x-ui-output/${safe_host}-$(date -u +%Y%m%d-%H%M%S)"
elif [[ $OUTPUT_DIR != /* ]]; then OUTPUT_DIR="$PWD/$OUTPUT_DIR"; fi
mkdir -p "$OUTPUT_DIR"; chmod 700 "$OUTPUT_DIR"
QR_PATH="$OUTPUT_DIR/vless-qr.png"
"$SCRIPT_DIR/generate_vless_qr.sh" "$VLESS_URL" "$QR_PATH" >/dev/null || \
  fail qr "VLESS works, but QR generation failed" 70 partial
SERVICE_ACTIVE=$(ssh_exec "systemctl is-active x-ui")
SERVICE_ENABLED=$(ssh_exec "systemctl is-enabled x-ui" 2>/dev/null || true)
SERVICE_ACTIVE=$(printf '%s\n' "$SERVICE_ACTIVE" | tr -d '\r' | awk 'NF {value=$0} END {print value}')
SERVICE_ENABLED=$(printf '%s\n' "$SERVICE_ENABLED" | tr -d '\r' | awk 'NF {value=$0} END {print value}')
[[ $SERVICE_ACTIVE == active ]] || fail service_verification "x-ui is not active" 76 partial
[[ $SERVICE_ENABLED == enabled ]] || fail service_verification "x-ui is not enabled at boot" 76 partial

DELIVERY_STATUS=completed
PANEL_WARNING=""
if [[ $PANEL_URL == https://* && $PANEL_TLS_OK != true ]]; then
  DELIVERY_STATUS=partial
  PANEL_WARNING="The panel reports HTTPS, but strict TLS certificate validation failed."
elif [[ $PANEL_URL == http://* ]]; then
  PANEL_WARNING="The panel uses unencrypted HTTP."
fi

RESULT_PATH="$OUTPUT_DIR/result.json"
jq -n --arg status "$DELIVERY_STATUS" --arg panelWarning "$PANEL_WARNING" \
  --arg panelUrl "$PANEL_URL" --arg panelUsername "$PANEL_USERNAME" \
  --arg panelPassword "$PANEL_PASSWORD" --arg apiToken "$API_TOKEN" --arg server "$HOST" \
  --arg vlessUuid "$VLESS_UUID" --arg vlessUrl "$VLESS_URL" --arg socksUsername "$SOCKS_USERNAME" \
  --arg socksPassword "$SOCKS_PASSWORD" --arg qrPath "$QR_PATH" --arg expectedIp "$EXPECTED_IP" \
  --argjson panelPort "$PANEL_PORT_ACTUAL" --argjson vlessPort "$VLESS_PORT_ACTUAL" \
  --argjson socksPort "$SOCKS_PORT_ACTUAL" --argjson vlessInboundId "$VLESS_INBOUND_ID" \
  --argjson socksInboundId "$SOCKS_INBOUND_ID" --argjson panelHttp "$PANEL_HTTP_OK" \
  --argjson panelTls "$PANEL_TLS_OK" \
  '{status:$status,panel:{url:$panelUrl,port:$panelPort,username:$panelUsername,password:$panelPassword,apiToken:$apiToken},vless:{server:$server,port:$vlessPort,uuid:$vlessUuid,url:$vlessUrl,inboundId:$vlessInboundId,qrPng:$qrPath},socks5:{server:$server,port:$socksPort,username:$socksUsername,password:$socksPassword,inboundId:$socksInboundId},verification:{serviceActive:true,serviceEnabled:true,panelHttp:$panelHttp,panelTls:$panelTls,vless:{passed:true,exitIp:$expectedIp},socks5:{passed:true,exitIp:$expectedIp}},warnings:(["VLESS over plain TCP has no transport encryption.","SOCKS5 authentication does not encrypt proxy traffic."] + (if $panelWarning == "" then [] else [$panelWarning] end))}' \
  | tee "$RESULT_PATH"
chmod 600 "$RESULT_PATH"
log "Completed; delivery JSON: $RESULT_PATH"

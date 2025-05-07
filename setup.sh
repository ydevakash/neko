#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run this script as root"; exit 99; }

TMPBASE="/tmp/neko"                          
STATE_FILE="$TMPBASE/state"                   
SENTINEL_DIR="$TMPBASE/sentinels"           
mkdir -p "$SENTINEL_DIR"

msg()  { printf "\033[1;32m▶ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m✖ %s\033[0m\n" "$*"; exit 1; }
backup(){ [[ -f $1 && ! -f $1.orig ]] && cp "$1" "$1.orig"; }

detect_rfcomm_port () {
  local mac="$1" port=""
  port=$(sdptool search --bdaddr "$mac" HEADSET 2>/dev/null | awk '/Channel/ {print $NF; exit}')
  [[ -z $port ]] && port=$(sdptool search --bdaddr "$mac" SP      2>/dev/null | awk '/Channel/ {print $NF; exit}')
  if [[ -z $port ]]; then
    for ch in {1..30}; do
      timeout 3 rfcomm connect "$BT_ADAPTER" "$mac" "$ch" &>/dev/null && { port=$ch; rfcomm release "$BT_ADAPTER" "$ch" &>/dev/null; break; }
    done
  fi
  [[ -z $port ]] && port=1       
  echo "$port"
}

ask () { # ask <var> <prompt> <default>
  local __var=$1 __q=$2 __def=$3
  if [[ -z "${!__var:-}" ]]; then
    if $NONINTERACTIVE; then
      ans="$__def"
    else
      read -r -p "$__q [${__def}]: " ans || true
      [[ -z "$ans" ]] && ans="$__def"
    fi
    printf -v "$__var" %s "$ans"
  fi
}

save_state () {       # persist env vars to STATE_FILE
  mkdir -p "$TMPBASE"
  cat > "$STATE_FILE" <<EOF
ASTERISK_VER="$ASTERISK_VER"
AMI_USER="$AMI_USER"
AMI_SECRET="$AMI_SECRET"
BT_ADAPTER="$BT_ADAPTER"
OUT_CONTEXT="$OUT_CONTEXT"
IN_CONTEXT="$IN_CONTEXT"
BUILD_PARENT="$BUILD_PARENT"
EOF
}

load_state (){ [[ -f $STATE_FILE ]] && source "$STATE_FILE"; }
need_step (){ [[ ! -e "$SENTINEL_DIR/$1" ]]; }
done_step (){ touch "$SENTINEL_DIR/$1"; }

# FLAG PARSING
NONINTERACTIVE=false
FORCE_RECONF=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes)      NONINTERACTIVE=true ;;
    --reconfigure) FORCE_RECONF=true   ;;
    *)             err "Unknown flag: $arg" ;;
  esac
done

# COLLECT / LOAD VARIABLES
load_state
$FORCE_RECONF && unset ASTERISK_VER AMI_USER AMI_SECRET BT_ADAPTER OUT_CONTEXT IN_CONTEXT BUILD_PARENT

ask ASTERISK_VER "Asterisk branch to build"          "20"
ask AMI_USER     "AMI username"                      "neko"
ask AMI_SECRET   "AMI secret"                        "neko"
ask BT_ADAPTER   "Bluetooth adapter"                 "hci0"
ask OUT_CONTEXT  "Outbound dialplan context"         "neko_out"
ask IN_CONTEXT   "Inbound dialplan context"          "neko_in"
ask BUILD_PARENT "Source download directory"         "/usr/src/neko"

BUILD_DIR="${BUILD_PARENT%/}/asterisk-${ASTERISK_VER}"
save_state

# PREREQUISITES
if need_step "packages"; then
  msg "Installing prerequisite packages…"
  apt-get update -qq
  DEPS=(build-essential git wget usbutils bluetooth bluez rfkill
        libusb-dev libbluetooth-dev libnewt-dev libssl-dev libsqlite3-dev
        libjansson-dev libedit-dev uuid-dev pkg-config expect)
  apt-get install -y "${DEPS[@]}"
  done_step "packages"
fi

# SYSTEM USER & GROUPS
if need_step "asterisk-user"; then
  id -u asterisk &>/dev/null || adduser --system --group --home /var/lib/asterisk asterisk
  usermod -aG dialout,bluetooth asterisk || true
  done_step "asterisk-user"
fi


#  DOWNLOAD SOURCE

if need_step "download"; then
  msg "Downloading Asterisk ${ASTERISK_VER} source…"
  mkdir -p "$BUILD_PARENT"
  cd "$BUILD_PARENT"
  wget -c "http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}-current.tar.gz"
  tar -xzf "asterisk-${ASTERISK_VER}-current.tar.gz"
  done_step "download"
fi


#  BUILD & INSTALL

if need_step "build"; then
  cd "$BUILD_DIR"
  msg "Configuring & compiling (please wait)…"
  contrib/scripts/install_prereq install -y
  ./configure --with-bluetooth=yes --with-ssl=yes
  make menuselect.makeopts
  menuselect/menuselect --enable chan_mobile \
                         --enable res_timing_timerfd \
                         --enable CORE-SOUNDS-en-wav \
                         menuselect.makeopts
  make -j"$(nproc)"
  make install
  make samples
  make config
  ldconfig
  done_step "build"
fi


#  ENABLE SYSTEMD UNIT (one‑time)

if need_step "enable-unit"; then
  msg "Enabling Asterisk systemd service to start at boot…"
  systemctl enable asterisk
  done_step "enable-unit"
fi


#  REPAIR MISSING SYMLINK

[[ -x /usr/sbin/asterisk ]] || ln -sf /usr/local/sbin/asterisk /usr/sbin/asterisk || true


#  BLUETOOTH PREP

systemctl restart bluetooth
rfkill unblock bluetooth
bluetoothctl power on


#  CONFIG FILES (create or repair)

cfg_chan_mobile () {
  backup /etc/asterisk/chan_mobile.conf
  cat > /etc/asterisk/chan_mobile.conf <<EOF
[general]
interface  = $BT_ADAPTER
nat        = no
autoconnect=yes
EOF
}

cfg_modules () {
  backup /etc/asterisk/modules.conf
  grep -q '^load = chan_mobile.so' /etc/asterisk/modules.conf 2>/dev/null || \
    echo 'load = chan_mobile.so' >> /etc/asterisk/modules.conf
}

cfg_manager () {
  backup /etc/asterisk/manager.conf
  grep -q "^\[$AMI_USER\]" /etc/asterisk/manager.conf 2>/dev/null || cat >> /etc/asterisk/manager.conf <<EOF

[$AMI_USER]
secret = $AMI_SECRET
deny   = 0.0.0.0/0.0.0.0
permit = 127.0.0.1/255.255.255.0
read   = all
write  = all
EOF
}

cfg_extensions () {
  backup /etc/asterisk/extensions.conf
  grep -q "^\[$OUT_CONTEXT\]" /etc/asterisk/extensions.conf 2>/dev/null || cat >> /etc/asterisk/extensions.conf <<EOF

[$OUT_CONTEXT]
exten => _X.,1,NoOp(Outgoing via GSM: \${EXTEN})
 same  => n,Dial(Mobile/\${DEVICE_MAC}/\${EXTEN},60)
 same  => n,Hangup()

[$IN_CONTEXT]
exten => s,1,NoOp(Inbound GSM call from \${CALLERID(num)})
 same  => n,Dial(SIP/1000,20)
 same  => n,Voicemail(1000@default,u)
 same  => n,Hangup()
EOF
}

[[ ! -s /etc/asterisk/chan_mobile.conf ]] && cfg_chan_mobile
[[ ! -s /etc/asterisk/modules.conf     ]] && cfg_modules
[[ ! -s /etc/asterisk/manager.conf     ]] && cfg_manager
[[ ! -s /etc/asterisk/extensions.conf  ]] && cfg_extensions


#  DEVICE DISCOVERY (first run only)

if need_step "pair"; then
  while : ; do
    msg "Scanning 10 s for discoverable phones…"
    bluetoothctl --timeout 10 scan on &>/dev/null
    DEVICES=$(bluetoothctl devices | grep -v "Controller" || true)
    [[ -n $DEVICES ]] && break
    read -rp "No devices found - press <Enter> to retry, or any other key to quit: " r || true
    [[ -z $r ]] || err "Aborted by user."
  done

  printf "\nFound devices:\n"; nl -ba <<<"$DEVICES"
  read -rp "Choose device number to pair: " sel
  LINE=$(sed -n "${sel}p" <<<"$DEVICES")
  DEVICE_MAC=$(awk '{print $2}' <<<"$LINE")
  DEVICE_NAME=$(cut -d' ' -f3- <<<"$LINE")

  msg "Pairing/trusting $DEVICE_NAME ($DEVICE_MAC)…"
  bluetoothctl <<EOF
agent on
default-agent
pair $DEVICE_MAC
trust $DEVICE_MAC
quit
EOF

  # Detect correct RFCOMM channel
  PORT=$(detect_rfcomm_port "$DEVICE_MAC")
  msg "Detected RFCOMM channel $PORT"

  # Write phone stanza with detected port
  grep -q "^\[$DEVICE_NAME\]" /etc/asterisk/chan_mobile.conf || cat >> /etc/asterisk/chan_mobile.conf <<EOF

[$DEVICE_NAME]
address  = $DEVICE_MAC
port     = $PORT
context  = $IN_CONTEXT
adapter  = $BT_ADAPTER
EOF
  done_step "pair"
fi



#  SELF‑HEAL: update ports if phone moved channels

update_ports () {
  local mac port_current port_expected
  while read -r mac; do
    port_current=$(awk "/address.*$mac/{flag=1}flag&&/port/{print \$3; exit}" /etc/asterisk/chan_mobile.conf)
    port_expected=$(detect_rfcomm_port "$mac")
    if [[ -n $port_current && $port_current != "$port_expected" ]]; then
      warn "RFCOMM channel for $mac changed $port_current → $port_expected. Fixing…"
      sed -i "/address.*$mac/{n;s/port.*/port     = $port_expected/}" /etc/asterisk/chan_mobile.conf
    fi
  done < <(grep -Eo '([0-9A-F]{2}:){5}[0-9A-F]{2}' /etc/asterisk/chan_mobile.conf | sort -u)
}
update_ports   # runs every invocation



#  ENSURE SERVICE RUNNING & RELOAD

systemctl restart asterisk          # start now (idempotent)

if ! systemctl is-active --quiet asterisk; then
  warn "Asterisk service not running — attempting to start…"
  systemctl start asterisk || err "Failed to start Asterisk. See: journalctl -u asterisk"
fi

asterisk -rx "module reload chan_mobile.so" || true
asterisk -rx "dialplan reload"             || true
asterisk -rx "manager reload"              || true


#  SUMMARY

cat <<EOF

\033[1;32m✔ Installation/repair complete.\033[0m
You can re-run ./setup.sh anytime; it will resume or fix issues automatically.

Checks:
  sudo asterisk -rvvv
    mobile show devices
    manager show users

AMI credentials:
  User   : $AMI_USER
  Secret : $AMI_SECRET

Need different answers later?
  sudo ./setup.sh --reconfigure

Happy hacking! by neko!
EOF

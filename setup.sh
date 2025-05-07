#!/usr/bin/env bash

set -eo pipefail
[[ $EUID -eq 0 ]] || { echo "Run this script as root"; exit 99; }
echo -e "\033[1;34m— neko installer starting —\033[0m"

TMPBASE=/tmp/neko
STATE_FILE=$TMPBASE/state
SENTINEL_DIR=$TMPBASE/sentinels
mkdir -p "$SENTINEL_DIR"

_STEPS=(packages asterisk-user download build enable-unit pair)

msg(){ printf "\033[1;32m▶ %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m⚠ %s\033[0m\n" "$*"; }
err(){ printf "\033[1;31m✖ %s\033[0m\n" "$*"; exit 1; }
backup(){ [[ -f $1 && ! -f $1.orig ]] && cp "$1" "$1.orig"; }

need(){ [[ ! -e $SENTINEL_DIR/$1 ]]; }
mark_done(){ touch "$SENTINEL_DIR/$1"; }
any_pending(){ for s in "${_STEPS[@]}"; do [[ ! -e $SENTINEL_DIR/$s ]] && return 0; done; return 1; }

detect_rfcomm(){ local mac=$1 port=""
  port=$(sdptool search --bdaddr "$mac" HEADSET 2>/dev/null | awk '/Channel/ {print $NF; exit}')
  [[ -z $port ]] && port=$(sdptool search --bdaddr "$mac" SP 2>/dev/null | awk '/Channel/ {print $NF; exit}')
  if [[ -z $port ]]; then
    for ch in {1..30}; do
      timeout 3 rfcomm connect "$BT_ADAPTER" "$mac" "$ch" &>/dev/null &&
        { port=$ch; rfcomm release "$BT_ADAPTER" "$ch" &>/dev/null; break; }
    done
  fi
  [[ -z $port ]] && port=1; echo "$port"; }


ask(){ local var=$1 prompt=$2 def=$3 ans
  [[ -n ${!var-} ]] && return
  if $NONINT; then ans=$def
  else read -r -p "$prompt [$def]: " ans || true; [[ -z $ans ]] && ans=$def; fi
  printf -v "$var" %s "$ans"; }


save_state(){ mkdir -p "$TMPBASE"; cat >"$STATE_FILE" <<EOF
ASTERISK_VER=$ASTERISK_VER
AMI_USER=$AMI_USER
AMI_SECRET=$AMI_SECRET
BT_ADAPTER=$BT_ADAPTER
OUT_CONTEXT=$OUT_CONTEXT
IN_CONTEXT=$IN_CONTEXT
BUILD_PARENT=$BUILD_PARENT
DEVICE_MAC=${DEVICE_MAC:-}
DEVICE_NAME=${DEVICE_NAME:-}
EOF
}

load_state(){ [[ -f $STATE_FILE ]] && source "$STATE_FILE"; }

[[ -f $STATE_FILE ]] || { warn "No saved state – fresh run."; rm -rf "$SENTINEL_DIR"; mkdir -p "$SENTINEL_DIR"; }

NONINT=false FORCE_RECONF=false
for arg in "$@"; do case $arg in -y|--yes) NONINT=true ;; --reconfigure) FORCE_RECONF=true ;; *) err "Unknown flag $arg" ;; esac; done

load_state
$FORCE_RECONF && { rm -rf "$SENTINEL_DIR"; mkdir -p "$SENTINEL_DIR"; rm -f "$STATE_FILE"; unset ASTERISK_VER AMI_USER AMI_SECRET BT_ADAPTER OUT_CONTEXT IN_CONTEXT BUILD_PARENT DEVICE_MAC DEVICE_NAME; }

ask ASTERISK_VER "Asterisk branch" 20
ask AMI_USER     "AMI user"        neko
ask AMI_SECRET   "AMI secret"      neko
ask BT_ADAPTER   "Bluetooth adapter" hci0
ask OUT_CONTEXT  "Outbound context"  neko_out
ask IN_CONTEXT   "Inbound context"   neko_in
ask BUILD_PARENT "Source dir"        /usr/src/neko
BUILD_DIR="${BUILD_PARENT%/}/asterisk-${ASTERISK_VER}"
save_state

if need packages; then
  msg "Installing packages…"
  apt-get update -qq
  apt-get install -y build-essential git wget usbutils bluetooth bluez rfkill \
    libusb-dev libbluetooth-dev libnewt-dev libssl-dev libsqlite3-dev \
    libjansson-dev libedit-dev uuid-dev pkg-config expect
  mark_done packages
fi

if need asterisk-user; then
  id -u asterisk &>/dev/null || adduser --system --group --home /var/lib/asterisk asterisk
  usermod -aG dialout,bluetooth asterisk || true
  mark_done asterisk-user
fi

if need download; then
  msg "Downloading Asterisk…"
  mkdir -p "$BUILD_PARENT"
  cd "$BUILD_PARENT"
  wget -c "http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VER}-current.tar.gz"
  tar -xzf "asterisk-${ASTERISK_VER}-current.tar.gz"
  mark_done download
fi

if need build; then
  cd "$BUILD_DIR"
  contrib/scripts/install_prereq install -y
  ./configure --with-bluetooth=yes --with-ssl=yes
  make menuselect.makeopts
  menuselect/menuselect --enable chan_mobile --enable res_timing_timerfd --enable CORE-SOUNDS-en-wav menuselect.makeopts
  make -j"$(nproc)"
  make install; make samples; make config; ldconfig
  mark_done build
fi

if need enable-unit; then
  systemctl enable asterisk
  mark_done enable-unit
fi

[[ -x /usr/sbin/asterisk ]] || ln -sf /usr/local/sbin/asterisk /usr/sbin/asterisk || true
systemctl restart bluetooth; rfkill unblock bluetooth; bluetoothctl power on

[[ -s /etc/asterisk/chan_mobile.conf ]] || cat > /etc/asterisk/chan_mobile.conf <<EOF
[general]
interface = $BT_ADAPTER
nat       = no
autoconnect=yes
EOF

backup /etc/asterisk/modules.conf
grep -q '^load *= *chan_mobile.so' /etc/asterisk/modules.conf || echo 'load = chan_mobile.so' >> /etc/asterisk/modules.conf

backup /etc/asterisk/manager.conf
grep -q "^\[$AMI_USER\]" /etc/asterisk/manager.conf || cat >> /etc/asterisk/manager.conf <<EOF

[$AMI_USER]
secret = $AMI_SECRET
deny   = 0.0.0.0/0.0.0.0
permit = 127.0.0.1/255.255.255.0
read   = all
write  = all
EOF

backup /etc/asterisk/extensions.conf
grep -q "^\[$OUT_CONTEXT\]" /etc/asterisk/extensions.conf || cat >> /etc/asterisk/extensions.conf <<EOF

[$OUT_CONTEXT]
exten => _X.,1,Dial(Mobile/\${DEVICE_MAC}/\${EXTEN},60)
 same  => n,Hangup()
EOF
grep -q "^\[$IN_CONTEXT\]" /etc/asterisk/extensions.conf || cat >> /etc/asterisk/extensions.conf <<EOF

[$IN_CONTEXT]
exten => s,1,Dial(SIP/1000,20)
 same  => n,Voicemail(1000@default,u)
 same  => n,Hangup()
EOF

if need pair; then
  while :; do
    msg "Scanning for phones…"; bluetoothctl --timeout 10 scan on &>/dev/null
    DEV=$(bluetoothctl devices | grep -v Controller || true); [[ -n $DEV ]] && break
    read -rp "No devices; Enter retry, q quit: " r; [[ $r == q ]] && err "Aborted."
  done
  printf "\nDevices:\n"; nl -ba <<<"$DEV"
  read -rp "Choose #: " n; LINE=$(sed -n "${n}p" <<<"$DEV") || err "Bad pick."
  DEVICE_MAC=$(awk '{print $2}' <<<"$LINE"); DEVICE_NAME=$(cut -d' ' -f3- <<<"$LINE")
  bluetoothctl <<EOF
agent on
default-agent
pair $DEVICE_MAC
trust $DEVICE_MAC
quit
EOF
  PORT=$(detect_rfcomm "$DEVICE_MAC")
  cat >> /etc/asterisk/chan_mobile.conf <<EOF

[$DEVICE_NAME]
address  = $DEVICE_MAC
port     = $PORT
context  = $IN_CONTEXT
adapter  = $BT_ADAPTER
EOF
  save_state; mark_done pair
fi

# adjust ports if they drifted
grep -Eo '([0-9A-F]{2}:){5}[0-9A-F]{2}' /etc/asterisk/chan_mobile.conf | sort -u | while read -r mac; do
 cur=$(awk "/address.*$mac/{f=1}f&&/port/{print \$3; exit}" /etc/asterisk/chan_mobile.conf)
 exp=$(detect_rfcomm "$mac"); [[ $cur != $exp ]] && sed -i "/address.*$mac/{n;s/port.*/port     = $exp/}" /etc/asterisk/chan_mobile.conf
done

systemctl restart asterisk || systemctl start asterisk
asterisk -rx "module reload chan_mobile.so" || true
asterisk -rx "dialplan reload"             || true
asterisk -rx "manager reload"              || true

any_pending && { msg "Continuing…"; exec "$0" "$@"; }

cat <<EOF
\033[1;32m✔ Asterisk + chan_mobile ready.\033[0m
AMI user  : $AMI_USER
AMI secret: $AMI_SECRET
EOF

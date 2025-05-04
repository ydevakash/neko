#!/bin/bash

set -e

echo "Updating and installing dependencies..."
sudo apt update
sudo apt install -y build-essential git wget usbutils \
  libusb-dev libbluetooth-dev libnewt-dev libssl-dev libsqlite3-dev \
  libjansson-dev libedit-dev uuid-dev bluetooth bluez alsa-utils pkg-config expect

echo "Downloading and compiling Asterisk with chan_mobile..."
cd /usr/src
sudo wget -q http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-20-current.tar.gz
sudo tar -xzf asterisk-20-current.tar.gz
cd asterisk-20*

sudo contrib/scripts/install_prereq install -y
sudo ./configure
sudo make menuselect.makeopts
sudo menuselect/menuselect --enable chan_mobile menuselect.makeopts
sudo make -j$(nproc)
sudo make install
sudo make samples
sudo make config
sudo ldconfig

echo "Asterisk installed with chan_mobile."

echo "Restarting bluetooth service..."
sudo systemctl restart bluetooth
sudo rfkill unblock bluetooth

echo "Scanning for Bluetooth devices nearby..."
sudo bluetoothctl --timeout 10 scan on > /dev/null &
sleep 10
DEVICES=$(bluetoothctl devices | grep -v "Controller")

if [ -z "$DEVICES" ]; then
  echo "No Bluetooth devices found. Please ensure your phone's Bluetooth is ON and discoverable."
  exit 1
fi

echo ""
echo "Found devices:"
echo "$DEVICES" | nl

read -p "Enter the number of the device to use as your GSM phone: " DEVICE_NUM
SELECTED_LINE=$(echo "$DEVICES" | sed -n "${DEVICE_NUM}p")
PHONE_MAC=$(echo "$SELECTED_LINE" | awk '{print $2}')
PHONE_NAME=$(echo "$SELECTED_LINE" | cut -d ' ' -f3-)

echo "Selected device: $PHONE_NAME ($PHONE_MAC)"

echo "Pairing and trusting the phone..."
bluetoothctl <<EOF
agent on
default-agent
pair $PHONE_MAC
trust $PHONE_MAC
quit
EOF

echo "Writing /etc/asterisk/mobile.conf..."
sudo tee /etc/asterisk/mobile.conf > /dev/null <<EOF
[general]
interface = hci0

[mobile1]
address = $PHONE_MAC
port = 1
context = from-mobile
adapter = hci0
EOF

echo "Writing outbound dialplan to /etc/asterisk/extensions.conf..."
sudo tee -a /etc/asterisk/extensions.conf > /dev/null <<EOF

[outbound]
exten => _X.,1,Dial(Mobile/mobile1/\${EXTEN},60)
 same => n,Hangup()
EOF

echo "All done!"

echo "Want to try it now? follow:"
echo "1. Start Asterisk: sudo asterisk -rvvv"
echo "2. Type: 'mobile search' and 'mobile show devices'"
echo "3. Use: 'originate Mobile/mobile1/PHONE_NUMBER application Playback hello-world'"
echo "4. To trigger an outbound call from dialplan with: exten => _X.,1,Dial(...)"

echo "Your phone ($PHONE_NAME) can now be used to place GSM calls through Asterisk!"

echo "Happy hacking! by Annomroot."

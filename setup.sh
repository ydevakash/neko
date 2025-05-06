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

# Loop until devices found or user quits
while true; do
  echo "Scanning for Bluetooth devices nearby..."
  sudo bluetoothctl --timeout 10 scan on > /dev/null &
  sleep 10
  DEVICES=$(bluetoothctl devices | grep -v "Controller")

  if [ -z "$DEVICES" ]; then
    echo
    echo "No Bluetooth devices found. Please ensure your phone's Bluetooth is ON and discoverable."
    read -n1 -p "Press 'r' to retry scanning or any other key to exit: " key
    echo
    if [[ "$key" == "r" || "$key" == "R" ]]; then
      echo "Retrying scan..."
      sleep 1
      continue
    else
      echo "Exiting."
      exit 1
    fi
  else
    break
  fi
done

echo
echo "Found devices:"
echo "$DEVICES" | nl
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

echo
read -p "Enter new AMI manager username: " AMI_NEW_USER
read -s -p "Enter secret for '$AMI_NEW_USER': " AMI_NEW_SECRET
echo
echo "Configuring AMI manager user '$AMI_NEW_USER'..."

if ! grep -q "^\[$AMI_NEW_USER\]" /etc/asterisk/manager.conf; then
  sudo tee -a /etc/asterisk/manager.conf > /dev/null <<EOF

[$AMI_NEW_USER]
secret = $AMI_NEW_SECRET
deny=0.0.0.0/0.0.0.0
permit=127.0.0.1/255.255.255.0
read = call,log,verbose,command,agent,system
write = call,agent,system
EOF
  echo "Added AMI user '$AMI_NEW_USER' to /etc/asterisk/manager.conf"
else
  echo "AMI user '$AMI_NEW_USER' already exists, skipping."
fi

echo "Reloading Asterisk AMI manager and dialplan..."
sudo asterisk -rx "manager reload" || echo "Warning: Failed to reload AMI manager"
sudo asterisk -rx "dialplan reload" || echo "Warning: Failed to reload dialplan"

echo "All done!"

cat <<EOM

To verify:

  sudo asterisk -rvvv
  > manager show users       # should list '$AMI_NEW_USER'
  > mobile search
  > mobile show devices

To originate a call via AMI:

  - Connect via AMI with:
      Username: $AMI_NEW_USER
      Secret:   $AMI_NEW_SECRET
  - From Asterisk CLI:
      originate Mobile/mobile1/PHONE_NUMBER application Playback hello-world

Happy hacking! by neko.

EOM

# neko🐾 : An Asterisk GSM Outbound Dialer via Bluetooth (chan\_mobile)

This project is about Asterisk with the `chan_mobile` module to **place GSM calls through your Android phone via Bluetooth**. <br/>
Perfect for you if you're looking for a free, `no-root` way to manage calls from a server with the help of a mobile phone.

## Features

* Make outbound GSM calls using your phone's SIM
* Auto-scans for nearby bluetooth phones
* Automatically pairs, trusts, and configures [asterisk](https://www.asterisk.org/)
* Installs and compiles `asterisk` with `chan_mobile`
* Adds a dialplan to route calls via your mobile


## Prerequisites

* A Linux system or VM (Ubuntu/Debian recommended)
* A USB Bluetooth dongle *(if your host/VM lacks Bluetooth)*
* A phone with **Bluetooth calling** capability *(not just audio/music)*


## Quick Install (1-Line Setup)

```bash
wget -O setup.sh https://raw.githubusercontent.com/ydevakash/neko/refs/heads/main/setup.sh && chmod +x setup.sh && ./setup.sh
```

This will:
1. Install all required packages and dependencies
2. Download, compile, and install Asterisk with `chan_mobile`
3. Scan for Bluetooth devices and let you pick your phone
4. Pair and trust your phone
5. Auto generate `mobile.conf` and update `extensions.conf`
6. Auto set-up an `outbound` context to trigger GSM calls

## Test the Setup

1. Start Asterisk:
   ```bash
   sudo asterisk -rvvv
   ```

2. List mobile devices:
   ```bash
   mobile show devices
   ```

3. Try calling from the Asterisk console:
   ```bash
   originate Mobile/mobile1/PHONE_NUMBER application Playback hello-world
   ```

4. Or from dialplan:
   ```bash
   exten => _X.,1,Dial(Mobile/mobile1/${EXTEN},60)
    same => n,Hangup()
   ```

## Notes

* If the script can't detect your phone, make sure:

  * Your phone is in **Bluetooth pairing mode**
  * You’ve enabled “Phone calls” in Bluetooth settings
  * The phone is not already paired with another device
  > The setup script uses `bluetoothctl` in non-interactive mode to auto pair and trust your device

## Future Work

* Add REST API to trigger outbound calls via HTTP
* Support call forwarding to internal SIP extensions
* Auto-configure SIP clients for internal call bridging


## Troubleshooting

* Use `lsusb` or `bluetoothctl show` to verify Bluetooth dongle is recognized

* Make sure `bluetooth.service` is running:

  ```bash
  sudo systemctl status bluetooth
  ```

* Restart Bluetooth if needed:

  ```bash
  sudo systemctl restart bluetooth
  ```

---

## License

MIT — feel free to fork and improve.

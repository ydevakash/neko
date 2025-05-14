#!/usr/bin/env python3
from __future__ import annotations
import asyncio, signal, sys, time, argparse, csv
from typing import List, Dict, Optional
from datetime import datetime
import telnetlib3
import logging
import pathlib

# ── CONFIG ─────────────────────────────────────────────────────────────
HOST    = "172.16.10.177"
PORT    = 5038
USER    = "neko"
SECRET  = "neko"
TIMEOUT = 180_000

# ── Globals ─────────────────────────────────────────────────────────────
log = logging.getLogger("dialer")

class CallSession:
    def __init__(self, number: str, csv_writer: csv.DictWriter):
        self.number = number
        self.action_id = f"NEKO-CLI-{int(time.time())}"
        self.linkedid: Optional[str] = None
        self.start_ts: Optional[float] = None
        self.csv_writer = csv_writer

    def log_event_block(self, block: List[str]) -> None:
        for line in block:
            log.debug(line)

    def process_event(self, block: List[str]) -> bool:
        self.log_event_block(block)

        headers: Dict[str, str] = {}
        event_type = None
        for line in block:
            if ':' in line:
                key, val = [x.strip() for x in line.split(':', 1)]
                headers[key] = val
                if key == 'Event':
                    event_type = val

        # Discover linkedid
        if self.linkedid is None:
            if event_type == 'OriginateResponse' and headers.get('ActionID') == self.action_id:
                self.linkedid = headers.get('Linkedid')
            elif event_type == 'Newchannel' and headers.get('Channel', '').startswith('Local/'):
                self.linkedid = headers.get('Linkedid')

        if self.linkedid and headers.get('Linkedid') != self.linkedid:
            return False

        # Mark start
        if self.start_ts is None:
            if event_type == 'OriginateResponse' and headers.get('DialStatus') == 'ANSWER':
                self.start_ts = time.time()
            elif event_type in ('BridgeEnter', 'BridgeCreate'):
                self.start_ts = time.time()

        if event_type == 'Hangup':
            end_ts = time.time()
            duration = int(end_ts - (self.start_ts or end_ts))
            cause = headers.get('Cause-txt') or headers.get('Cause', '<unknown>')
            dial_status = headers.get('DialStatus', '')
            start_dt = datetime.fromtimestamp(self.start_ts).isoformat() if self.start_ts else ''
            end_dt = datetime.fromtimestamp(end_ts).isoformat()

            summary = (f"==== CALL (ActionID={self.action_id}) ENDED – "
                       f"talk-time {duration}s  cause={cause} ====")
            print(f"\n{summary}")
            log.info(summary)

            self.csv_writer.writerow({
                'ActionID': self.action_id,
                'Number': self.number,
                'LinkedID': self.linkedid or '',
                'StartTime': start_dt,
                'EndTime': end_dt,
                'TalkTimeSec': duration,
                'DialStatus': dial_status,
                'Cause': cause
            })
            return True

        return False


async def send_block(writer, lines: List[str]) -> None:
    for line in lines:
        writer.write(line + "\r\n")
    writer.write("\r\n")
    await writer.drain()


async def handle_call(number: str, csv_writer: csv.DictWriter) -> None:
    session = CallSession(number, csv_writer)

    reader, writer = await telnetlib3.open_connection(host=HOST, port=PORT, encoding='ascii')
    await reader.readuntil(b"\n")  # skip banner

    await send_block(writer, ['Action: Login', f'Username: {USER}', f'Secret: {SECRET}'])
    await send_block(writer, ['Action: Events', 'EventMask: all'])

    await send_block(writer, [
        'Action: Originate',
        f'Channel: Local/{number}@neko_out/n',
        'Context: neko_out',
        f'Exten: {number}',
        'Priority: 1',
        'CallerID: Campaign <1000>',
        f'Timeout: {TIMEOUT}',
        'Async: true',
        f'ActionID: {session.action_id}',
    ])
    log.info(f"Calling {number} (ActionID={session.action_id})")

    block: List[str] = []
    try:
        while True:
            line = await reader.readline()
            if line is None:
                break
            line = line.rstrip("\r\n")
            if line:
                block.append(line)
            else:
                if block:
                    if session.process_event(block):
                        break
                    block.clear()
    finally:
        writer.close()


def setup_logging(level: str, debug: bool) -> None:
    lvl = logging.DEBUG if debug else getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(
        level=lvl,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
        filename='neko_cli.log'
    )


async def run_calls(numbers: List[str], csv_path: pathlib.Path) -> None:
    try:
        with open(csv_path, 'w', newline='') as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=[
                'ActionID', 'Number', 'LinkedID', 'StartTime',
                'EndTime', 'TalkTimeSec', 'DialStatus', 'Cause'
            ])
            writer.writeheader()
            for number in numbers:
                await handle_call(number, writer)
    except Exception as e:
        log.error(f"CSV write error: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Neko campaign sequential dialer via AMI and generate report.")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('-n', '--number', action='append', dest='numbers', help='pass numbers in-line')
    group.add_argument('-f', '--file', dest='file', help='take numbers from file')
    parser.add_argument('--debug', action="store_true", help='log everything for debugging')
    parser.add_argument('--log-level', default='INFO', help='logging level (default: INFO)')
    parser.add_argument('-o', '--out', dest='csv', type=pathlib.Path, default=pathlib.Path(f"./campaign_report_{datetime.now():%Y%m%d_%H%M%S}.csv"))
    args = parser.parse_args()

    setup_logging(args.log_level, args.debug)

    if args.file:
        try:
            with open(args.file) as f:
                numbers = [line.strip() for line in f if line.strip()]
        except Exception as e:
            print(f"Error reading file {args.file}: {e}")
            sys.exit(1)
    else:
        numbers = args.numbers

    loop = asyncio.new_event_loop()
    try:
        asyncio.set_event_loop(loop)
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, lambda: sys.exit(0))
        loop.run_until_complete(run_calls(numbers, args.csv))
    finally:
        log.info("Shutting down...")
        loop.close()


if __name__ == '__main__':
    main()

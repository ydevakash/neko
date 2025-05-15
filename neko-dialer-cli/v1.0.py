from __future__ import annotations
import asyncio, signal, sys, time, argparse, csv
from typing import List, Dict, Optional
from datetime import datetime
import telnetlib3
import logging
import pathlib
from rich.console import Console
from rich.text import Text
from rich.progress import Progress, BarColumn, TimeElapsedColumn, TextColumn

# ── CONFIG ─────────────────────────────────────────────────────────────
HOST    = "172.16.10.177"
PORT    = 5038
USER    = "neko"
SECRET  = "neko"
TIMEOUT = 180_000

log = logging.getLogger("neko-dialer-cli")
console = Console()

class CampaignState:
    def __init__(self, numbers: List[str]):
        self.total = len(numbers)
        self.pending = set(numbers)
        self.in_progress = set()
        self.completed = set()
        self.failed: Dict[str, str] = {}
        self.lock = asyncio.Lock()
        self.progress = Progress(
            TextColumn("[bold blue]Progress:[/bold blue]"),
            BarColumn(),
            "[progress.percentage]{task.percentage:>3.0f}%",
            TimeElapsedColumn(),
            console=console,
            transient=True
        )
        self.task_id = self.progress.add_task("dialing", total=self.total)

    async def update_status(self, number: str, status: str, error: Optional[str] = None):
        async with self.lock:
            if status == 'start':
                self.pending.discard(number)
                self.in_progress.add(number)
            elif status == 'done':
                self.in_progress.discard(number)
                self.completed.add(number)
                self.progress.update(self.task_id, advance=1)
            elif status == 'failed':
                self.in_progress.discard(number)
                self.failed[number] = error or "Unknown"
                self.progress.update(self.task_id, advance=1)
            self.display_stats()

    def display_stats(self):
        console.print(
            f"[cyan]Stats:[/cyan] Total: {self.total} | Dialing: {len(self.in_progress)} | Completed: {len(self.completed)} | Failed: {len(self.failed)}",
            end='\r'
        )

    def display_summary(self, csv_path: pathlib.Path):
        console.print("\n[bold green] Campaign completed[/bold green]")
        console.print(f"[white]Results saved to[/white] [cyan]{csv_path}[/cyan]")
        if self.failed:
            console.print("\n[bold red] Failed Calls:[/bold red]")
            for num, reason in self.failed.items():
                console.print(f"[red]- {num}[/red]: {reason}")

class CallSession:
    def __init__(self, number: str, action_id: str, buffer: List[Dict[str, str]], state: CampaignState):
        self.number = number
        self.action_id = action_id
        self.linkedid: Optional[str] = None
        self.start_ts: Optional[float] = None
        self.result_row: Optional[Dict[str, str]] = None
        self.buffer = buffer
        self.state = state

    def process_event(self, block: List[str]) -> bool:
        headers = {}
        event_type = None
        for line in block:
            if ':' in line:
                key, val = [x.strip() for x in line.split(':', 1)]
                headers[key] = val
                if key == 'Event':
                    event_type = val

        if self.linkedid is None:
            if event_type == 'OriginateResponse' and headers.get('ActionID') == self.action_id:
                self.linkedid = headers.get('Linkedid')
            elif event_type == 'Newchannel' and headers.get('Channel', '').startswith('Local/'):
                self.linkedid = headers.get('Linkedid')

        if self.linkedid and headers.get('Linkedid') != self.linkedid:
            return False

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

            self.result_row = {
                'ActionID': self.action_id,
                'Number': self.number,
                'LinkedID': self.linkedid or '',
                'StartTime': start_dt,
                'EndTime': end_dt,
                'TalkTimeSec': duration,
                'DialStatus': dial_status,
                'Cause': cause
            }
            self.buffer.append(self.result_row)
            return True

        return False

async def send_block(writer, lines: List[str]) -> None:
    for line in lines:
        writer.write(line + "\r\n")
    writer.write("\r\n")
    await writer.drain()

async def handle_call(number: str, buffer: List[Dict[str, str]], state: CampaignState) -> None:
    action_id = f"NEKO-CLI-{int(time.time())}-{number[-4:]}"
    await state.update_status(number, 'start')
    session = CallSession(number, action_id, buffer, state)
    console.log(f"Dialing {number}...")

    state.display_stats()
    try:
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
            f'ActionID: {action_id}',
        ])
        log.info(f"Calling {number} (ActionID={action_id})")

        block = []
        while True:
            line = await reader.readline()
            if line is None:
                break
            line = line.rstrip("\r\n")
            if line:
                block.append(line)
            else:
                if block and session.process_event(block):
                    break
                block.clear()
    except Exception as e:
        log.error(f"Error calling {number}: {e}")
        await state.update_status(number, 'failed', str(e))
    else:
        await state.update_status(number, 'done')
    finally:
        try:
            writer.close()
        except:
            pass

async def run_campaign(numbers: List[str], csv_path: pathlib.Path):
    results: List[Dict[str, str]] = []
    state = CampaignState(numbers)

    with state.progress:
        for num in numbers:
            await handle_call(num, results, state)

    try:
        with open(csv_path, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=[
                'ActionID', 'Number', 'LinkedID', 'StartTime',
                'EndTime', 'TalkTimeSec', 'DialStatus', 'Cause'
            ])
            writer.writeheader()
            writer.writerows(results)
        state.display_summary(csv_path)
    except Exception as e:
        log.error(f"Failed writing CSV: {e}")
        console.print(f"\n[bold red] Error saving CSV:[/bold red] {e}")

def setup_logging(level: str, debug: bool) -> None:
    lvl = logging.DEBUG if debug else getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(
        level=lvl,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
        filename='neko_cli.log'
    )

def main():
    parser = argparse.ArgumentParser(description="Neko AMI Campaign Dialer with Rich Progress")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('-n', '--number', action='append', dest='numbers', help='Phone numbers to dial')
    group.add_argument('-f', '--file', dest='file', help='File with one number per line')
    parser.add_argument('--debug', action="store_true")
    parser.add_argument('--log-level', default='INFO')
    parser.add_argument('-o', '--out', dest='csv', type=pathlib.Path,
                        default=pathlib.Path(f"./campaign_report_{datetime.now():%Y%m%d_%H%M%S}.csv"))
    args = parser.parse_args()

    setup_logging(args.log_level, args.debug)

    if args.file:
        try:
            with open(args.file) as f:
                numbers = [line.strip() for line in f if line.strip()]
        except Exception as e:
            console.print(f"[red]Error reading file {args.file}:[/red] {e}")
            sys.exit(1)
    else:
        numbers = args.numbers

    loop = asyncio.new_event_loop()
    try:
        asyncio.set_event_loop(loop)
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, lambda: sys.exit(0))
        loop.run_until_complete(run_campaign(numbers, args.csv))
    finally:
        log.info("Shutting down...")
        loop.close()

if __name__ == '__main__':
    main()

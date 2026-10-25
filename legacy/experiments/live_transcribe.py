#!/usr/bin/env python3
"""Pendant -> Sarvam realtime WebSocket -> partial/final terminal transcripts."""
import argparse
import asyncio
import base64
from datetime import datetime, timezone
import json
import os
import shutil
from pathlib import Path
import struct
import sys
from urllib.parse import urlencode
import wave

from bleak import BleakClient, BleakScanner
from websockets.asyncio.client import connect

AUDIO_CHAR = '6b656570-7361-6b65-0001-000000000002'
RATE = 8000
FRAME_BYTES = 1600  # 100 ms of native mono PCM16


async def run(args):
    key = os.environ.get('SARVAM_API_KEY') or os.environ.get('KEEPSAKE_SARVAM_API_KEY')
    if not key:
        raise RuntimeError('Export SARVAM_API_KEY first (source ~/.zshrc).')
    if not args.wav and not sys.stdin.isatty():
        raise RuntimeError('Run in an interactive terminal for Enter-to-stop.')
    device = None
    if not args.wav:
        print('Scanning for Keepsake-P0...', flush=True)
        device = await BleakScanner.find_device_by_name('Keepsake-P0', timeout=20)
        if device is None:
            raise RuntimeError('Pendant not found. Unplug/reconnect it and retry.')
    folder = Path(__file__).parent / 'recordings' / datetime.now(timezone.utc).strftime('stream_%Y%m%dT%H%M%S_%fZ')
    folder.mkdir(parents=True)
    stop = asyncio.Event()
    ready = asyncio.Event()
    queue = asyncio.Queue(maxsize=50)  # at most five seconds of network backlog
    pending = bytearray()
    expected = None
    errors = []
    counts = {'packets': 0, 'partials': 0, 'finals': 0, 'sent_bytes': 0}
    ended = False
    loop = asyncio.get_running_loop()

    def fail(message):
        errors.append(message)
        print(f'\nERROR: {message}', flush=True)
        stop.set()

    def enter():
        sys.stdin.readline()
        stop.set()

    def disconnected(_):
        if not stop.is_set():
            fail('Pendant disconnected unexpectedly.')

    with wave.open(str(folder / 'audio.wav'), 'wb') as recording, (folder / 'events.jsonl').open('w') as events, (folder / 'transcript.txt').open('w') as transcript:
        recording.setnchannels(1)
        recording.setsampwidth(2)
        recording.setframerate(RATE)

        def feed(pcm):
            pending.extend(pcm)
            while len(pending) >= FRAME_BYTES:
                frame = bytes(pending[:FRAME_BYTES])
                del pending[:FRAME_BYTES]
                recording.writeframesraw(frame)
                try:
                    queue.put_nowait(frame)
                except asyncio.QueueFull:
                    fail('Network cannot keep up with audio; stopping capture.')
                    return

        def notify(_, data):
            nonlocal expected
            if stop.is_set():
                return
            if len(data) <= 5:
                fail('Malformed BLE packet.')
                return
            seq = struct.unpack_from('<I', data)[0]
            if expected is not None and seq != expected:
                fail(f'BLE packet gap: expected {expected}, received {seq}; retry capture.')
                return
            expected = (seq + 1) & 0xffffffff
            counts['packets'] += 1
            feed(data[5:])

        params = urlencode(dict(model='saaras:v4', language_code='auto',
                                stream_type=args.stream_type, mode=args.mode,
                                endpointing='vad', encoding='linear16', sample_rate=RATE))
        print('Connecting to Sarvam realtime (v4, auto language, 8 kHz)...', flush=True)
        async with connect('wss://api.sarvam.ai/speech-to-text-realtime/ws?' + params,
                           additional_headers={'Api-Subscription-Key': key},
                           open_timeout=20, close_timeout=5) as ws:
            async def receive():
                nonlocal ended
                previous = None
                try:
                    async for raw in ws:
                        event = json.loads(raw.replace(key, '[REDACTED]'))
                        events.write(json.dumps(event, ensure_ascii=False) + '\n')
                        events.flush()
                        kind = event.get('event')
                        if kind == 'session.begin':
                            ready.set()
                        elif kind in ('transcript.partial', 'transcript.final'):
                            final = kind == 'transcript.final'
                            counts['finals' if final else 'partials'] += 1
                            line = f"[{event.get('language', 'auto')}] {event.get('text', '')}"
                            # Each partial is a replacement hypothesis, not appended words.
                            if final:
                                print(('\r\033[2K' if sys.stdout.isatty() else '') + 'FINAL   ' + line, flush=True)
                                previous = None
                            elif line != previous and event.get('text'):
                                if sys.stdout.isatty():
                                    # Reserve two terminal cells per character for Indic/wide scripts.
                                    width = max(10, (shutil.get_terminal_size().columns - 12) // 2)
                                    print('\r\033[2Kpartial ' + line[-width:], end='', flush=True)
                                else:
                                    print('partial ' + line, flush=True)
                                previous = line
                            if final:
                                transcript.write(line + '\n')
                                transcript.flush()
                        elif kind == 'error':
                            fail(f"Sarvam {event.get('code')}: {event.get('message')}")
                            if event.get('is_fatal'):
                                return
                        elif kind == 'session.end':
                            ended = True
                            return
                finally:
                    if not ended:
                        fail('Realtime connection ended without session.end; final transcript may be incomplete.')
                    stop.set()
                    ready.set()

            async def send():
                while True:
                    frame = await queue.get()
                    if frame is None:
                        await ws.send(json.dumps({'event': 'end'}))
                        return
                    await ws.send(json.dumps({'event': 'audio_input', 'audio': base64.b64encode(frame).decode()}))
                    counts['sent_bytes'] += len(frame)

            receiver = asyncio.create_task(receive())
            sender = asyncio.create_task(send())
            sender.add_done_callback(lambda task: stop.set() if not task.cancelled() and task.exception() else None)
            try:
                await asyncio.wait_for(ready.wait(), timeout=20)
                if stop.is_set():
                    raise RuntimeError('Sarvam did not open a usable session.')
                if args.wav:
                    with wave.open(str(args.wav), 'rb') as source:
                        if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (RATE, 1, 2):
                            raise RuntimeError('Replay requires an 8 kHz mono PCM16 WAV.')
                        print('Replaying saved audio at real-time speed...', flush=True)
                        while not stop.is_set():
                            pcm = source.readframes(FRAME_BYTES // 2)
                            if not pcm:
                                break
                            feed(pcm)
                            await asyncio.sleep(len(pcm) / (RATE * 2))
                else:
                    async with BleakClient(device, disconnected_callback=disconnected) as client:
                        loop.add_reader(sys.stdin, enter)
                        try:
                            await client.start_notify(AUDIO_CHAR, notify)
                            print('RECORDING — speak now. Partials can change; FINAL is settled.\n'
                                  'Press ENTER to stop and finalize. Ctrl+C cancels.', flush=True)
                            await stop.wait()
                            if client.is_connected:
                                await client.stop_notify(AUDIO_CHAR)
                        finally:
                            loop.remove_reader(sys.stdin)
                stop.set()
                if len(pending) % 2:
                    fail('Incomplete last PCM sample; trailing byte omitted.')
                remainder = bytes(pending[:len(pending)//2*2])
                if remainder:
                    recording.writeframesraw(remainder)
                    await asyncio.wait_for(queue.put(remainder), timeout=10)
                print('Finishing audio and waiting for final transcript...', flush=True)
                await asyncio.wait_for(queue.put(None), timeout=10)
                await asyncio.wait_for(sender, timeout=20)
                await asyncio.wait_for(receiver, timeout=30)
            finally:
                for task in (sender, receiver):
                    task.cancel()
                await asyncio.gather(sender, receiver, return_exceptions=True)
    if not counts['sent_bytes']:
        errors.append('No audio was sent.')
    report = dict(counts, session_ended=ended, errors=errors)
    (folder / 'report.json').write_text(json.dumps(report, indent=2))
    print(f"\n{'Completed with errors' if errors else 'Completed'}. "
          f"{counts['partials']} partials, {counts['finals']} finals.\nSaved: {folder.resolve()}", flush=True)
    return 1 if errors or not ended else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['transcribe', 'codemix'], default='transcribe')
    parser.add_argument('--stream-type', choices=['fast', 'balanced'], default='fast')
    parser.add_argument('--wav', type=Path, help='Replay an existing 8 kHz WAV at real-time speed instead of BLE')
    try:
        raise SystemExit(asyncio.run(run(parser.parse_args())))
    except KeyboardInterrupt:
        print('\nCancelled. Use Enter to wait for final transcripts.')
        raise SystemExit(130)
    except Exception as exc:
        # API keys are never in URLs; redact defensively before printing diagnostics.
        message = str(exc)
        for name in ('SARVAM_API_KEY', 'KEEPSAKE_SARVAM_API_KEY'):
            if os.environ.get(name):
                message = message.replace(os.environ[name], '[REDACTED]')
        print(f'Test failed ({type(exc).__name__}): {message}')
        raise SystemExit(1)

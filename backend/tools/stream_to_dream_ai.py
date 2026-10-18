#!/usr/bin/env python3
"""Streams live 16 kHz audio from the Keepsake pendant directly to the Dream AI Console.
URL: https://aadeshai.xyz/dream-ai/
Webhook: https://aadeshai.xyz/omi/webhook/audio?sample_rate=16000
"""

import argparse
import asyncio
import sys
import time
import httpx
from bleak import BleakClient, BleakScanner

SERVICE_UUID = "6b656570-7361-6b65-0001-000000000001"
AUDIO_CHAR_UUID = "6b656570-7361-6b65-0001-000000000002"
INFO_CHAR_UUID = "6b656570-7361-6b65-0001-000000000003"
DEFAULT_WEBHOOK = "https://aadeshai.xyz/omi/webhook/audio?sample_rate=16000&uid=keepsake_user&token=keepsake-secret-2026"


async def run(webhook_url: str):
    print("=" * 60)
    print("Keepsake Pendant → Dream AI Console Streamer")
    print(f"Target: {webhook_url}")
    print("Web Console: https://aadeshai.xyz/dream-ai/")
    print("=" * 60)

    async with httpx.AsyncClient(timeout=10.0) as http_client:
        while True:
            print("\nScanning for Keepsake-P0 pendant...")
            device = await BleakScanner.find_device_by_filter(
                lambda d, a: SERVICE_UUID in a.service_uuids or (d.name and "Keepsake" in d.name),
                timeout=15.0,
            )
            if not device:
                print("Pendant not seen yet. Retrying in 2 seconds...")
                await asyncio.sleep(2)
                continue

            print(f"Found {device.name} ({device.address}). Connecting...")
            try:
                async with BleakClient(device) as client:
                    info = bytes(await client.read_gatt_char(INFO_CHAR_UUID))
                    if len(info) >= 8 and info[:4] == b"KSR1":
                        rate = int.from_bytes(info[4:8], "little")
                        print(f"✓ Validated stream format: {rate} Hz mono PCM16")
                    else:
                        print(f"! Unexpected descriptor: {info.hex()}")

                    pcm_buffer = bytearray()
                    last_flush = time.monotonic()
                    total_bytes_sent = 0

                    async def flush():
                        nonlocal pcm_buffer, last_flush, total_bytes_sent
                        if not pcm_buffer:
                            return
                        data = bytes(pcm_buffer)
                        pcm_buffer.clear()
                        last_flush = time.monotonic()
                        try:
                            resp = await http_client.post(
                                webhook_url,
                                content=data,
                                headers={"Content-Type": "application/octet-stream"},
                            )
                            if resp.status_code == 200:
                                total_bytes_sent += len(data)
                                sec = round(total_bytes_sent / 32000, 1)
                                print(f"\r[LIVE] Sent {len(data)} bytes ({sec}s audio streamed) → https://aadeshai.xyz/dream-ai/", end="", flush=True)
                        except Exception as e:
                            print(f"\n[HTTP ERROR] {e}")

                    def on_notification(_, data: bytearray):
                        nonlocal pcm_buffer
                        # Keepsake packet: [seq: 4 bytes][flags: 1 byte][pcm bytes: 5..end]
                        if len(data) > 5:
                            pcm_buffer.extend(data[5:])

                    await client.start_notify(AUDIO_CHAR_UUID, on_notification)
                    print("✓ Audio notifications active. Speak into the pendant!")

                    while client.is_connected:
                        await asyncio.sleep(0.5)
                        if len(pcm_buffer) >= 16000 or (time.monotonic() - last_flush >= 0.8 and pcm_buffer):
                            await flush()

            except Exception as e:
                print(f"\nConnection closed or error: {e}. Reconnecting in 2s...")
                await asyncio.sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=DEFAULT_WEBHOOK, help="Target webhook URL")
    args = parser.parse_args()
    try:
        asyncio.run(run(args.url))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()

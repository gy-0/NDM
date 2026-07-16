#!/usr/bin/env python3
"""Smoke-test the NDM host bridge without Chrome.

Examples (first ensure nothing else owns 127.0.0.1:10007):
  python3 reverse/tools/ws_bridge_client.py --expect-flow
  python3 reverse/tools/ws_bridge_client.py --listen-only --expect ShowPanelChrome=1
"""
from __future__ import annotations

import argparse
import asyncio
import sys

try:
    import websockets
except ImportError:
    websockets = None


async def main(args: argparse.Namespace) -> int:
    host, port, url = args.host, args.port, args.url
    uri = f"ws://{host}:{port}/download"
    async with websockets.connect(uri, subprotocols=["neatextension.v1"]) as ws:
        if ws.subprotocol != "neatextension.v1":
            print(f"unexpected subprotocol: {ws.subprotocol!r}", file=sys.stderr)
            return 2
        print(f"connected {uri} subprotocol={ws.subprotocol}")

        if not args.listen_only:
            msg = (
                f"1:GET\r\n"
                f"2:{url}\r\n"
                f"3:{args.filename}\r\n"
                f"6:{args.link_type}\r\n"
                f"4:ws_bridge_client\r\n"
                f"5:https://example.com/\r\n"
                f"Cookie: bridge_smoke=1\r\n"
            )
            await ws.send(msg)
            print(">> request sent")

        expected = set(args.expect)
        if args.expect_flow:
            expected.update(("waiting", "nowaiting"))
        received: set[str] = set()
        for _ in range(args.max_replies):
            try:
                reply = await asyncio.wait_for(ws.recv(), timeout=args.timeout)
                print("<<", reply)
                if isinstance(reply, str):
                    received.add(reply)
                if expected and expected.issubset(received):
                    break
            except asyncio.TimeoutError:
                break
        missing = expected - received
        if missing:
            print("missing expected messages:", ", ".join(sorted(missing)), file=sys.stderr)
            return 2
        return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=10007)
    p.add_argument("--url", default="https://example.com/file.bin")
    p.add_argument("--filename", default="bridge-smoke.bin")
    p.add_argument("--link-type", choices=("normal", "media", "hls"), default="normal")
    p.add_argument("--listen-only", action="store_true", help="do not send a download request")
    p.add_argument("--expect-flow", action="store_true", help="require waiting and nowaiting")
    p.add_argument("--expect", action="append", default=[], help="require an exact host message")
    p.add_argument("--timeout", type=float, default=3.0)
    p.add_argument("--max-replies", type=int, default=8)
    args = p.parse_args()
    if websockets is None:
        print("missing dependency: python3 -m pip install websockets", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(asyncio.run(main(args)))

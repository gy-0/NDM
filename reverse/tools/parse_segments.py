#!/usr/bin/env python3
"""Parse NDM segments.bin (24-byte records). See specs/04_SEGMENTS_FORMAT.md."""
from __future__ import annotations
import argparse
import struct
import sys
from pathlib import Path


def parse(data: bytes) -> list[dict]:
    if len(data) % 24 != 0:
        raise ValueError(f"size {len(data)} not multiple of 24")
    out = []
    for i in range(0, len(data), 24):
        order, seg_id, nxt, start, end = struct.unpack_from("<hhiqq", data, i)
        out.append(
            {
                "order": order,
                "segmentId": seg_id,
                "next": nxt,
                "start": start,
                "end": end,
                "length": end - start + 1 if end >= start else None,
            }
        )
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path)
    args = ap.parse_args()
    segs = parse(args.path.read_bytes())
    for s in segs:
        nxt = s["next"]
        nxt_s = "END" if nxt == -1 or nxt == 0xFFFFFFFF else str(nxt)
        print(
            f"order={s['order']:4d} id={s['segmentId']:4d} next={nxt_s:4s} "
            f"[{s['start']:>12} .. {s['end']:<12}] len={s['length']}  → seg.x{s['segmentId']}"
        )
    print(f"total records: {len(segs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

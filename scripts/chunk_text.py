#!/usr/bin/env python3
"""Split stdin text into <=800 byte UTF-8 safe chunks, NULL-separated on stdout."""
import sys

CHUNK_BYTES = 800
data = sys.stdin.buffer.read()
i = 0
while i < len(data):
    end = min(i + CHUNK_BYTES, len(data))
    # Don't split a multi-byte UTF-8 character
    while end > i and data[end - 1] & 0xC0 == 0x80:
        end -= 1
    if end == i:
        break
    sys.stdout.buffer.write(data[i:end])
    sys.stdout.buffer.write(b'\x00')
    i = end

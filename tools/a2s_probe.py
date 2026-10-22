#!/usr/bin/env python3
"""Ask a game server what it reports over the Steam A2S query protocol.
Usage: python3 tools/a2s_probe.py <ip> [port]      (default port 15637)
Prints the server info and, if the server supports it, the player list.
"""
import socket
import struct
import sys

HEADER = b"\xff\xff\xff\xff"


def ask(sock, addr, payload):
    sock.sendto(HEADER + payload, addr)
    data, _ = sock.recvfrom(4096)
    return data


def cstr(data, i):
    j = data.index(b"\x00", i)
    return data[i:j].decode("utf-8", "replace"), j + 1


def info(sock, addr):
    req = b"TSource Engine Query\x00"
    data = ask(sock, addr, req)
    if data[4:5] == b"A":  # challenge
        data = ask(sock, addr, req + data[5:9])
    if data[4:5] != b"I":
        return None
    i = 6
    name, i = cstr(data, i)
    _map, i = cstr(data, i)
    _folder, i = cstr(data, i)
    _game, i = cstr(data, i)
    i += 2
    return {"name": name, "players": data[i], "max_players": data[i + 1]}


def players(sock, addr):
    data = ask(sock, addr, b"U\xff\xff\xff\xff")
    if data[4:5] == b"A":
        data = ask(sock, addr, b"U" + data[5:9])
    if data[4:5] != b"D":
        return None
    count, i, out = data[5], 6, []
    for _ in range(count):
        i += 1  # index byte
        name, i = cstr(data, i)
        score, duration = struct.unpack_from("<if", data, i)
        i += 8
        out.append((name, score, round(duration / 60, 1)))
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    addr = (sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 15637)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(4)
    try:
        print("info:   ", info(sock, addr))
    except (OSError, ValueError, IndexError) as exc:
        print("info:    failed:", exc)
    try:
        result = players(sock, addr)
        print("players:", "not supported by this server" if result is None else result)
    except (OSError, ValueError, IndexError, struct.error) as exc:
        print("players: failed (no answer or unsupported):", exc)


if __name__ == "__main__":
    main()

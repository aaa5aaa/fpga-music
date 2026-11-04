#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pc_live_test.py — PC 上位机最小实时演奏测试

通过板载 USB-UART (dbg_rx/dbg_tx) 直连 FPGA，发送实时音符：
  0x40 NOTE_ON   [note, vel]
  0x41 NOTE_OFF  [note]
  0x42 ALL_NOTES_OFF

用法:
  pip install pyserial
  python pc_live_test.py COM6          # 默认力度 100，弹一遍 F4..C7 音阶
  python pc_live_test.py COM6 127      # 指定力度

注意:
  - 115200 8N1；
  - 用 USB 串口时不要让 ESP32 同时发数据（蓝牙优先会抢 UART）；
  - 程序 Ctrl+C 退出前会发送 ALL_NOTES_OFF。
"""

import sys
import time

import serial

CMD_NOTE_ON = 0x40
CMD_NOTE_OFF = 0x41
CMD_ALL_OFF = 0x42

# 32 键 = F4..C7，和实体琴布局一致
NOTE_COUNT = 32


def crc16(data: bytes) -> int:
    """CCITT-FALSE: poly=0x1021, init=0xFFFF, 覆盖 CMD/LEN/PAYLOAD"""
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def frame(cmd: int, payload: bytes = b"") -> bytes:
    if len(payload) > 63:
        raise ValueError("payload too long")
    body = bytes([cmd, len(payload)]) + payload
    c = crc16(body)
    return b"\xAA\x55" + body + bytes([c & 0xFF, (c >> 8) & 0xFF])


def note_on(note: int, vel: int) -> bytes:
    return frame(CMD_NOTE_ON, bytes([note & 0x1F, vel & 0xFF]))


def note_off(note: int) -> bytes:
    return frame(CMD_NOTE_OFF, bytes([note & 0x1F]))


def all_off() -> bytes:
    return frame(CMD_ALL_OFF)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    port = sys.argv[1]
    vel = int(sys.argv[2]) if len(sys.argv) > 2 else 100

    ser = serial.Serial(port, 115200, timeout=0, write_timeout=1)
    print(f"open {port} 115200, velocity={vel}")
    print("弹一遍 F4..C7 音阶，Ctrl+C 停止")

    try:
        while True:
            for note in range(NOTE_COUNT):
                ser.write(note_on(note, vel))
                time.sleep(0.18)
                ser.write(note_off(note))
                time.sleep(0.03)
            time.sleep(0.6)
    except KeyboardInterrupt:
        pass
    finally:
        ser.write(all_off())
        ser.flush()
        ser.close()
        print("\nALL_NOTES_OFF sent, port closed")


if __name__ == "__main__":
    main()

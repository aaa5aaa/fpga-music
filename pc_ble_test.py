#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pc_ble_test.py — PC 通过 BLE 直连 ESP32-C3 测试实时音符

协议与 USB-UART/小程序一致：
  AA 55 | CMD | LEN | PAYLOAD | CRC16
  0x40 NOTE_ON [note, vel]
  0x41 NOTE_OFF [note]
  0x42 ALL_NOTES_OFF
  0x01 PING

用法:
  pip install bleak
  python pc_ble_test.py                 # 自动扫描 ACG720-Synth
  python pc_ble_test.py <BLE地址>       # 直接连接
  python pc_ble_test.py <地址> 127      # 指定力度

注意:
  - 电脑需要蓝牙；
  - ESP32 固件需在广播 ACG720-Synth；
  - Ctrl+C 退出前会发 ALL_NOTES_OFF。
"""

import asyncio
import sys

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
RX_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  # 手机/PC -> ESP32
TX_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  # ESP32 -> 手机/PC

CMD_PING = 0x01
CMD_NOTE_ON = 0x40
CMD_NOTE_OFF = 0x41
CMD_ALL_OFF = 0x42

NOTE_COUNT = 32


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def frame(cmd: int, payload: bytes = b"") -> bytes:
    body = bytes([cmd, len(payload)]) + payload
    c = crc16(body)
    return b"\xAA\x55" + body + bytes([c & 0xFF, (c >> 8) & 0xFF])


def note_on(note, vel):
    return frame(CMD_NOTE_ON, bytes([note & 0x1F, vel & 0xFF]))


def note_off(note):
    return frame(CMD_NOTE_OFF, bytes([note & 0x1F]))


def all_off():
    return frame(CMD_ALL_OFF)


class Link:
    def __init__(self, client):
        self.client = client
        self.buf = bytearray()
        self.replies = []

    def on_notify(self, _sender, data):
        self.buf.extend(data)
        while len(self.buf) >= 6:
            if self.buf[0] != 0xAA or self.buf[1] != 0x55:
                del self.buf[0]
                continue
            n = self.buf[3]
            if len(self.buf) < 6 + n:
                return
            f = bytes(self.buf[:6 + n])
            del self.buf[:6 + n]
            self.replies.append(f)
            print("RX:", f.hex(" "))

    async def send(self, data: bytes):
        await self.client.write_gatt_char(RX_UUID, data, response=False)


async def find_synth():
    print("扫描 BLE 设备...")
    devices = await BleakScanner.discover(timeout=10.0)
    for d in devices:
        if (d.name or "") == "ACG720-Synth":
            print("找到:", d.address, d.name)
            return d.address
    return None


async def main():
    address = None
    vel = 100
    loops = 0          # 0 = 无限循环
    if len(sys.argv) >= 2:
        address = sys.argv[1]
    if len(sys.argv) >= 3:
        vel = int(sys.argv[2])
    if len(sys.argv) >= 4:
        loops = int(sys.argv[3])

    if not address:
        address = await find_synth()
    if not address:
        print("没有找到 ACG720-Synth，确认 ESP32 已上电并广播")
        return

    print("连接", address)
    async with BleakClient(address, timeout=15.0) as client:
        print("已连接, MTU=", getattr(client, "mtu_size", "?"))
        link = Link(client)
        await client.start_notify(TX_UUID, link.on_notify)

        await link.send(frame(CMD_PING))
        await asyncio.sleep(0.7)
        if not link.replies:
            print("PING 无回复：检查 ESP32 是否在桥接、FPGA 是否已配置")
            return

        # 探测实时音符命令：旧固件会回 status=1/err=1
        link.replies.clear()
        await link.send(note_on(0, 100))
        await asyncio.sleep(0.25)
        await link.send(note_off(0))
        await asyncio.sleep(0.25)
        for f in link.replies:
            if len(f) >= 12 and f[2] == 0xE0 and f[4] == CMD_NOTE_ON and f[5] != 0:
                print("当前 FPGA 不支持 0x40 NOTE_ON（回 status=%d err=%d）" % (f[5], f[11]))
                print("请先下载最新 fpga_project.fs（16:13 之后）")
                return

        print("实时音符命令正常，开始弹 F4..C7，力度", vel,
              ("，%d 遍后退出" % loops) if loops else "，Ctrl+C 停止")
        rounds = 0
        try:
            while True:
                for note in range(NOTE_COUNT):
                    await link.send(note_on(note, vel))
                    await asyncio.sleep(0.18)
                    await link.send(note_off(note))
                    await asyncio.sleep(0.03)
                rounds += 1
                if loops and rounds >= loops:
                    break
                await asyncio.sleep(0.6)
        except KeyboardInterrupt:
            pass
        finally:
            try:
                await link.send(all_off())
                await asyncio.sleep(0.1)
            except Exception:
                pass
            print("ALL_NOTES_OFF sent")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

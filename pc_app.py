#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pc_app.py — ACG720 PC 上位机（PySide6 多页面框架）

页面:
  主页 / 钢琴 / 曲库 / 录音 / 显示 / 设置

当前版本:
  - 主页卡片导航
  - 钢琴页完整可用（13 黑 19 白、鼠标、电脑键盘、力度、主音量）
  - 曲库/录音/显示为占位页，后续接入
  - BLE 服务页面间共享

用法:
  pip install PySide6 bleak
  python pc_app.py
"""

import asyncio
import json
import math
import threading
import time

import numpy as np
import serial
from serial.tools import list_ports

from PySide6.QtCore import Qt, Signal, QObject, QPointF, QRectF, QTimer
from PySide6.QtGui import QPainter, QColor, QPen, QFont, QBrush, QPainterPath, QPolygonF
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QStackedWidget, QFrame, QSlider, QCheckBox,
    QGridLayout, QSizePolicy, QTableWidget, QTableWidgetItem,
    QHeaderView, QLineEdit, QFileDialog, QSpinBox, QComboBox
)

from bleak import BleakClient, BleakScanner

from pc_ble_test import (
    RX_UUID, TX_UUID, frame, note_on, note_off, all_off, CMD_PING
)

N_NOTES = 32
SYNTH_NAME = "ACG720-Synth"
DEFAULT_ADDRESS = "9C:96:D5:B1:61:6A"

CMD_SAVE = 0x26
CMD_LOAD = 0x27
CMD_DELETE = 0x28
CMD_LIST = 0x29
CMD_NAME = 0x2A
CMD_REC = 0x2C
CMD_STATUS = 0x30
CMD_LIVE = 0x48
CMD_LIVE_PARAMS = 0x49
CMD_SCOPE = 0x50
CMD_SCOPE_CHUNK = 0x51
CMD_PLAY = 0x23
CMD_STOP = 0x24
CMD_SONG_BEGIN = 0x20
CMD_SONG_EVENTS = 0x21
CMD_SONG_END = 0x22

WHITE_NOTES = [n for n in range(N_NOTES) if (n % 12) not in (1, 3, 5, 8, 10)]
BLACK_NOTES = [n for n in range(N_NOTES) if (n % 12) in (1, 3, 5, 8, 10)]


def utf8_bytes(text, max_len):
    data = (text or "").encode("utf-8")[:max_len]
    return list(data) + [0] * (max_len - len(data))


def decode_name(data):
    clean = bytearray()
    for b in data:
        if b == 0 or b == 0xFF:
            break
        clean.append(b)
    try:
        return clean.decode("utf-8", "ignore")
    except Exception:
        return ""


# ============================================================================
# PC 演奏录音（记录 PC 钢琴页的音符事件）
# ============================================================================
class NoteRecorder:
    def __init__(self):
        self.active = False
        self.events = []
        self.held = {}
        self.last_ms = 0
        self.start_ms = 0

    def start(self):
        self.active = True
        self.events = []
        self.held.clear()
        self.last_ms = time.monotonic()
        self.start_ms = self.last_ms

    def _append(self, note, vel):
        now = time.monotonic()
        delta = int((now - self.last_ms) * 1000)
        delta = max(0, min(65535, delta))
        self.events.append([delta, int(note), int(vel)])
        self.last_ms = now

    def note_on(self, note, vel):
        if not self.active or note in self.held:
            return
        self.held[note] = int(vel)
        self._append(note, vel)

    def note_off(self, note):
        if not self.active or note not in self.held:
            return
        del self.held[note]
        self._append(note, 0)

    def release_all(self):
        for note in list(self.held.keys()):
            self.note_off(note)

    def stop(self):
        self.release_all()
        self.active = False
        return list(self.events)

    def elapsed_ms(self):
        return int((time.monotonic() - self.start_ms) * 1000) if self.active else 0


class SongTransfer(QObject):
    """把事件列表通过 BLE 发给 FPGA，并可选保存到槽位。"""
    progress = Signal(int, str)
    finished = Signal(bool, str)

    def __init__(self, ble, events, name, slot, save=True):
        super().__init__()
        self.ble = ble
        self.events = events
        self.name = name
        self.slot = slot
        self.save = save
        self.attempt = 0
        self.frames = []
        self.idx = 0
        self.state = None
        self._done = False

        self.timer = QTimer(self)
        self.timer.setInterval(10)
        self.timer.timeout.connect(self._tick)
        self.wait = QTimer(self)
        self.wait.setSingleShot(True)
        self.wait.timeout.connect(self._timeout)
        ble.frameReceived.connect(self._on_frame)

    def start(self):
        if not self.ble.connected:
            self._finish(False, "BLE 未连接")
            return
        self.attempt += 1
        words = []
        for d, n, v in self.events:
            words.append(((int(d) & 0xFFFF) << 16) |
                         ((int(n) & 0xFF) << 8) | (int(v) & 0xFF))
        total = sum(words) & 0xFFFFFFFF
        self.frames = [frame(CMD_SONG_BEGIN,
                             bytes([len(self.events) & 0xFF,
                                    (len(self.events) >> 8) & 0xFF]))]
        for i in range(0, len(words), 15):
            payload = bytearray()
            for w in words[i:i + 15]:
                payload += bytes([w & 0xFF, (w >> 8) & 0xFF,
                                  (w >> 16) & 0xFF, (w >> 24) & 0xFF])
            self.frames.append(frame(CMD_SONG_EVENTS, bytes(payload)))
        self.frames.append(frame(CMD_SONG_END, bytes([
            total & 0xFF, (total >> 8) & 0xFF,
            (total >> 16) & 0xFF, (total >> 24) & 0xFF])))
        self.idx = 0
        self.state = "sending"
        self.progress.emit(0, "发送中 0%")
        self.timer.start()

    def _tick(self):
        if self.state != "sending":
            self.timer.stop()
            return
        if self.idx >= len(self.frames):
            self.timer.stop()
            self.state = "wait_end"
            self.wait.start(8000)
            return
        self.ble.send(self.frames[self.idx])
        self.idx += 1
        pct = int(self.idx * 100 / max(1, len(self.frames)))
        self.progress.emit(pct, "发送中 %d%%" % pct)

    def _timeout(self):
        if self.state == "wait_end":
            if self.attempt < 3:
                self.progress.emit(0, "SONG_END 超时，重发...")
                QTimer.singleShot(300, self.start)
            else:
                self._finish(False, "导入失败：SONG_END 超时")
        elif self.state == "wait_save":
            self._finish(False, "保存超时")

    def _on_frame(self, f):
        if len(f) < 12 or f[2] != 0xE0:
            return
        cmd, status, err = f[4], f[5], f[11]
        if self.state == "wait_end" and cmd == CMD_SONG_END:
            self.wait.stop()
            if status == 0 and err == 0:
                if self.save:
                    self.state = "wait_save"
                    payload = [self.slot & 0xFF] + utf8_bytes(self.name, 16)
                    self.ble.send(frame(CMD_SAVE, bytes(payload)))
                    self.wait.start(8000)
                else:
                    self._finish(True, "导入成功（仅 RAM）")
            else:
                self.state = None
                if self.attempt < 3:
                    self.progress.emit(0, "校验失败，重发...")
                    QTimer.singleShot(300, self.start)
                else:
                    self._finish(False, "校验失败 status=%d err=%d" % (status, err))
        elif self.state == "wait_save" and cmd == CMD_SAVE:
            self.wait.stop()
            if status == 0 and err == 0:
                self._finish(True, "录音已保存到槽位 %02d" % (self.slot + 1))
            else:
                self._finish(False, "保存失败 status=%d err=%d" % (status, err))

    def _finish(self, ok, msg):
        if self._done:
            return
        self._done = True
        self.state = None
        self.timer.stop()
        self.wait.stop()
        self.finished.emit(ok, msg)


def is_black(note):
    return (note % 12) in (1, 3, 5, 8, 10)


def note_name(note):
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    midi = 60 + note   # FPGA note 0 = C4
    return names[midi % 12] + str(midi // 12 - 1)


# ============================================================================
# BLE 服务：后台线程 + Qt 信号
# ============================================================================
class BleService(QObject):
    statusChanged = Signal(str)
    stateChanged = Signal(str)
    connectedChanged = Signal(bool)
    replyReceived = Signal(bytes)
    frameReceived = Signal(bytes)

    def __init__(self, address=DEFAULT_ADDRESS):
        super().__init__()
        self.address = address
        self.stop_evt = threading.Event()
        self.thread = None
        self.loop = None
        self.queue = None
        self.connected = False
        self.state = "idle"
        self.mtu = 0
        self.rxbuf = bytearray()
        self._operation = None
        self._client = None
        self._restart_pending = False
        self._cancel_issued = False
        self._error = ""
        # Qt owns restarts. Never launch another BLE worker until the old
        # worker AND its asyncio loop have completely finished cleanup.
        self._reaper = QTimer(self)
        self._reaper.setInterval(25)
        self._reaper.timeout.connect(self._reap_worker)

    def _set_state(self, state, text):
        self.state = state
        self.stateChanged.emit(state)
        self.statusChanged.emit(text)

    def start(self):
        if self.thread and self.thread.is_alive():
            if self.stop_evt.is_set():
                self._restart_pending = True
                self._set_state("disconnecting", "正在释放旧连接，完成后自动重连...")
            return
        self._launch()

    def _launch(self):
        self._restart_pending = False
        self.stop_evt.clear()
        self._cancel_issued = False
        self._error = ""
        self.rxbuf.clear()
        self._set_state("scanning", "扫描 ACG720-Synth...")
        # Freeze this attempt's selection; a later rescan may clear address.
        address = self.address
        self.thread = threading.Thread(target=self._run, args=(address,), daemon=True)
        self.thread.start()
        self._reaper.start()

    def _reap_worker(self):
        if self.thread and self.thread.is_alive():
            return
        self.thread = None
        self._reaper.stop()
        if self._restart_pending:
            self._launch()

    def send(self, data):
        loop, queue = self.loop, self.queue
        if not self.connected or self.stop_evt.is_set() or not loop or not queue:
            return

        def enqueue():
            if self.connected and not self.stop_evt.is_set() and self.queue is queue:
                queue.put_nowait(bytes(data))
        try:
            loop.call_soon_threadsafe(enqueue)
        except RuntimeError:
            # Loop may have closed between the UI's check and this call.
            pass

    def _cancel_operation(self):
        # Runs only on the BLE loop. A second click must not cancel disconnect().
        task = self._operation
        if task and not task.done() and not self._cancel_issued:
            self._cancel_issued = True
            task.cancel()

    def _request_stop(self):
        self.stop_evt.set()
        if self.thread and self.thread.is_alive():
            self._set_state("disconnecting", "正在断开并释放蓝牙连接...")
            loop = self.loop
            if loop:
                try:
                    loop.call_soon_threadsafe(self._cancel_operation)
                except RuntimeError:
                    pass
            self._reaper.start()
        else:
            self.connected = False
            self.mtu = 0
            self.connectedChanged.emit(False)
            self._set_state("idle", "已主动断开")

    def stop(self):
        self._restart_pending = False
        self._request_stop()

    def restart(self):
        self._restart_pending = True
        if self.thread and self.thread.is_alive():
            self._request_stop()
            self.statusChanged.emit("正在释放旧连接，完成后自动重连...")
        else:
            self._launch()

    def _disconnected(self, client):
        if client is not self._client or self.stop_evt.is_set() or not self.connected:
            return
        self._error = "蓝牙连接意外断开，请重新连接"
        self.connected = False
        self.mtu = 0
        self.connectedChanged.emit(False)
        self._set_state("disconnecting", "连接已丢失，正在释放蓝牙资源...")
        self._cancel_operation()

    def _notify(self, _sender, data):
        if self.stop_evt.is_set():
            return
        self.rxbuf.extend(data)
        while len(self.rxbuf) >= 6:
            if self.rxbuf[0] != 0xAA or self.rxbuf[1] != 0x55:
                del self.rxbuf[0]
                continue
            n = self.rxbuf[3]
            if len(self.rxbuf) < 6 + n:
                return
            f = bytes(self.rxbuf[:6 + n])
            del self.rxbuf[:6 + n]
            self.replyReceived.emit(f)
            self.frameReceived.emit(f)

    async def _session(self, address):
        # Use a freshly discovered BLEDevice rather than passing a stale address
        # to BleakClient (which otherwise performs an implicit second scan).
        found = await BleakScanner.discover(timeout=8.0, return_adv=True)
        device = None
        for candidate, adv in found.values():
            if address:
                match = candidate.address.casefold() == address.casefold()
            else:
                match = (adv.local_name or candidate.name or "") == SYNTH_NAME
            if match:
                device = candidate
                break
        if device is None:
            raise RuntimeError("未找到设备，请确认设备已开机且未被手机/其他程序占用；也可点击重新扫描")
        if self.stop_evt.is_set():
            return
        self.address = device.address
        self._set_state("connecting", "连接 %s..." % device.address)
        client = BleakClient(device, timeout=15.0,
                             disconnected_callback=self._disconnected,
                             winrt={"use_cached_services": False})
        self._client = client
        await client.connect()
        await asyncio.wait_for(client.start_notify(TX_UUID, self._notify), timeout=10.0)
        await asyncio.wait_for(client.write_gatt_char(RX_UUID, frame(CMD_PING), response=False), timeout=5.0)
        if self.stop_evt.is_set() or not client.is_connected:
            return
        self.mtu = int(getattr(client, "mtu_size", 0) or 0)
        self.connected = True
        self._set_state("connected", "已连接  MTU=%s" % self.mtu)
        self.connectedChanged.emit(True)
        while not self.stop_evt.is_set():
            if not client.is_connected:
                raise RuntimeError("蓝牙连接已丢失，请重新连接")
            try:
                data = await asyncio.wait_for(self.queue.get(), timeout=0.2)
            except asyncio.TimeoutError:
                continue
            await asyncio.wait_for(client.write_gatt_char(RX_UUID, data, response=False), timeout=5.0)

    async def _run_async(self, address):
        self.loop = asyncio.get_running_loop()
        self.queue = asyncio.Queue()
        if self.stop_evt.is_set():
            return
        self._operation = asyncio.create_task(self._session(address))
        try:
            await self._operation
        except asyncio.CancelledError:
            # Manual stop and the disconnect callback both converge on cleanup.
            pass
        except Exception as exc:
            if not self.stop_evt.is_set():
                self._error = "连接/通信失败: %s" % (str(exc) or type(exc).__name__)
        finally:
            self._operation = None
            self.connected = False
            self.mtu = 0
            self.connectedChanged.emit(False)
            client = self._client
            if client:
                self._set_state("disconnecting", "正在释放蓝牙连接...")
                try:
                    if client.is_connected:
                        await asyncio.wait_for(client.write_gatt_char(RX_UUID, all_off(), response=False), timeout=1.0)
                except Exception:
                    pass
                try:
                    # Bleak disconnect removes notifications and disposes WinRT
                    # services/session/device. Do this even after connect fails.
                    await asyncio.wait_for(client.disconnect(), timeout=10.0)
                except Exception as exc:
                    self._error = "蓝牙资源释放失败: %s；若重连仍失败请重启程序" % (str(exc) or type(exc).__name__)
                await asyncio.sleep(0.3)  # Let the peripheral resume advertising.
            self._client = None

    def _run(self, address):
        try:
            asyncio.run(self._run_async(address))
        except Exception as exc:
            self._error = "BLE 异常: %s" % (str(exc) or type(exc).__name__)
        finally:
            # No closed-loop / old-queue references survive into another attempt.
            self.loop = None
            self.queue = None
            self._operation = None
            self._client = None
            self.connected = False
            self.mtu = 0
            self.connectedChanged.emit(False)
            if self._error:
                self._set_state("failed", self._error)
            else:
                self._set_state("idle", "已断开")

# ============================================================================
# USB 串口服务：演奏命令走有线，BLE 只留曲库/遥测
# ============================================================================
class SerialService(QObject):
    frameReceived = Signal(bytes)
    connectedChanged = Signal(bool)
    statusChanged = Signal(str)

    def __init__(self):
        super().__init__()
        self.connected = False
        self.port = None
        self.ser = None
        self.thread = None
        self.stop_evt = threading.Event()

    @staticmethod
    def ports():
        try:
            return [p.device for p in list_ports.comports()]
        except Exception:
            return []

    def open_port(self, port):
        self.close_port()
        try:
            self.ser = serial.Serial(port, 115200, timeout=0.05)
        except Exception as e:
            self.statusChanged.emit("串口打开失败: %s" % e)
            return False
        self.port = port
        self.connected = True
        self.stop_evt.clear()
        self.connectedChanged.emit(True)
        self.statusChanged.emit("USB 串口已连接 %s" % port)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return True

    def close_port(self):
        self.stop_evt.set()
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=1.0)
        if self.ser:
            try:
                self.ser.close()
            except Exception:
                pass
        self.ser = None
        self.connected = False
        self.port = None
        self.connectedChanged.emit(False)

    def send(self, data):
        if self.connected and self.ser:
            try:
                self.ser.write(data)
            except Exception:
                self.close_port()

    def _run(self):
        rx = bytearray()
        while not self.stop_evt.is_set():
            try:
                chunk = self.ser.read(512)
            except Exception:
                break
            if chunk:
                rx.extend(chunk)
                while len(rx) >= 6:
                    if rx[0] != 0xAA or rx[1] != 0x55:
                        del rx[0]
                        continue
                    n = rx[3]
                    if len(rx) < 6 + n:
                        break
                    self.frameReceived.emit(bytes(rx[:6 + n]))
                    del rx[:6 + n]
        self.connected = False
        self.connectedChanged.emit(False)
        self.statusChanged.emit("USB 串口已断开")

# ============================================================================
# 钢琴控件
# ============================================================================
class LiveState(QObject):
    changed = Signal()

    def __init__(self):
        super().__init__()
        self.active = {}

    def note_on(self, note, vel):
        self.active[int(note)] = int(vel)
        self.changed.emit()

    def note_off(self, note):
        if int(note) in self.active:
            del self.active[int(note)]
            self.changed.emit()

    def clear(self):
        if self.active:
            self.active.clear()
            self.changed.emit()


class PianoWidget(QWidget):
    noteOn = Signal(int, int)      # note, base velocity
    noteOff = Signal(int)

    KEYMAP = {}

    def __init__(self):
        super().__init__()
        self.setFocusPolicy(Qt.StrongFocus)
        self.setMinimumHeight(300)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

        self.velocity = 100
        self.master = 100
        self.position_velocity = False
        self.mono = False
        self.active = {}            # note -> base velocity
        self.external = set()       # 实体琴按键 (遥测)
        self.kb_down = {}           # Qt key -> note
        self.mouse_note = None
        self.key_rects = []         # (note, QRectF, is_black)

        self._build_keymap()

    def _build_keymap(self):
        # 白键：A..' + Z..,
        white_keys = [
            Qt.Key_A, Qt.Key_S, Qt.Key_D, Qt.Key_F, Qt.Key_G,
            Qt.Key_H, Qt.Key_J, Qt.Key_K, Qt.Key_L,
            Qt.Key_Semicolon, Qt.Key_Apostrophe,
            Qt.Key_Z, Qt.Key_X, Qt.Key_C, Qt.Key_V, Qt.Key_B,
            Qt.Key_N, Qt.Key_M, Qt.Key_Comma,
        ]
        # 黑键：Q..P [ ] \（中文键盘上反斜杠键显示“、”）
        black_keys = [
            Qt.Key_Q, Qt.Key_W, Qt.Key_E, Qt.Key_R, Qt.Key_T,
            Qt.Key_Y, Qt.Key_U, Qt.Key_I, Qt.Key_O, Qt.Key_P,
            Qt.Key_BracketLeft, Qt.Key_BracketRight, Qt.Key_Backslash,
        ]
        self.KEYMAP = {}
        for k, n in zip(white_keys, WHITE_NOTES):
            self.KEYMAP[k] = n
        for k, n in zip(black_keys, BLACK_NOTES):
            self.KEYMAP[k] = n

    def set_velocity(self, v):
        self.velocity = max(1, min(127, int(v)))

    def set_master(self, v):
        self.master = max(0, min(100, int(v)))
        for note, base in list(self.active.items()):
            self.noteOn.emit(note, base)
        self.update()

    def set_position_velocity(self, enabled):
        self.position_velocity = bool(enabled)

    def set_external_keys(self, mask):
        keys = {i for i in range(32) if (mask >> i) & 1}
        if keys != self.external:
            self.external = keys
            self.update()

    def set_mono(self, enabled):
        self.mono = bool(enabled)
        if self.mono and len(self.active) > 1:
            keep = list(self.active.keys())[-1]
            for n in list(self.active.keys()):
                if n != keep:
                    self._end_note(n)

    def _scaled(self, base):
        return max(1, min(127, int(round(base * self.master / 100.0))))

    def _start_note(self, note, base):
        if self.mono:
            for n in list(self.active.keys()):
                if n != note:
                    self._end_note(n)
        if note in self.active:
            self.active[note] = base
            self.noteOn.emit(note, base)
        else:
            self.active[note] = base
            self.noteOn.emit(note, base)
        self.update()

    def _end_note(self, note):
        if note in self.active:
            del self.active[note]
            self.noteOff.emit(note)
            self.update()

    def all_off(self):
        for note in list(self.active.keys()):
            self._end_note(note)
        self.kb_down.clear()
        self.mouse_note = None
        self.update()

    # 画键
    def paintEvent(self, _event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        w = self.width()
        h = self.height()
        margin = 6.0
        ww = (w - 2 * margin) / 19.0
        bw = ww * 0.62
        self.key_rects.clear()

        # 白键
        for idx, n in enumerate(WHITE_NOTES):
            x0 = margin + idx * ww
            r = QRectF(x0, 0, ww - 1, h)
            self.key_rects.append((n, r, False))
            active = n in self.active
            ext = n in self.external
            p.setBrush(QBrush(QColor("#ff6b6b" if active else
                                     "#7bd88f" if ext else "#f2f2f2")))
            p.setPen(QPen(QColor("#555555"), 1.5))
            p.drawRoundedRect(r.adjusted(1, 0, -1, -1), 3, 3)
            if idx % 3 == 0:
                p.setPen(QPen(QColor("#777777")))
                p.setFont(QFont("Consolas", 8))
                p.drawText(r.adjusted(0, 0, 0, -8), Qt.AlignHCenter | Qt.AlignBottom,
                           note_name(n))

        # 黑键覆盖
        for n in BLACK_NOTES:
            before = sum(1 for m in range(n) if not is_black(m))
            center = margin + before * ww
            r = QRectF(center - bw / 2, 0, bw, h * 0.62)
            self.key_rects.append((n, r, True))
            active = n in self.active
            ext = n in self.external
            p.setBrush(QBrush(QColor("#4ea1ff" if active else
                                     "#2fbf71" if ext else "#15202b")))
            p.setPen(QPen(QColor("#000000"), 1.5))
            p.drawRoundedRect(r.adjusted(1, 0, -1, 0), 3, 3)

        p.end()

    def _hit(self, pos: QPointF):
        # 黑键优先
        for n, r, black in reversed(self.key_rects):
            if r.contains(pos):
                return n
        return None

    def _base_velocity(self, note, pos):
        if not self.position_velocity:
            return self.velocity
        for n, r, _black in self.key_rects:
            if n == note:
                rel = max(0.0, min(1.0, (pos.y() - r.top()) / max(1.0, r.height())))
                return max(8, min(127, int(8 + rel * 119)))
        return 100

    def mousePressEvent(self, e):
        self.setFocus()
        self._play_at(e.position())

    def mouseMoveEvent(self, e):
        if e.buttons() & Qt.LeftButton:
            self._play_at(e.position())

    def mouseReleaseEvent(self, _e):
        if self.mouse_note is not None:
            self._end_note(self.mouse_note)
            self.mouse_note = None

    def _play_at(self, pos):
        n = self._hit(pos)
        if n is None:
            if self.mouse_note is not None:
                self._end_note(self.mouse_note)
                self.mouse_note = None
            return
        if n == self.mouse_note:
            return
        if self.mouse_note is not None:
            self._end_note(self.mouse_note)
        self.mouse_note = n
        self._start_note(n, self._base_velocity(n, pos))

    def keyPressEvent(self, e):
        if e.isAutoRepeat():
            return
        note = self.KEYMAP.get(e.key())
        if note is None:
            return
        if note not in self.kb_down.values():
            self.kb_down[e.key()] = note
            self._start_note(note, self.velocity)
        e.accept()

    def keyReleaseEvent(self, e):
        if e.isAutoRepeat():
            return
        note = self.kb_down.pop(e.key(), None)
        if note is not None:
            self._end_note(note)
        e.accept()

    def focusOutEvent(self, _e):
        self.all_off()


# ============================================================================
# 页面基类
# ============================================================================
class Page(QWidget):
    backRequested = Signal()

    def __init__(self, title):
        super().__init__()
        self.setObjectName("Page")
        self.layout = QVBoxLayout(self)
        self.layout.setContentsMargins(24, 18, 24, 18)
        self.layout.setSpacing(12)

        top = QHBoxLayout()
        back = QPushButton("← 返回主页")
        back.setObjectName("BackBtn")
        back.clicked.connect(self.backRequested.emit)
        top.addWidget(back)
        t = QLabel(title)
        t.setObjectName("PageTitle")
        top.addWidget(t)
        top.addStretch(1)
        self.layout.addLayout(top)


class HomeCard(QFrame):
    clicked = Signal()

    def mousePressEvent(self, e):
        if e.button() == Qt.LeftButton:
            self.clicked.emit()
        super().mousePressEvent(e)


class HomePage(QWidget):
    openPage = Signal(str)

    def __init__(self, ble, serial=None):
        super().__init__()
        self.ble = ble
        self.ser = serial
        self.setObjectName("Home")
        root = QVBoxLayout(self)
        root.setContentsMargins(38, 30, 38, 30)
        root.setSpacing(16)

        hero = QFrame()
        hero.setObjectName("Hero")
        h = QHBoxLayout(hero)
        h.setContentsMargins(26, 22, 26, 22)
        left = QVBoxLayout()
        eye = QLabel("FPGA REAL-TIME SYNTHESIZER")
        eye.setObjectName("Eyebrow")
        left.addWidget(eye)
        title = QLabel("ACG720 合成器控制台")
        title.setObjectName("HomeTitle")
        left.addWidget(title)
        sub = QLabel("32 声部实时合成 · 16 槽曲库 · BLE 无线控制")
        sub.setObjectName("HeroSub")
        left.addWidget(sub)
        h.addLayout(left, 1)
        right = QVBoxLayout()
        right.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        self.status = QLabel("BLE：初始化...")
        self.status.setObjectName("StatusChip")
        right.addWidget(self.status)

        usb = QHBoxLayout()
        self.port_box = QComboBox()
        self.port_box.setMinimumWidth(110)
        self.port_refresh()
        self.usb_btn = QPushButton("连接USB")
        self.usb_btn.clicked.connect(self.toggle_usb)
        self.usb_test = QPushButton("测试USB")
        self.usb_test.clicked.connect(self.usb_probe)
        usb.addWidget(self.port_box)
        usb.addWidget(self.usb_btn)
        usb.addWidget(self.usb_test)
        right.addLayout(usb)
        self.usb_status = QLabel("USB：未连接")
        self.usb_status.setObjectName("StatusChip")
        right.addWidget(self.usb_status)
        h.addLayout(right)
        if self.ser is not None:
            self.ser.statusChanged.connect(self.usb_status.setText)
            self.ser.connectedChanged.connect(self.on_usb_conn)
            self.ser.frameReceived.connect(self.on_usb_frame)
        root.addWidget(hero)

        sec = QLabel("功能模块")
        sec.setObjectName("SectionLabel")
        root.addWidget(sec)
        grid = QGridLayout()
        grid.setSpacing(14)
        cards = [
            ("piano", "01", "🎹  钢琴键盘", "演奏 · 录音 · 力度 / 弯音 / ADSR", "进入演奏"),
            ("library", "02", "📚  PC 曲库", "16 槽 · 导入 / 保存 / 加载 / 播放", "打开曲库"),
            ("scope", "03", "📈  显示", "波形 / 频谱 / 李萨如", "查看显示"),
            ("settings", "04", "⚙  设置 / 连接", "BLE 扫描 · 重连 · 版本 · 诊断", "打开设置"),
        ]
        for i, (key, idx, name, desc, action) in enumerate(cards):
            card = HomeCard()
            card.setObjectName("Card")
            card.setCursor(Qt.PointingHandCursor)
            card.setMinimumHeight(140)
            lay = QVBoxLayout(card)
            lay.setContentsMargins(22, 18, 22, 14)
            top = QHBoxLayout()
            num = QLabel(idx)
            num.setObjectName("CardIndex")
            top.addWidget(num)
            top.addStretch(1)
            arrow = QLabel("→")
            arrow.setObjectName("CardArrow")
            top.addWidget(arrow)
            lay.addLayout(top)
            n = QLabel(name)
            n.setObjectName("CardTitle")
            d = QLabel(desc)
            d.setObjectName("CardDesc")
            d.setWordWrap(True)
            act = QLabel(action)
            act.setObjectName("CardAction")
            lay.addWidget(n)
            lay.addWidget(d)
            lay.addStretch(1)
            lay.addWidget(act)
            card.clicked.connect(lambda k=key: self.openPage.emit(k))
            grid.addWidget(card, i // 2, i % 2)
        root.addLayout(grid, 1)
        foot = QLabel("SELECT A MODULE TO BEGIN  ·  ACG720 / FPGA SYNTH")
        foot.setObjectName("FooterLabel")
        root.addWidget(foot)
        ble.statusChanged.connect(self.status.setText)
        ble.connectedChanged.connect(
            lambda ok: self.status.setText("● 已连接" if ok else "○ 未连接"))

    def port_refresh(self):
        cur = self.port_box.currentText()
        self.port_box.clear()
        for p in SerialService.ports():
            self.port_box.addItem(p)
        if cur:
            i = self.port_box.findText(cur)
            if i >= 0:
                self.port_box.setCurrentIndex(i)

    def toggle_usb(self):
        if self.ser is None:
            return
        if self.ser.connected:
            self.ser.close_port()
        else:
            port = self.port_box.currentText()
            if port:
                self.ser.open_port(port)

    def on_usb_conn(self, ok):
        self.usb_btn.setText("断开USB" if ok else "连接USB")
        if ok:
            self.port_refresh()

    def usb_probe(self):
        if self.ser is None or not self.ser.connected:
            self.usb_status.setText("先连接USB")
            return
        self.ser.send(frame(CMD_STATUS))
        self.usb_status.setText("已发 STATUS，等待回复...")

    def on_usb_frame(self, f):
        self.usb_status.setText("USB回复: %s" % f.hex(" "))

    def on_show(self):
        self.status.setText("● 已连接" if self.ble.connected else "○ 未连接")


class PianoPage(Page):
    def __init__(self, ble, recorder=None, live=None, serial=None):
        super().__init__("钢琴键盘")
        self.ser = serial
        self.ble = ble
        self.live = live or LiveState()
        self.recording = False
        self.rec_events = 0
        self.rec_start_ms = 0
        self.pending_record_save = False
        self.record_save_retry = 0

        def panel(title):
            f = QFrame()
            f.setObjectName("Panel")
            b = QVBoxLayout(f)
            b.setContentsMargins(14, 12, 14, 12)
            b.setSpacing(8)
            t = QLabel(title)
            t.setObjectName("PanelTitle")
            b.addWidget(t)
            return f, b

        deck = QHBoxLayout()
        deck.setSpacing(12)

        p1, b1 = panel("演奏")
        r = QHBoxLayout()
        r.addWidget(QLabel("力度"))
        self.vel = QSlider(Qt.Horizontal)
        self.vel.setRange(1, 127)
        self.vel.setValue(100)
        r.addWidget(self.vel, 1)
        self.vel_label = QLabel("100")
        self.vel_label.setObjectName("ValueLabel")
        r.addWidget(self.vel_label)
        b1.addLayout(r)
        r = QHBoxLayout()
        r.addWidget(QLabel("主音量"))
        self.master = QSlider(Qt.Horizontal)
        self.master.setRange(0, 19)
        self.master.setValue(13)
        r.addWidget(self.master, 1)
        self.vol_label = QLabel("13")
        self.vol_label.setObjectName("ValueLabel")
        r.addWidget(self.vol_label)
        b1.addLayout(r)
        self.pos_vel = QCheckBox("点击位置决定力度")
        b1.addWidget(self.pos_vel)
        self.info = QLabel("未按键")
        self.info.setObjectName("InfoLabel")
        b1.addWidget(self.info)
        self.hw_info = QLabel("实体：未连接")
        self.hw_info.setObjectName("InfoLabel")
        b1.addWidget(self.hw_info)
        b1.addStretch(1)
        self._timbre_ui = -1
        self.all_btn = QPushButton("全部松开")
        b1.addWidget(self.all_btn)
        deck.addWidget(p1, 3)

        p2, b2 = panel("音色 / 效果")
        g = QGridLayout()
        g.setHorizontalSpacing(10)
        g.setVerticalSpacing(8)
        g.addWidget(QLabel("音色"), 0, 0)
        self.timbre_box = QComboBox()
        self.timbre_box.addItems(["钢琴", "古筝", "箫"])
        self.timbre_box.setCurrentIndex(0)  # Initial timbre: piano; later follow live device state.
        g.addWidget(self.timbre_box, 0, 1)
        g.addWidget(QLabel("颤音"), 1, 0)
        self.vib_box = QComboBox()
        self.vib_box.addItems(["关", "浅", "深"])
        g.addWidget(self.vib_box, 1, 1)
        g.addWidget(QLabel("滑音"), 2, 0)
        self.glide_box = QComboBox()
        self.glide_box.addItems(["关", "快", "慢"])
        g.addWidget(self.glide_box, 2, 1)
        b2.addLayout(g)
        fx = QHBoxLayout()
        self.chorus_box = QCheckBox("合唱")
        self.delay_box = QCheckBox("延迟")
        fx.addWidget(self.chorus_box)
        fx.addWidget(self.delay_box)
        fx.addStretch(1)
        b2.addLayout(fx)
        b2.addStretch(1)
        deck.addWidget(p2, 2)

        p3, b3 = panel("表情 / 包络")
        r = QHBoxLayout()
        self.mono = QCheckBox("单音")
        r.addWidget(self.mono)
        r.addWidget(QLabel("弯音"))
        self.bend = QSlider(Qt.Horizontal)
        self.bend.setRange(-200, 200)
        r.addWidget(self.bend, 1)
        self.bend_label = QLabel("0.00")
        self.bend_label.setObjectName("ValueLabel")
        r.addWidget(self.bend_label)
        b3.addLayout(r)
        b3.addWidget(QLabel("ADSR"))
        for name, attr, lo, hi, val in (
                ("A", "adsr_a", 1, 1000, 2),
                ("D", "adsr_d", 10, 2000, 1342),
                ("S", "adsr_s", 0, 100, 0),
                ("R", "adsr_r", 10, 2000, 300)):
            rr = QHBoxLayout()
            lb = QLabel(name)
            lb.setObjectName("ValueLabel")
            lb.setFixedWidth(18)
            rr.addWidget(lb)
            sl = QSlider(Qt.Horizontal)
            sl.setRange(lo, hi)
            sl.setValue(val)
            setattr(self, attr, sl)
            rr.addWidget(sl, 1)
            b3.addLayout(rr)
        self.adsr_label = QLabel("A2 D1342 S0 R300")
        self.adsr_label.setObjectName("InfoLabel")
        b3.addWidget(self.adsr_label)
        b3.addStretch(1)
        deck.addWidget(p3, 3)
        self.layout.addLayout(deck)

        recp = QFrame()
        recp.setObjectName("Panel")
        rec = QHBoxLayout(recp)
        rec.setContentsMargins(14, 10, 14, 10)
        rt = QLabel("录音")
        rt.setObjectName("PanelTitle")
        rec.addWidget(rt)
        rec.addWidget(QLabel("槽位"))
        self.record_slot = QSpinBox()
        self.record_slot.setRange(1, 16)
        self.record_slot.setValue(1)
        rec.addWidget(self.record_slot)
        rec.addWidget(QLabel("曲名"))
        self.record_name = QLineEdit("录音")
        self.record_name.setMaxLength(16)
        self.record_name.setMinimumWidth(150)
        rec.addWidget(self.record_name)
        self.record_btn = QPushButton("开始录音")
        self.record_btn.setObjectName("RecordBtn")
        rec.addWidget(self.record_btn)
        self.record_info = QLabel("未录音")
        self.record_info.setObjectName("InfoLabel")
        rec.addWidget(self.record_info, 1)
        self.record_timer = QTimer(self)
        self.record_timer.setInterval(200)
        self.record_timer.timeout.connect(self.update_record_info)
        self.status_timer = QTimer(self)
        self.status_timer.setInterval(500)
        self.status_timer.timeout.connect(self.entity_poll)
        self.record_btn.clicked.connect(self.toggle_record)
        self.layout.addWidget(recp)

        self.piano = PianoWidget()
        self.layout.addWidget(self.piano, 1)
        self.status = QLabel("BLE：未连接")
        self.status.setObjectName("HomeStatus")
        self.layout.addWidget(self.status)
        self.layout.addWidget(QLabel(
            "白键  A S D F G H J K L ; ' Z X C V B N M ,    "
            "黑键  Q W E R T Y U I O P [ ] 、"))

        self.vel.valueChanged.connect(self.piano.set_velocity)
        self.vel.valueChanged.connect(lambda v: self.vel_label.setText(str(v)))
        self.master.valueChanged.connect(self.send_volume)
        self.piano.set_master(100)
        self.pos_vel.toggled.connect(self.piano.set_position_velocity)
        self.mono.toggled.connect(self.piano.set_mono)
        self.bend.valueChanged.connect(self.send_bend)
        self.timbre_box.currentIndexChanged.connect(self.send_timbre)
        self.vib_box.currentIndexChanged.connect(lambda i: self.send_effect(0, i))
        self.glide_box.currentIndexChanged.connect(lambda i: self.send_effect(1, i))
        self.chorus_box.toggled.connect(lambda on: self.send_effect(2, 1 if on else 0))
        self.delay_box.toggled.connect(lambda on: self.send_effect(3, 1 if on else 0))
        for w in (self.adsr_a, self.adsr_d, self.adsr_s, self.adsr_r):
            w.valueChanged.connect(self.send_adsr)
        self.all_btn.clicked.connect(self.all_off)
        self.piano.noteOn.connect(self.on_note_on)
        self.piano.noteOff.connect(self.on_note_off)
        ble.connectedChanged.connect(self.on_conn)
        ble.frameReceived.connect(self.on_frame)
        self.watchdog = QTimer(self)
        self.watchdog.setInterval(1000)
        self.watchdog.timeout.connect(self.watchdog_tick)
        self.watchdog.start()

        self.live_tick = 0
        self.syncing = False
        self.live_timer = QTimer(self)
        self.live_timer.setInterval(100)
        self.live_timer.timeout.connect(self.poll_live)

    def _scaled(self, base):
        return max(1, min(127, int(round(base))))

    def xport(self):
        return self.ble

    def send_volume(self, value):
        self.vol_label.setText(str(int(value)))
        if self.ble.connected:
            self.xport().send(frame(0x43, bytes([int(value) & 0x1F])))

    def send_timbre(self, index):
        idx = max(0, min(2, int(index)))
        if self.ble.connected:
            self.xport().send(frame(0x44, bytes([idx + 1])))
        self.update_adsr_ui(idx, apply=True)

    def send_effect(self, eid, value):
        if self.ble.connected:
            self.xport().send(frame(0x45, bytes([eid & 0xFF, value & 0xFF])))

    TIMBRE_ADSR = ((2, 1342, 0, 300),    # 钢琴
                   (1, 1342, 0, 300),    # 古筝
                   (120, 200, 85, 200))  # 箫 (D=200ms, 与 FPGA 模板一致)

    def update_adsr_ui(self, timbre, apply=False):
        if timbre == self._timbre_ui:
            return
        self._timbre_ui = timbre
        a, d, s, r = self.TIMBRE_ADSR[timbre]
        for w, v in ((self.adsr_a, a), (self.adsr_d, d),
                     (self.adsr_s, s), (self.adsr_r, r)):
            w.blockSignals(True)
            w.setValue(v)
            w.blockSignals(False)
        self.adsr_label.setText("A%d D%d S%d R%d" % (a, d, s, r))
        # 下发该音色的默认包络, 保证 FPGA 实际值 = 界面显示值
        if apply and self.ble.connected:
            self.send_adsr()

    def send_adsr(self):
        fs = 48828.0
        a = max(1.0, float(self.adsr_a.value()))
        d = max(1.0, float(self.adsr_d.value()))
        s = max(0.0, min(100.0, float(self.adsr_s.value())))
        r = max(1.0, float(self.adsr_r.value()))
        sus = int(round(65535 * s / 100.0))
        att = min(65535, max(1, int(round(65535.0 / (fs * a / 1000.0)))))
        dec = min(65535, max(1, int(round(max(1, 65535 - sus) / (fs * d / 1000.0)))))
        rel = min(65535, max(1, int(round(max(1, sus) / (fs * r / 1000.0)))))
        self.adsr_label.setText("A%d D%d S%d R%d" % (a, d, s, r))
        if self.ble.connected:
            self.xport().send(frame(0x47,
                att.to_bytes(2, "little") + dec.to_bytes(2, "little") +
                sus.to_bytes(2, "little") + rel.to_bytes(2, "little")))

    def send_bend(self):
        cents = self.bend.value()
        self.bend_label.setText("%+.2f" % (cents / 100.0))
        off = 0
        if self.piano.active:
            note = list(self.piano.active)[-1]
            freq = 440.0 * (2.0 ** ((60 + note - 69) / 12.0))   # 与 FPGA 一致: note 0 = C4
            phase = freq * (1 << 24) / 48828.0
            off = int(round(phase * (2.0 ** (cents / 1200.0) - 1.0)))
        if self.ble.connected:
            self.ble.send(frame(0x46, int(off).to_bytes(4, "little", signed=True)))

    def poll_live(self):
        if not self.ble.connected:
            return
        win = self.window()
        if win is not None and getattr(win, "scope_active", False):
            return
        self.ble.send(frame(CMD_LIVE))
        self.live_tick += 1
        if self.live_tick % 5 == 0:
            self.ble.send(frame(CMD_LIVE_PARAMS))

    def sync_live(self, keys, vel, vol):
        self.piano.set_external_keys(keys)
        self.master.blockSignals(True)
        self.master.setValue(max(0, min(self.master.maximum(), vol)))
        self.master.blockSignals(False)
        self.vol_label.setText(str(self.master.value()))
        names = [note_name(i) for i in range(32) if (keys >> i) & 1]
        shown = " ".join(names[:6]) + ("..." if len(names) > 6 else "")
        self.hw_info.setText("实体 %s   FSR %d   音量 %d" %
                             (shown or "-", vel, vol))

    def sync_params(self, timbre, vib, glide, chorus, delay):
        # Firmware/protocol uses 1..3; Qt and TIMBRE_ADSR use indexes 0..2.
        if timbre not in (1, 2, 3):
            return
        timbre_index = timbre - 1
        for w, v in ((self.timbre_box, timbre_index), (self.vib_box, vib),
                     (self.glide_box, glide)):
            w.blockSignals(True)
            w.setCurrentIndex(max(0, min(w.count() - 1, v)))
            w.blockSignals(False)
        for w, v in ((self.chorus_box, chorus), (self.delay_box, delay)):
            w.blockSignals(True)
            w.setChecked(bool(v))
            w.blockSignals(False)
        self.update_adsr_ui(timbre_index, apply=True)

    def on_note_on(self, note, base):
        vel = self._scaled(base)
        self.ble.send(note_on(note, vel))
        self.live.note_on(note, vel)
        self.info.setText("%s  力度 %d" % (note_name(note), vel))
        self.send_bend()

    def on_note_off(self, note):
        self.ble.send(note_off(note))
        self.live.note_off(note)
        if not self.piano.active:
            self.xport().send(all_off())
            self.info.setText("未按键")
        self.send_bend()

    def watchdog_tick(self):
        if self.ble.connected and not self.piano.active:
            self.xport().send(all_off())

    def all_off(self):
        self.piano.all_off()
        self.live.clear()
        self.ble.send(all_off())
        self.bend.setValue(0)
        self.send_bend()
        self.info.setText("全部松开")

    def toggle_record(self):
        if not self.recording:
            if not self.ble.connected:
                self.status.setText("BLE 未连接")
                return
            slot = self.record_slot.value() - 1
            self.ble.send(frame(CMD_REC, bytes([1, slot])))
            self.recording = True
            self.rec_events = 0
            self.rec_start_ms = time.monotonic()
            self.record_btn.setText("停止并保存")
            self.record_slot.setEnabled(False)
            self.record_name.setEnabled(False)
            self.record_info.setText("● FPGA 录音中  0 事件")
            self.record_timer.start()
            self.status_timer.start()
        else:
            slot = self.record_slot.value() - 1
            self.ble.send(frame(CMD_REC, bytes([0, slot])))
            self.recording = False
            self.record_timer.stop()
            self.status_timer.stop()
            self.ble.send(all_off())
            self.record_btn.setEnabled(False)
            self.record_btn.setText("开始录音")
            self.record_slot.setEnabled(True)
            self.record_name.setEnabled(True)
            self.record_info.setText("停止，FPGA 保存中...")
            self.record_save_retry = 0
            QTimer.singleShot(1800, self.rename_record)

    def entity_poll(self):
        if self.ble.connected:
            self.ble.send(frame(CMD_STATUS))

    def on_conn(self, ok):
        self.status.setText("BLE：已连接" if ok else "BLE：未连接")
        if ok:
            self.xport().send(all_off())
            if self.isVisible() and hasattr(self, "live_timer"):
                self.live_timer.start()
        else:
            if hasattr(self, "live_timer"):
                self.live_timer.stop()
            self.piano.all_off()
            self.live.clear()
            self.hw_info.setText("实体：未连接")
            self.piano.set_external_keys(0)
        if not ok and self.recording:
            self.recording = False
            self.record_timer.stop()
            self.status_timer.stop()
            self.record_btn.setEnabled(True)
            self.record_btn.setText("开始录音")
            self.record_slot.setEnabled(True)
            self.record_name.setEnabled(True)
            self.record_info.setText("BLE 断开，录音取消")

    def on_frame(self, f):
        if len(f) < 12 or f[2] != 0xE0:
            return
        cmd, status, err = f[4], f[5], f[11]
        if cmd == CMD_LIVE and status == 0:
            keys = f[6] | (f[7] << 8) | (f[8] << 16) | (f[9] << 24)
            self.sync_live(keys, f[10], f[11] & 0x1F)
            return
        if cmd == CMD_LIVE_PARAMS and status == 0:
            p0, p1 = f[6], f[7]
            self.sync_params((p0 >> 4) & 3, (p0 >> 2) & 3,
                             p0 & 3, (p1 >> 1) & 1, p1 & 1)
            return
        if cmd == CMD_STATUS and self.recording and (f[6] & 0x80):
            self.rec_events = f[7] | (f[8] << 8)
        elif cmd == CMD_SAVE and self.pending_record_save:
            self.pending_record_save = False
            self.record_btn.setEnabled(True)
            if status == 0 and err == 0:
                self.record_info.setText("✅ 已保存到槽位 %02d" % self.record_slot.value())
                self.status.setText("录音已保存，去曲库刷新")
            else:
                self.record_info.setText("❌ 保存失败 %d/%d" % (status, err))

    def rename_record(self):
        if not self.ble.connected:
            self.record_btn.setEnabled(True)
            return
        slot = self.record_slot.value() - 1
        name = self.record_name.text().strip() or "录音"
        self.pending_record_save = True
        self.ble.send(frame(CMD_SAVE, bytes([slot] + utf8_bytes(name, 16))))
        self.record_info.setText("写入曲名...")
        QTimer.singleShot(3500, self.record_save_timeout)

    def record_save_timeout(self):
        if not self.pending_record_save:
            return
        self.pending_record_save = False
        if self.record_save_retry < 1 and self.ble.connected:
            self.record_save_retry += 1
            QTimer.singleShot(400, self.rename_record)
        else:
            self.record_btn.setEnabled(True)
            self.record_info.setText("保存超时")

    def update_record_info(self):
        if self.recording:
            sec = int((time.monotonic() - self.rec_start_ms))
            self.record_info.setText("● FPGA 录音中  %02d:%02d  %d 事件" %
                                     (sec // 60, sec % 60, self.rec_events))

    def leave_page(self):
        if self.recording:
            self.toggle_record()
        else:
            self.all_off()
        self.live_timer.stop()

    def on_show(self):
        self.window().activateWindow()
        self.piano.setFocus(Qt.OtherFocusReason)
        QTimer.singleShot(0, lambda: self.piano.setFocus(Qt.OtherFocusReason))
        if self.ble.connected:
            self.live_timer.start()

class LibraryPage(Page):
    ERR = {0: "成功", 1: "参数错误", 2: "事件数错误", 3: "超过 4095",
           4: "事件数不一致", 5: "校验和错误", 6: "没有可播放曲目",
           7: "保存校验失败", 8: "保存超时", 9: "加载超时",
           10: "删除超时", 11: "加载播放超时", 12: "没有曲名"}

    def __init__(self, ble):
        super().__init__("PC 曲库")
        self.ble = ble
        self.mask = 0
        self.current = 0
        self.slot = 0
        self.names = {}
        self.name_raw = {}
        self._filling = False
        self.pending_cmd = None
        self.pending_slot = 0
        self.name_queue = []
        self.name_wait = None
        self.timer = QTimer(self)
        self.timer.setSingleShot(True)
        self.timer.timeout.connect(self.on_timeout)
        self.name_timer = QTimer(self)
        self.name_timer.setSingleShot(True)
        self.name_timer.timeout.connect(self.on_name_timeout)

        tool = QFrame()
        tool.setObjectName("Panel")
        tv = QVBoxLayout(tool)
        tv.setContentsMargins(16, 12, 16, 12)
        tv.setSpacing(8)
        tt = QLabel("曲库操作")
        tt.setObjectName("PanelTitle")
        tv.addWidget(tt)
        row = QHBoxLayout()
        row.addWidget(QLabel("曲名"))
        self.name_edit = QLineEdit("录音")
        self.name_edit.setMaxLength(16)
        row.addWidget(self.name_edit, 1)
        tv.addLayout(row)
        self.import_btn = QPushButton("导入曲谱")
        self.play_btn = QPushButton("播放")
        self.stop_btn = QPushButton("停止")
        self.refresh_btn = QPushButton("刷新")
        self.save_btn = QPushButton("保存当前曲谱")
        self.load_btn = QPushButton("加载")
        self.del_btn = QPushButton("删除")
        self.del_btn.setObjectName("DangerBtn")
        acts = QGridLayout()
        acts.setSpacing(8)
        for b in (self.import_btn, self.play_btn, self.stop_btn,
                  self.refresh_btn, self.save_btn, self.load_btn, self.del_btn):
            b.setFixedWidth(122)
            b.setFixedHeight(30)
        for i, b in enumerate((self.import_btn, self.play_btn, self.stop_btn,
                               self.refresh_btn)):
            acts.addWidget(b, 0, i)
        acts.addWidget(self.save_btn, 1, 0)
        acts.addWidget(self.load_btn, 1, 1)
        acts.addWidget(self.del_btn, 1, 2)
        self.save_after = QCheckBox("导入后保存")
        self.save_after.setChecked(True)
        acts.addWidget(self.save_after, 1, 3)
        acts.setColumnStretch(4, 1)
        tv.addLayout(acts)
        self.layout.addWidget(tool)

        tp = QFrame()
        tp.setObjectName("Panel")
        tv2 = QVBoxLayout(tp)
        tv2.setContentsMargins(12, 10, 12, 10)
        th = QHBoxLayout()
        title = QLabel("槽位列表")
        title.setObjectName("PanelTitle")
        th.addWidget(title)
        th.addStretch(1)
        self.count_label = QLabel("已用 0 / 16")
        self.count_label.setObjectName("ValueLabel")
        th.addWidget(self.count_label)
        tv2.addLayout(th)
        self.table = QTableWidget(16, 3)
        self.table.setHorizontalHeaderLabels(["槽位", "状态", "曲名"])
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.setSelectionMode(QTableWidget.SingleSelection)
        self.table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.Stretch)
        self.table.verticalHeader().setDefaultSectionSize(32)
        tv2.addWidget(self.table, 1)
        self.status = QLabel("BLE：未连接")
        self.status.setObjectName("HomeStatus")
        tv2.addWidget(self.status)
        self.layout.addWidget(tp, 1)

        self.refresh_btn.clicked.connect(self.refresh)
        self.save_btn.clicked.connect(self.save_song)
        self.load_btn.clicked.connect(self.load_song)
        self.del_btn.clicked.connect(self.delete_song)
        self.import_btn.clicked.connect(self.import_song)
        self.play_btn.clicked.connect(self.play_song)
        self.stop_btn.clicked.connect(self.stop_song)
        self.table.cellClicked.connect(self.on_cell_clicked)
        ble.frameReceived.connect(self.on_frame)
        ble.connectedChanged.connect(self.on_conn)
        self.fill_table()

    def fill_table(self):
        keep = self.slot
        self._filling = True
        self.table.blockSignals(True)
        for i in range(16):
            valid = (self.mask >> i) & 1
            texts = ["%02d" % (i + 1), "●" if valid else "○",
                     self.names.get(i, "") if valid else ""]
            for c, text in enumerate(texts):
                item = QTableWidgetItem(text)
                item.setTextAlignment(Qt.AlignCenter if c < 2 else
                                      Qt.AlignLeft | Qt.AlignVCenter)
                if i == self.current:
                    item.setForeground(QColor("#ffd166"))
                self.table.setItem(i, c, item)
        self.table.blockSignals(False)
        self._filling = False
        self.slot = max(0, min(15, keep))
        self.table.selectRow(self.slot)
        self.count_label.setText("已用 %d / 16" % bin(self.mask).count("1"))

    def on_cell_clicked(self, row, _col):
        self.slot = row
        self.name_edit.setText(self.names.get(row, ""))

    def send_cmd(self, cmd, payload, timeout=3000, slot=None):
        if not self.ble.connected:
            self.status.setText("BLE 未连接")
            return False
        self.pending_cmd = cmd
        self.pending_slot = self.slot if slot is None else slot
        self.timer.start(timeout)
        self.ble.send(frame(cmd, payload))
        return True

    def on_timeout(self):
        if self.pending_cmd is not None:
            self.status.setText("命令超时：0x%02X" % self.pending_cmd)
            self.pending_cmd = None

    def on_conn(self, ok):
        self.status.setText("BLE：已连接" if ok else "BLE：未连接")
        if ok:
            self.refresh()

    def on_show(self):
        if self.ble.connected:
            self.refresh()

    def refresh(self):
        if not self.ble.connected:
            self.status.setText("BLE 未连接")
            return
        self.status.setText("读取曲库...")
        self.send_cmd(CMD_LIST, b"", 3000)

    def query_names(self):
        self.names = {}
        self.name_raw = {}
        self.name_queue = [(i, p) for i in range(16) if (self.mask >> i) & 1
                           for p in (0, 1)]
        self.name_wait = None
        self.next_name()

    def next_name(self):
        self.name_wait = None
        if not self.name_queue:
            self.fill_table()
            return
        slot, part = self.name_queue.pop(0)
        self.name_wait = (slot, part)
        self.ble.send(frame(CMD_NAME, bytes([slot, part])))
        self.name_timer.start(300)

    def on_name_timeout(self):
        if self.name_wait is not None:
            self.name_wait = None
            self.next_name()

    def on_frame(self, f):
        if len(f) < 8:
            return
        if f[2] == 0xE1 and len(f) >= 14:
            if self.name_wait is None:
                return
            slot, part = self.name_wait
            chunk = f[4:12]
            self.name_timer.stop()
            raw = self.name_raw.get(slot)
            if part == 0:
                raw = bytearray(chunk)
            else:
                if raw is None:
                    raw = bytearray(16)
                if len(raw) < 8:
                    raw.extend(b"\x00" * (8 - len(raw)))
                raw[8:16] = chunk
            self.name_raw[slot] = raw
            if part == 1:
                self.names[slot] = decode_name(bytes(raw))
            self.name_wait = None
            self.next_name()
            return
        if f[2] != 0xE0 or len(f) < 12:
            return
        cmd, status, err = f[4], f[5], f[11]
        if cmd == CMD_LIST:
            self.timer.stop()
            self.pending_cmd = None
            self.mask = f[6] | (f[7] << 8)
            self.current = f[8] & 0x0F
            self.status.setText("已刷新，当前槽 %02d" % (self.current + 1))
            self.query_names()
            self.fill_table()
            return
        if self.pending_cmd != cmd:
            return
        self.timer.stop()
        self.pending_cmd = None
        if status != 0 or err != 0:
            self.status.setText("操作失败：%s" % self.ERR.get(err, err))
            return
        if cmd == CMD_SAVE:
            self.names[self.pending_slot] = self.name_edit.text().strip()
            self.status.setText("已保存槽 %02d" % (self.pending_slot + 1))
            self.refresh()
        elif cmd == CMD_LOAD:
            self.current = self.pending_slot
            self.status.setText("已加载槽 %02d" % (self.pending_slot + 1))
            self.fill_table()
        elif cmd == CMD_DELETE:
            self.names.pop(self.pending_slot, None)
            self.status.setText("已删除槽 %02d" % (self.pending_slot + 1))
            self.refresh()
        else:
            self.status.setText("操作成功")

    def save_song(self):
        name = self.name_edit.text().strip() or "未命名"
        payload = bytes([self.slot] + utf8_bytes(name, 16))
        if self.send_cmd(CMD_SAVE, payload, 4000):
            self.status.setText("保存到槽 %02d..." % (self.slot + 1))

    def load_song(self):
        if self.send_cmd(CMD_LOAD, bytes([self.slot]), 4000):
            self.status.setText("加载槽 %02d..." % (self.slot + 1))

    def delete_song(self):
        if self.send_cmd(CMD_DELETE, bytes([self.slot]), 4000):
            self.status.setText("删除槽 %02d..." % (self.slot + 1))

    def play_song(self):
        if self.ble.connected:
            self.ble.send(frame(CMD_PLAY))
            self.status.setText("播放中...")

    def stop_song(self):
        if self.ble.connected:
            self.ble.send(frame(CMD_STOP))
            self.status.setText("已停止")

    def import_song(self):
        if not self.ble.connected:
            self.status.setText("BLE 未连接")
            return
        path, _ = QFileDialog.getOpenFileName(self, "导入曲谱", "", "JSON (*.json)")
        if not path:
            return
        try:
            obj = json.load(open(path, encoding="utf-8"))
            events = obj.get("events", [])
            name = str(obj.get("name", "导入曲谱"))[:16]
            if not events or len(events) > 4095:
                raise ValueError("事件数必须在 1..4095")
        except Exception as e:
            self.status.setText("JSON 错误：%s" % e)
            return
        self.import_btn.setEnabled(False)
        self.status.setText("导入 %d 事件..." % len(events))
        self.transfer = SongTransfer(self.ble, events, name, self.slot,
                                     save=self.save_after.isChecked())
        self.transfer.progress.connect(lambda p, t: self.status.setText(t))
        self.transfer.finished.connect(self.on_import_done)
        self.transfer.start()

    def on_import_done(self, ok, msg):
        self.import_btn.setEnabled(True)
        self.status.setText(("✅ " if ok else "❌ ") + msg)
        if ok:
            self.refresh()

class ScopeCanvas(QWidget):
    def __init__(self, live):
        super().__init__()
        self.live = live
        self.mode = 0
        self.phase = 0.0
        self.setMinimumHeight(260)
        self.real = None
        self.timer = QTimer(self)
        self.timer.setInterval(33)
        self.timer.timeout.connect(self.tick)
        self.timer.start()

    def clear_samples(self):
        self.real = None
        self.peak = 0.0
        self.update()

    def set_samples(self, data):
        raw = np.frombuffer(data, dtype="<i2").astype(np.float32)
        raw = raw - raw.mean()
        self.peak = float(np.max(np.abs(raw))) if len(raw) else 0.0
        # 单音经过 ADSR/力度后幅度常常只有几个 LSB，自动增益后再画
        if self.peak > 2.0:
            scale = 100.0 / self.peak
            raw = raw * scale
            # 简单零交叉对齐，避免波形左右滚动
            half = max(1, len(raw) // 2)
            for i in range(1, half):
                if raw[i - 1] <= 0.0 < raw[i]:
                    raw = np.roll(raw, -i)
                    break
        self.real = raw
        self.update()

    def set_mode(self, mode):
        self.mode = mode
        self.update()

    def tick(self):
        self.phase = (self.phase + 0.07) % (2 * math.pi)
        if self.isVisible():
            self.update()

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        w, h = self.width(), self.height()
        p.fillRect(0, 0, w, h, QColor("#0b1016"))
        m = 30
        p.setPen(QPen(QColor("#1d2b3a"), 1))
        for i in range(1, 8):
            p.drawLine(int(m + (w - 2 * m) * i / 8), m,
                       int(m + (w - 2 * m) * i / 8), h - m)
        for i in range(1, 6):
            p.drawLine(m, int(m + (h - 2 * m) * i / 6),
                       w - m, int(m + (h - 2 * m) * i / 6))
        if self.real is not None:
            if self.mode == 0:
                self.wave_real(p, w, h, m)
            elif self.mode == 1:
                self.spectrum_real(p, w, h, m)
            else:
                self.lissajous_real(p, w, h, m)
            p.setPen(QPen(QColor("#5f7287")))
            p.setFont(QFont("Consolas", 9))
            p.drawText(m, h - 8, "FPGA 真实采样 · 6.1kHz · 256 点")
            p.end()
            return
        active = dict(self.live.active)
        if self.mode == 0:
            self.wave(p, w, h, m, active)
        elif self.mode == 1:
            self.spectrum(p, w, h, m, active)
        else:
            self.lissajous(p, w, h, m, active)
        p.setPen(QPen(QColor("#5f7287")))
        p.setFont(QFont("Consolas", 9))
        p.drawText(m, h - 8, "PC 音符驱动 · 非 ES8388 实际采样")
        p.end()

    def wave_real(self, p, w, h, m):
        data = self.real
        n = len(data)
        if n == 0:
            return
        mid = h / 2
        amp = (h - 2 * m) * 0.42
        pts = [QPointF(m + i * (w - 2 * m) / max(1, n - 1),
                       mid - data[i] / 128.0 * amp) for i in range(n)]
        p.setPen(QPen(QColor("#4ea1ff"), 2))
        p.drawPolyline(QPolygonF(pts))

    def spectrum_real(self, p, w, h, m):
        data = self.real
        if len(data) == 0:
            return
        window = np.hanning(len(data))
        mag = np.abs(np.fft.rfft(data * window))
        bins = len(mag)
        base = h - m
        peak = float(mag[1:].max()) if bins > 1 else 1.0
        for i in range(bins):
            x0 = m + i * (w - 2 * m) / bins
            x1 = m + (i + 1) * (w - 2 * m) / bins
            bh = (h - 2 * m) * (mag[i] / peak if peak > 0 else 0)
            p.setBrush(QBrush(QColor("#4ea1ff")))
            p.setPen(Qt.NoPen)
            p.drawRect(QRectF(x0, base - bh, x1 - x0, bh))
        p.setPen(QPen(QColor("#5f7287")))
        p.setFont(QFont("Consolas", 8))
        p.drawText(m, m + 14, "FFT 0-24kHz Δ381Hz bins=%d" % bins)

    def lissajous_real(self, p, w, h, m):
        data = self.real
        n = len(data)
        if n < 24:
            return
        y = np.roll(data, -24)
        cx, cy = w / 2, h / 2
        amp = min(w - 2 * m, h - 2 * m) * 0.42
        pts = [QPointF(cx + data[i] / 128.0 * amp,
                       cy + y[i] / 128.0 * amp) for i in range(n)]
        p.setPen(QPen(QColor("#ffd166"), 1.6))
        p.drawPolyline(QPolygonF(pts))
        p.setPen(QPen(QColor("#5f7287")))
        p.setFont(QFont("Consolas", 9))
        p.drawText(m, m + 14, "X=样本  Y=延迟24点")

    def wave(self, p, w, h, m, active):
        if not active:
            p.setPen(QPen(QColor("#5f7287")))
            p.drawText(QRectF(0, 0, w, h), Qt.AlignCenter, "无音符")
            return
        n = max(2, w - 2 * m)
        pts = []
        for x in range(n):
            t = x / n * 4 * math.pi
            s = 0.0
            norm = 0.0
            for note, vel in active.items():
                amp = max(1, vel) / 127.0
                f = 1.0 + (note % 12) * 0.5 + (note // 12) * 0.25
                s += math.sin(f * t * 2 + self.phase + note * 0.15) * amp
                norm += amp
            pts.append(QPointF(m + x, h / 2 - (s / max(0.001, norm)) * h * 0.34))
        p.setPen(QPen(QColor("#4ea1ff"), 2))
        p.drawPolyline(QPolygonF(pts))

    def spectrum(self, p, w, h, m, active):
        n = 32
        bw = (w - 2 * m) / n
        base = h - m
        for i in range(n):
            vel = active.get(i)
            x0 = m + i * bw + 1
            x1 = m + (i + 1) * bw - 2
            if vel:
                bh = (h - 2 * m) * max(1, vel) / 127.0
                p.setBrush(QBrush(QColor("#4ea1ff")))
                p.setPen(Qt.NoPen)
                p.drawRect(QRectF(x0, base - bh, x1 - x0, bh))
            else:
                p.setBrush(QBrush(QColor("#162331")))
                p.setPen(Qt.NoPen)
                p.drawRect(QRectF(x0, base - 4, x1 - x0, 4))
        p.setPen(QPen(QColor("#5f7287")))
        p.setFont(QFont("Consolas", 8))
        for i in range(0, n, 4):
            p.drawText(QRectF(m + i * bw, base + 3, bw * 4, 18), Qt.AlignLeft,
                       note_name(i))

    def lissajous(self, p, w, h, m, active):
        notes = list(active.keys())
        if len(notes) >= 2:
            f1 = 1.0 + (notes[0] % 12) * 0.5
            f2 = 1.0 + (notes[1] % 12) * 0.5
        else:
            f1, f2 = 3.0, 2.0
        cx, cy = w / 2, h / 2
        r = min(w - 2 * m, h - 2 * m) * 0.44
        pts = [QPointF(cx + math.sin(f1 * i * math.pi / 360 + self.phase) * r,
                       cy + math.sin(f2 * i * math.pi / 360) * r)
               for i in range(720)]
        p.setPen(QPen(QColor("#ffd166"), 1.6))
        p.drawPolyline(QPolygonF(pts))
        p.setPen(QPen(QColor("#5f7287")))
        p.drawText(m, m + 14, "f1=%.1f  f2=%.1f" % (f1, f2))


class ScopePage(Page):
    def __init__(self, ble, live, serial=None):
        super().__init__("显示")
        self.ble = ble
        self.live = live
        self.ser = serial
        tool = QFrame()
        tool.setObjectName("Panel")
        bar = QHBoxLayout(tool)
        bar.setContentsMargins(14, 10, 14, 10)
        t = QLabel("视图模式")
        t.setObjectName("PanelTitle")
        bar.addWidget(t)
        self.mode = QComboBox()
        self.mode.addItems(["波形", "频谱", "李萨如"])
        bar.addWidget(self.mode)
        self.pos_vel = QCheckBox("位置力度")
        self.pos_vel.setChecked(True)
        bar.addWidget(self.pos_vel)
        bar.addSpacing(12)
        bar.addWidget(QLabel("当前"))
        self.vel_info = QLabel("力度 -")
        self.vel_info.setObjectName("InfoLabel")
        bar.addWidget(self.vel_info)
        bar.addSpacing(12)
        self.scope_btn = QPushButton("开始真实采样")
        bar.addWidget(self.scope_btn)
        self.scope_info = QLabel("未启动")
        self.scope_info.setObjectName("InfoLabel")
        bar.addWidget(self.scope_info)
        bar.addStretch(1)
        self.layout.addWidget(tool)

        cp = QFrame()
        cp.setObjectName("Panel")
        cv = QVBoxLayout(cp)
        cv.setContentsMargins(12, 10, 12, 10)
        ct = QLabel("实时视图")
        ct.setObjectName("PanelTitle")
        cv.addWidget(ct)
        self.canvas = ScopeCanvas(live)
        cv.addWidget(self.canvas, 1)
        self.layout.addWidget(cp, 1)

        mp = QFrame()
        mp.setObjectName("Panel")
        mv = QVBoxLayout(mp)
        mv.setContentsMargins(12, 8, 12, 8)
        mt = QLabel("试听键盘")
        mt.setObjectName("PanelTitle")
        mv.addWidget(mt)
        self.mini = PianoWidget()
        self.mini.setFixedHeight(122)
        self.mini.set_master(100)
        self.mini.set_position_velocity(True)
        mv.addWidget(self.mini)
        self.layout.addWidget(mp)

        self.mode.currentIndexChanged.connect(self.canvas.set_mode)
        self.mode.currentIndexChanged.connect(lambda: self.mini.setFocus())
        self.pos_vel.toggled.connect(self.mini.set_position_velocity)
        self.mini.noteOn.connect(self.on_note_on)
        self.mini.noteOff.connect(self.on_note_off)

        self.scope_buf = bytearray(256)
        self.scope_rx = set()
        self.scope_running = False
        self.scope_state = "idle"
        self.scope_wait = 0
        self.repair_queue = []
        self.scope_timer = QTimer(self)
        self.scope_timer.setInterval(20)
        self.scope_timer.timeout.connect(self.request_scope)
        self.scope_btn.clicked.connect(self.toggle_scope)
        ble.frameReceived.connect(self.on_scope_frame)

    def xport(self):
        return self.ble

    def toggle_scope(self):
        if self.scope_running:
            self.scope_running = False
            self.scope_timer.stop()
            self.scope_btn.setText("开始真实采样")
            self.scope_info.setText("已停止 · 模拟模式")
            self.canvas.clear_samples()
            win = self.window()
            if win is not None:
                win.scope_active = False
        else:
            if not self.ble.connected:
                self.scope_info.setText("BLE 未连接")
                return
            self.scope_running = True
            self.scope_state = "capture"
            self.scope_wait = 5
            self.scope_rx.clear()
            self.scope_btn.setText("停止采样")
            self.scope_info.setText("请求采样...")
            self.canvas.clear_samples()
            win = self.window()
            if win is not None:
                win.scope_active = True
            self.scope_timer.start()

    def scope_assemble(self):
        self.canvas.set_samples(bytes(self.scope_buf))
        nz = sum(1 for b in self.scope_buf[::2] if b)
        self.scope_info.setText("已更新 128 点  峰值 %.1f  非零 %d" %
                                (getattr(self.canvas, "peak", 0.0), nz))
        self.scope_state = "capture"
        self.scope_wait = 1
        self.scope_rx.clear()

    def request_scope(self):
        if not self.scope_running or not self.ble.connected:
            return
        if self.scope_state == "capture":
            if self.scope_wait > 0:
                self.scope_wait -= 1
                return
            self.ble.send(frame(CMD_SCOPE))
            self.scope_rx.clear()
            self.scope_state = "collect"
            self.scope_wait = 15
            self.scope_info.setText("采集中...")
        elif self.scope_state == "collect":
            if len(self.scope_rx) >= 22:
                self.scope_assemble()
                return
            if self.scope_wait > 0:
                self.scope_wait -= 1
                return
            self.repair_queue = [i for i in range(22)
                                 if i not in self.scope_rx]
            self.scope_state = "repair"
            self.scope_wait = 2
            self.scope_info.setText("补缺 %d 块..." % len(self.repair_queue))
        elif self.scope_state == "repair":
            if self.scope_wait > 0:
                self.scope_wait -= 1
                return
            if not self.repair_queue:
                if len(self.scope_rx) >= 22:
                    self.scope_assemble()
                else:
                    self.scope_state = "capture"
                    self.scope_wait = 5
                return
            for _ in range(2):
                if self.repair_queue:
                    c = self.repair_queue.pop(0)
                    self.ble.send(frame(CMD_SCOPE_CHUNK, bytes([c & 0xFF])))
            self.scope_wait = 2
            self.scope_info.setText("补缺块 %d/22" % (22 - len(self.repair_queue)))

    def on_scope_frame(self, f):
        if not self.scope_running:
            return
        if self.scope_state not in ("collect", "repair"):
            return
        if f[2] != 0xE2 or len(f) < 12:
            return
        chunk = f[4]
        if chunk > 21:
            return
        for i in range(12):
            pos = chunk * 12 + i
            if pos < 256:
                self.scope_buf[pos] = f[5 + i]
        self.scope_rx.add(chunk)
        if self.scope_state == "collect":
            self.scope_wait = 6
            self.scope_info.setText("接收 %d/22" % len(self.scope_rx))
            if len(self.scope_rx) >= 22:
                self.scope_assemble()

    def on_note_on(self, note, base):
        self.xport().send(note_on(note, base))
        self.live.note_on(note, base)
        self.vel_info.setText("%s  力度 %d" % (note_name(note), base))

    def on_note_off(self, note):
        self.ble.send(note_off(note))
        self.ble.send(note_off(note))
        self.live.note_off(note)
        if not self.mini.active:
            self.ble.send(all_off())
            self.vel_info.setText("力度 -")

    def all_off(self):
        self.mini.all_off()
        self.live.clear()
        self.xport().send(all_off())

    def leave_page(self):
        self.all_off()
        self.scope_timer.stop()
        self.canvas.clear_samples()
        win = self.window()
        if win is not None:
            win.scope_active = False

    def on_show(self):
        self.window().activateWindow()
        self.mini.setFocus(Qt.OtherFocusReason)
        QTimer.singleShot(0, lambda: self.mini.setFocus(Qt.OtherFocusReason))
        if self.scope_running and self.ble.connected:
            win = self.window()
            if win is not None:
                win.scope_active = True
            self.scope_timer.start()

class SettingsPage(Page):
    APP_VERSION = "1.1.1"
    PROTO_VERSION = "1"

    def __init__(self, ble):
        super().__init__("设置 / 连接")
        self.ble = ble
        info = QFrame()
        info.setObjectName("Panel")
        iv = QVBoxLayout(info)
        iv.setContentsMargins(18, 14, 18, 14)
        iv.setSpacing(10)
        it = QLabel("设备连接")
        it.setObjectName("PanelTitle")
        iv.addWidget(it)

        grid = QGridLayout()
        grid.setHorizontalSpacing(24)
        grid.setVerticalSpacing(9)
        grid.setColumnMinimumWidth(0, 110)
        grid.setColumnStretch(1, 1)
        self.state = QLabel("-")
        self.addr = QLabel("-")
        self.mtu = QLabel("-")
        rows = [
            ("连接状态", self.state),
            ("BLE 名称", QLabel(SYNTH_NAME)),
            ("BLE 地址", self.addr),
            ("MTU", self.mtu),
            ("协议版本", QLabel(self.PROTO_VERSION)),
            ("上位机版本", QLabel(self.APP_VERSION)),
        ]
        for i, (k, v) in enumerate(rows):
            key = QLabel(k)
            key.setObjectName("ParamName")
            grid.addWidget(key, i, 0)
            grid.addWidget(v, i, 1)
        iv.addLayout(grid)
        self.layout.addWidget(info)

        actions = QFrame()
        actions.setObjectName("Panel")
        av = QVBoxLayout(actions)
        av.setContentsMargins(18, 14, 18, 14)
        av.setSpacing(10)
        at = QLabel("连接操作")
        at.setObjectName("PanelTitle")
        av.addWidget(at)

        btns = QGridLayout()
        btns.setHorizontalSpacing(8)
        btns.setVerticalSpacing(8)
        self.scan_btn = QPushButton("重新扫描")
        self.reconnect_btn = QPushButton("重新连接")
        self.disconnect_btn = QPushButton("断开")
        self.ping_btn = QPushButton("发送 PING")
        self.stop_btn = QPushButton("全部停止")
        self.stop_btn.setObjectName("DangerBtn")
        for b in (self.scan_btn, self.reconnect_btn, self.disconnect_btn,
                  self.ping_btn, self.stop_btn):
            b.setFixedWidth(132)
            b.setFixedHeight(30)
        btns.addWidget(self.scan_btn, 0, 0)
        btns.addWidget(self.reconnect_btn, 0, 1)
        btns.addWidget(self.disconnect_btn, 0, 2)
        btns.addWidget(self.ping_btn, 1, 0)
        btns.addWidget(self.stop_btn, 1, 1)
        btns.setColumnStretch(3, 1)
        av.addLayout(btns)

        self.status = QLabel("")
        self.status.setObjectName("HomeStatus")
        av.addWidget(self.status)
        self.layout.addWidget(actions)
        self.layout.addStretch(1)
        self.scan_btn.clicked.connect(self.scan)
        self.reconnect_btn.clicked.connect(self.reconnect)
        self.disconnect_btn.clicked.connect(self.disconnect)
        self.ping_btn.clicked.connect(self.ping)
        self.stop_btn.clicked.connect(self.all_stop)

        ble.connectedChanged.connect(self.on_conn)
        ble.statusChanged.connect(self.on_status)
        ble.stateChanged.connect(self.on_ble_state)
        self.refresh()

    def refresh(self):
        states = {"idle": "未连接", "scanning": "扫描中", "connecting": "连接中",
                  "connected": "已连接", "disconnecting": "断开清理中", "failed": "连接失败 / 已掉线"}
        self.state.setText(states.get(self.ble.state, "未连接"))
        busy = self.ble.state in ("scanning", "connecting", "disconnecting")
        self.scan_btn.setEnabled(not busy)
        self.reconnect_btn.setEnabled(not busy)
        self.disconnect_btn.setEnabled(self.ble.state in ("scanning", "connecting", "connected"))
        self.ping_btn.setEnabled(self.ble.connected and not busy)
        self.stop_btn.setEnabled(self.ble.connected and not busy)
        self.addr.setText(self.ble.address or "自动扫描")
        self.mtu.setText(str(self.ble.mtu) if self.ble.mtu else "-")

    def on_conn(self, _ok):
        self.refresh()

    def on_ble_state(self, _state):
        self.refresh()

    def on_status(self, text):
        self.status.setText(text)
        self.refresh()

    def on_show(self):
        self.refresh()

    def scan(self):
        self.status.setText("重新扫描 ACG720-Synth...")
        self.ble.address = None
        self.ble.restart()

    def reconnect(self):
        self.status.setText("重新连接...")
        self.ble.restart()

    def disconnect(self):
        self.ble.stop()
        self.refresh()

    def ping(self):
        if not self.ble.connected:
            self.status.setText("BLE 未连接")
            return
        self.ble.send(frame(CMD_PING))
        self.status.setText("PING 已发送")

    def all_stop(self):
        if not self.ble.connected:
            self.status.setText("BLE 未连接")
            return
        self.ble.send(frame(CMD_STOP))
        self.ble.send(all_off())
        self.status.setText("已发送 STOP + ALL_NOTES_OFF")


# ============================================================================
# 主窗口
# ============================================================================
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("ACG720 合成器控制台")
        self.resize(1220, 780)

        self.ble = BleService(DEFAULT_ADDRESS)
        self.serial = None
        self.recorder = NoteRecorder()
        self.live = LiveState()
        self.stack = QStackedWidget()
        self.setCentralWidget(self.stack)

        self.home = HomePage(self.ble)
        self.piano = PianoPage(self.ble, self.recorder, self.live)
        self.library = LibraryPage(self.ble)
        self.scope = ScopePage(self.ble, self.live)
        self.settings = SettingsPage(self.ble)

        self.pages = {
            "home": self.home,
            "piano": self.piano,
            "library": self.library,
            "scope": self.scope,
            "settings": self.settings,
        }
        for p in self.pages.values():
            self.stack.addWidget(p)
        for attr in ("port_box", "usb_btn", "usb_test", "usb_status"):
            w = getattr(self.home, attr, None)
            if w is not None:
                w.setVisible(False)

        self.home.openPage.connect(self.go)
        for p in self.pages.values():
            if hasattr(p, "backRequested"):
                p.backRequested.connect(lambda: self.go("home"))

        self.ble.statusChanged.connect(self.statusBar().showMessage)
        if self.serial is not None:
            self.serial.statusChanged.connect(self.statusBar().showMessage)
        self.ble.start()
        self.go("home")

    def go(self, key):
        current = self.stack.currentWidget()
        if current is self.piano and key != "piano":
            self.piano.leave_page()
        elif current is self.scope and key != "scope":
            self.scope.leave_page()
        page = self.pages.get(key)
        if page is None:
            return
        self.stack.setCurrentWidget(page)
        if hasattr(page, "on_show"):
            page.on_show()

    def closeEvent(self, e):
        if not getattr(self, "_closing", False):
            self._closing = True
            self.piano.all_off()
            self.scope.leave_page()
            self.ble.stop()
            if self.serial is not None:
                self.serial.close_port()
            self.setEnabled(False)
        if self.ble.thread and self.ble.thread.is_alive():
            # Keep Qt alive until the BLE worker has released its WinRT handles.
            e.ignore()
            QTimer.singleShot(100, self.close)
        else:
            e.accept()


# ============================================================================
# 样式
# ============================================================================
QSS = """
QWidget {
    background: #0b1118;
    color: #dbe7f3;
    font-family: "Microsoft YaHei", "Segoe UI";
    font-size: 13px;
}
QLabel { background: transparent; }
QMainWindow { background: #0b1118; }
#Home { background: #0b1118; }
#Page { background: #0b1118; }
#HomeTitle {
    font-size: 30px;
    font-weight: 700;
    color: #8fd6ff;
}
#PageTitle {
    font-size: 22px;
    font-weight: 700;
    color: #8fd6ff;
    margin-left: 8px;
}
#HomeStatus {
    color: #8fa3b8;
    font-size: 12px;
}
#BackBtn {
    background: #15212e;
    border: 1px solid #2a3d52;
    border-radius: 7px;
    padding: 6px 13px;
    color: #a9bfd4;
}
#BackBtn:hover {
    background: #1d2d3e;
    border-color: #4ea1ff;
    color: #ffffff;
}
#Card {
    background: #111a24;
    border: 1px solid #223244;
    border-radius: 12px;
}
#Card:hover {
    border: 1px solid #4ea1ff;
    background: #142130;
}
#CardTitle {
    font-size: 19px;
    font-weight: 600;
    color: #dbe7f3;
}
#CardDesc {
    color: #8fa3b8;
    font-size: 12px;
}
#Panel {
    background: #111a24;
    border: 1px solid #223244;
    border-radius: 10px;
}
#PanelTitle {
    color: #8fd6ff;
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 1px;
    padding-bottom: 2px;
}
#ValueLabel {
    color: #ffd166;
    font-family: Consolas, "Microsoft YaHei";
    font-size: 12px;
}
#InfoLabel {
    color: #ffd166;
    font-family: Consolas, "Microsoft YaHei";
    font-size: 13px;
}
#HelpLabel {
    color: #5f7287;
    font-family: Consolas;
    font-size: 11px;
}
QTableWidget {
    background: #0f1722;
    alternate-background-color: #131e2b;
    color: #dbe7f3;
    gridline-color: #203247;
    border: 1px solid #223244;
    border-radius: 8px;
    selection-background-color: #1f3b5c;
}
QTableWidget::item:selected {
    background: #1f3b5c;
    color: #ffffff;
}
QHeaderView::section {
    background: #15212e;
    color: #8fa3b8;
    border: none;
    border-bottom: 1px solid #223244;
    padding: 7px;
    font-weight: 600;
}
QLineEdit, QSpinBox, QComboBox {
    background: #0d151e;
    color: #dbe7f3;
    border: 1px solid #2a3d52;
    border-radius: 6px;
    padding: 5px 8px;
    selection-background-color: #1f6feb;
}
QLineEdit:focus, QSpinBox:focus, QComboBox:focus {
    border-color: #4ea1ff;
}
QComboBox::drop-down {
    border: none;
    width: 22px;
}
QComboBox QAbstractItemView {
    background: #111a24;
    color: #dbe7f3;
    border: 1px solid #2a3d52;
    selection-background-color: #1f3b5c;
}
QPushButton {
    background: #1f6feb;
    border: none;
    border-radius: 7px;
    padding: 7px 14px;
    color: white;
    font-weight: 600;
}
QPushButton:hover { background: #2f7ff5; }
QPushButton:pressed { background: #185bcc; }
QPushButton:disabled {
    background: #22303f;
    color: #607080;
}
QPushButton#RecordBtn {
    background: #c94f4b;
}
QPushButton#RecordBtn:hover {
    background: #df605b;
}
QSlider::groove:horizontal {
    height: 5px;
    background: #223244;
    border-radius: 2px;
}
QSlider::sub-page:horizontal {
    background: #2f6fa8;
    border-radius: 2px;
}
QSlider::handle:horizontal {
    width: 14px;
    margin: -5px 0;
    border-radius: 7px;
    background: #4ea1ff;
}
QSlider::handle:horizontal:hover {
    background: #8fd6ff;
}
QCheckBox {
    color: #a9bfd4;
    spacing: 6px;
}
QCheckBox::indicator {
    width: 15px;
    height: 15px;
    border: 1px solid #3a5269;
    border-radius: 3px;
    background: #0d151e;
}
QCheckBox::indicator:checked {
    background: #1f6feb;
    border-color: #4ea1ff;
}
QStatusBar {
    background: #0b1016;
    color: #8fd6ff;
}
QToolTip {
    background: #15212e;
    color: #dbe7f3;
    border: 1px solid #4ea1ff;
    padding: 4px;
}

#Hero {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:1,
        stop:0 #122131, stop:0.55 #0e1a27, stop:1 #0b141d);
    border: 1px solid #24415c;
    border-radius: 16px;
}
#Eyebrow {
    color: #4ea1ff;
    font-family: Consolas;
    font-size: 11px;
    letter-spacing: 2px;
}
#HeroSub {
    color: #8fa3b8;
    font-size: 13px;
}
#StatusChip {
    background: #0d2a22;
    color: #5ee0a0;
    border: 1px solid #1e5c45;
    border-radius: 12px;
    padding: 6px 14px;
    font-size: 12px;
    font-weight: 600;
}
#StatNum {
    color: #8fd6ff;
    font-family: Consolas;
    font-size: 21px;
    font-weight: 700;
}
#StatName {
    color: #6f8aa3;
    font-size: 11px;
}
#SectionLabel {
    color: #7c93a8;
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 1px;
    margin-top: 2px;
}
#CardIndex {
    color: #4ea1ff;
    font-family: Consolas;
    font-size: 11px;
    letter-spacing: 1px;
}
#CardArrow {
    color: #4ea1ff;
    font-size: 18px;
    font-weight: 700;
}
#CardAction {
    color: #6f8aa3;
    font-size: 11px;
}
#FooterLabel {
    color: #40566a;
    font-family: Consolas;
    font-size: 10px;
    letter-spacing: 1px;
}
QPushButton#DangerBtn {
    background: #8f3a38;
}
QPushButton#DangerBtn:hover {
    background: #b04744;
}
#ParamName {
    color: #7c93a8;
    font-size: 12px;
}
"""



def main():
    app = QApplication([])
    app.setStyleSheet(QSS)
    win = MainWindow()
    win.show()
    app.exec()


if __name__ == "__main__":
    main()

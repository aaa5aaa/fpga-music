#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pc_piano.py — 13 黑 / 19 白 PC 钢琴上位机（第一版）

功能:
  - BLE 直连 ACG720-Synth
  - 鼠标点击/拖动琴键，实时 NOTE_ON / NOTE_OFF
  - 力度：滑块，或按点击位置（下重上轻）
  - 软件主音量：按比例缩放 velocity
  - 电脑键盘支持和弦
  - 窗口失焦/关闭自动 ALL_NOTES_OFF

用法:
  pip install bleak
  python pc_piano.py
"""

import asyncio
import threading
import tkinter as tk

from bleak import BleakClient, BleakScanner

from pc_ble_test import (
    RX_UUID, TX_UUID, frame, note_on, note_off, all_off, CMD_PING
)

N_NOTES = 32
SYNTH_NAME = "ACG720-Synth"
DEFAULT_ADDRESS = "9C:96:D5:B1:61:6A"

# 电脑键盘（按物理键识别，不要求 Shift）
# 白键 19：A..' + Z..,
WHITE_KEYS = [
    "a", "s", "d", "f", "g", "h", "j", "k", "l",
    "semicolon", "apostrophe",
    "z", "x", "c", "v", "b", "n", "m", "comma"
]
# 黑键 13：Q W E R T Y U I O P [ ] 、（反斜杠）
BLACK_KEYS = [
    "q", "w", "e", "r", "t", "y", "u",
    "i", "o", "p", "bracketleft", "bracketright", "backslash"
]


def is_black(note: int) -> bool:
    return (note % 12) in (1, 3, 5, 8, 10)


def note_name(note: int) -> str:
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    midi = 65 + note  # F4 = MIDI 65
    return names[midi % 12] + str(midi // 12 - 1)


class BleWorker(threading.Thread):
    def __init__(self, address, on_status):
        super().__init__(daemon=True)
        self.address = address
        self.on_status = on_status
        self.stop_evt = threading.Event()
        self.loop = None
        self.out = None
        self.connected = False

    def status(self, text):
        self.on_status(text)

    def send(self, data: bytes):
        if self.connected and self.loop and self.out:
            self.loop.call_soon_threadsafe(self.out.put_nowait, data)

    def stop(self):
        self.stop_evt.set()
        if self.loop and self.out:
            self.loop.call_soon_threadsafe(self.out.put_nowait, None)
        self.join(timeout=3)

    def _notify(self, _sender, data):
        if len(data) >= 12 and data[0] == 0xAA and data[1] == 0x55:
            if data[2] == 0xE0 and data[5] != 0:
                print("FPGA status error:", data.hex(" "))

    async def _run(self):
        self.loop = asyncio.get_running_loop()
        self.out = asyncio.Queue()

        address = self.address
        if not address:
            self.status("扫描 ACG720-Synth...")
            devices = await BleakScanner.discover(timeout=8.0)
            for d in devices:
                if (d.name or "") == SYNTH_NAME:
                    address = d.address
                    break
        if not address:
            self.status("未找到 ACG720-Synth")
            return

        self.status("连接 %s..." % address)
        try:
            async with BleakClient(address, timeout=15.0) as client:
                await client.start_notify(TX_UUID, self._notify)
                self.connected = True
                self.status("已连接，MTU=%s" % getattr(client, "mtu_size", "?"))
                await client.write_gatt_char(RX_UUID, frame(CMD_PING), response=False)

                while not self.stop_evt.is_set():
                    try:
                        data = await asyncio.wait_for(self.out.get(), timeout=0.2)
                    except asyncio.TimeoutError:
                        continue
                    if data is None:
                        break
                    await client.write_gatt_char(RX_UUID, data, response=False)

                try:
                    await client.write_gatt_char(RX_UUID, all_off(), response=False)
                except Exception:
                    pass
        except Exception as e:
            self.status("连接失败: %s" % e)
        finally:
            self.connected = False
            self.status("已断开")

    def run(self):
        try:
            asyncio.run(self._run())
        except Exception as e:
            self.status("BLE 异常: %s" % e)


class PianoApp:
    def __init__(self, root):
        self.root = root
        self.root.title("ACG720 钢琴 — 13 黑 / 19 白")
        self.root.geometry("1180x470")
        self.root.configure(bg="#111820")
        self.root.protocol("WM_DELETE_WINDOW", self.close)

        self.active = {}          # note -> base velocity
        self.mouse_note = None
        self.kb_down = {}         # char -> note
        self.keys = []
        self.worker = None
        self.keymap = self.build_keymap()

        top = tk.Frame(root, bg="#111820")
        top.pack(fill="x", padx=16, pady=8)
        tk.Label(top, text="ACG720 PC 钢琴", fg="#7fd1ff", bg="#111820",
                 font=("Microsoft YaHei", 18, "bold")).pack(side="left")
        self.status_var = tk.StringVar(value="启动中...")
        tk.Label(top, textvariable=self.status_var, fg="#8fa3b8", bg="#111820",
                 font=("Microsoft YaHei", 10)).pack(side="left", padx=20)
        tk.Button(top, text="重新连接", command=self.reconnect).pack(side="right", padx=4)
        tk.Button(top, text="全部松开", command=self.all_off_ui).pack(side="right", padx=4)

        ctrl = tk.Frame(root, bg="#111820")
        ctrl.pack(fill="x", padx=16, pady=3)

        tk.Label(ctrl, text="力度", fg="#8fa3b8", bg="#111820").pack(side="left")
        self.vel_var = tk.IntVar(value=100)
        tk.Scale(ctrl, from_=1, to=127, orient="horizontal", variable=self.vel_var,
                 length=190, bg="#111820", fg="#dbe7f3", highlightthickness=0,
                 troughcolor="#243244").pack(side="left", padx=6)

        tk.Label(ctrl, text="主音量", fg="#8fa3b8", bg="#111820").pack(side="left", padx=(12, 0))
        self.master_var = tk.IntVar(value=100)
        tk.Scale(ctrl, from_=0, to=100, orient="horizontal", variable=self.master_var,
                 command=self.on_master, length=170, bg="#111820", fg="#dbe7f3",
                 highlightthickness=0, troughcolor="#243244").pack(side="left", padx=6)

        self.pos_vel = tk.BooleanVar(value=False)
        tk.Checkbutton(ctrl, text="点击位置决定力度（下重上轻）",
                       variable=self.pos_vel, bg="#111820", fg="#8fa3b8",
                       selectcolor="#111820", activebackground="#111820",
                       activeforeground="#ffffff").pack(side="left", padx=8)

        self.key_label = tk.StringVar(value="未按键")
        tk.Label(ctrl, textvariable=self.key_label, fg="#ffd166", bg="#111820",
                 font=("Consolas", 11)).pack(side="right")

        self.canvas = tk.Canvas(root, bg="#0b1016", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True, padx=16, pady=10)
        self.canvas.bind("<Configure>", self.redraw)
        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)

        help_text = ("电脑键盘：白键 A S D F G H J K L ; ' Z X C V B N M ,   |   "
                     "黑键 Q W E R T Y U I O P [ ] 、")
        tk.Label(root, text=help_text, fg="#5f7287", bg="#111820",
                 font=("Consolas", 9)).pack(fill="x", padx=16, pady=(0, 8))

        self.root.bind_all("<KeyPress>", self.on_key_press)
        self.root.bind_all("<KeyRelease>", self.on_key_release)
        self.root.bind("<FocusOut>", lambda e: self.all_off_ui())

        self.redraw()
        self.root.after(300, self.reconnect)

    def build_keymap(self):
        whites = [n for n in range(N_NOTES) if not is_black(n)]
        blacks = [n for n in range(N_NOTES) if is_black(n)]
        m = {}
        for c, n in zip(WHITE_KEYS, whites):
            m[c] = n
        for c, n in zip(BLACK_KEYS, blacks):
            m[c] = n
        return m

    # ---------- 画琴键 ----------
    def redraw(self, event=None):
        self.canvas.delete("all")
        self.keys.clear()

        w = max(self.canvas.winfo_width(), 800)
        h = max(self.canvas.winfo_height(), 260)
        margin = 4
        ww = (w - 2 * margin) / 19.0
        bw = ww * 0.62

        whites = [n for n in range(N_NOTES) if not is_black(n)]
        for idx, n in enumerate(whites):
            x0 = margin + idx * ww
            x1 = x0 + ww
            self.canvas.create_rectangle(x0, 0, x1, h, fill="#f2f2f2",
                                         outline="#555555", width=2,
                                         tags=("key", "n%d" % n))
            self.keys.append((n, x0, 0, x1, h, False))
            if idx % 3 == 0:
                self.canvas.create_text((x0 + x1) / 2, h - 18, text=note_name(n),
                                        fill="#777777", font=("Consolas", 9))

        for n in range(N_NOTES):
            if not is_black(n):
                continue
            before = sum(1 for m in range(n) if not is_black(m))
            center = margin + before * ww
            x0 = center - bw / 2
            x1 = center + bw / 2
            y1 = h * 0.62
            self.canvas.create_rectangle(x0, 0, x1, y1, fill="#15202b",
                                         outline="#000000", width=2,
                                         tags=("key", "n%d" % n))
            self.keys.append((n, x0, 0, x1, y1, True))

        for n in list(self.active.keys()):
            self.paint_note(n, True, redraw=True)

    def hit_note(self, x, y):
        for n, x0, y0, x1, y1, black in reversed(self.keys):
            if x0 <= x <= x1 and y0 <= y <= y1:
                return n
        return None

    def mouse_base_velocity(self, note, x, y):
        if not self.pos_vel.get():
            return max(1, min(127, int(self.vel_var.get())))
        for n, x0, y0, x1, y1, black in self.keys:
            if n == note:
                rel = max(0.0, min(1.0, (y - y0) / max(1, y1 - y0)))
                return max(8, min(127, int(8 + rel * 119)))
        return 100

    def scaled_vel(self, base):
        pct = max(0, min(100, int(self.master_var.get())))
        return max(1, min(127, int(round(base * pct / 100.0))))

    # ---------- 音符开关 ----------
    def note_on_ui(self, note, base_vel):
        vel = self.scaled_vel(base_vel)
        if note in self.active:
            self.active[note] = base_vel
            self.send(note_on(note, vel))
        else:
            self.active[note] = base_vel
            self.send(note_on(note, vel))
            self.paint_note(note, True)
        self.key_label.set("%s  vel=%d" % (note_name(note), vel))

    def note_off_ui(self, note):
        if note not in self.active:
            return
        del self.active[note]
        self.send(note_off(note))
        self.paint_note(note, False)
        if not self.active:
            self.key_label.set("未按键")

    def paint_note(self, note, active, redraw=False):
        if is_black(note):
            color = "#4ea1ff" if active else "#15202b"
        else:
            color = "#ff6b6b" if active else "#f2f2f2"
        self.canvas.itemconfigure("n%d" % note, fill=color)

    # ---------- 鼠标 ----------
    def on_press(self, event):
        self.root.focus_set()
        self.play_at(event.x, event.y)

    def on_drag(self, event):
        self.play_at(event.x, event.y)

    def on_release(self, event=None):
        if self.mouse_note is not None:
            self.note_off_ui(self.mouse_note)
            self.mouse_note = None

    def play_at(self, x, y):
        n = self.hit_note(x, y)
        if n is None:
            self.on_release()
            return
        if n == self.mouse_note:
            return
        if self.mouse_note is not None:
            self.note_off_ui(self.mouse_note)
        self.mouse_note = n
        self.note_on_ui(n, self.mouse_base_velocity(n, x, y))

    # ---------- 电脑键盘 ----------
    def event_key(self, event):
        ks = event.keysym.lower()
        return {
            "quoteleft": "grave",
            "asciitilde": "grave",
            "quoteright": "apostrophe",
            "ideographiccomma": "backslash",
        }.get(ks, ks)

    def on_key_press(self, event):
        ch = self.event_key(event)
        if ch not in self.keymap or ch in self.kb_down:
            return
        note = self.keymap[ch]
        self.kb_down[ch] = note
        self.note_on_ui(note, max(1, min(127, int(self.vel_var.get()))))

    def on_key_release(self, event):
        ch = self.event_key(event)
        note = self.kb_down.pop(ch, None)
        if note is not None:
            self.note_off_ui(note)

    # ---------- 主音量 ----------
    def on_master(self, _value=None):
        # 正在响的音也实时更新
        for note, base in list(self.active.items()):
            self.send(note_on(note, self.scaled_vel(base)))
        if self.active and hasattr(self, "key_label"):
            self.key_label.set("主音量 %d%%" % int(self.master_var.get()))

    # ---------- BLE ----------
    def send(self, data):
        if self.worker:
            self.worker.send(data)

    def all_off_ui(self):
        self.mouse_note = None
        self.kb_down.clear()
        for n in list(self.active.keys()):
            self.paint_note(n, False)
        self.active.clear()
        self.send(all_off())
        self.key_label.set("全部松开")

    def reconnect(self):
        if self.worker:
            self.worker.stop()
            self.worker = None
        self.status_var.set("连接中...")
        self.worker = BleWorker(DEFAULT_ADDRESS, self.set_status)
        self.worker.start()

    def set_status(self, text):
        self.root.after(0, lambda: self.status_var.set(text))

    def close(self):
        self.all_off_ui()
        if self.worker:
            self.worker.stop()
        self.root.after(100, self.root.destroy)


def main():
    root = tk.Tk()
    PianoApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()

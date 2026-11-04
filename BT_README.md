# 蓝牙曲库第一批（BLE → FPGA → 自动演奏）

本批目标：**手机/PC 发曲谱，FPGA 存进 BSRAM 并自动演奏**。不包含录音回传、键位表、LED 指引、外挂 Flash，这些放下一批。

## 1. 新增/修改的文件

| 文件 | 作用 |
|---|---|
| `src/uart_rx.v` / `src/uart_tx.v` | 115200 8N1 串口 |
| `src/bt_rx_frame.v` | `AA 55 / CMD / LEN / PAYLOAD / CRC16` 帧解析 |
| `src/bt_cmd.v` | 命令处理、曲库写入、统一状态回复 |
| `src/song_engine.v` | 4096×32 BSRAM + 1ms 播放器 |
| `src/acg720_instrument.v` | 顶层接入：双 UART、song_gate/song_vel、蓝牙灯 |
| `src/fpga_project.cst` | 新增 D14/D15/C14/J21/M15/M22/N22 |
| `bt_tools/pc_bt_test.py` | PC 串口测试脚本（先用它调通） |
| `esp32c3/ble_uart_bridge/` | ESP32-C3 BLE-UART 透传固件 |
| `miniprogram/` | 微信小程序骨架（扫描/连接/演奏/停止） |

## 2. 接线

### FPGA ←→ ESP32-C3

| ESP32-C3 | ACG720 | 说明 |
|---|---|---|
| 5V | 扩展口 5V | 供电 |
| GND | GND | 共地 |
| GPIO4 (TX) | **D14** (`bt_rx`) | ESP32 → FPGA |
| GPIO5 (RX) | **D15** (`bt_tx`) | FPGA → ESP32 |
| GPIO3 (STATE) | **C14** (`bt_state`) | 可选，连接后 D7 常亮 |

### FPGA ←→ PC（第一批先用这个调）

| USB-UART | ACG720 | 说明 |
|---|---|---|
| USB 口 | PC | 板载 USB 转串口 |
| — | **J21** (`dbg_rx`) | FPGA 接收 |
| — | **M15** (`dbg_tx`) | FPGA 发送 |
| GND | GND | 必须共地 |

> `bt_tx` 和 `dbg_tx` 输出的是同一路串口数据，所以 PC 和手机能看到同样的回复。

## 3. 协议

```
AA 55 | CMD(1) | LEN(1) | PAYLOAD(LEN) | CRC16(2, 低字节在前)
CRC16 = CCITT-FALSE, poly 0x1021, init 0xFFFF, 覆盖 CMD/LEN/PAYLOAD
```

| CMD | 功能 | 载荷 |
|---|---|---|
| 0x01 | PING | 无 |
| 0x20 | SONG_BEGIN | `count_lo, count_hi`（事件数 ≤4095） |
| 0x21 | SONG_EVENTS | `N×4` 字节事件（N≤15；BLE 用 3 个=12B） |
| 0x22 | SONG_END | `sum[31:0]` 小端（所有事件字的和） |
| 0x23 | PLAY | 无 |
| 0x24 | STOP | 无 |
| 0x25 | PAUSE | 第一版等同 STOP |
| 0x30 | STATUS | 无 |

事件 4 字节（小端）：

```
byte0 = velocity (0=note off, 1..255=note on)
byte1 = note (0..31, 0=C4)
byte2 = delta_lo
byte3 = delta_hi      // 相对上一个事件的毫秒数
```

> **注意**：同一个音符重复时，note-off 和下一个 note-on 之间至少留 1ms（建议 20–50ms）间隙。
> 否则 48.8kHz 的采样可能看不到 gate 拉低，音符不会重新起音（ADSR 不会重触发）。
> 不同音符可以 delta=0 同时触发（和弦）。

回复统一 14 字节：

```
AA 55 E0 08 [last_cmd status playing pos_lo pos_hi len_lo len_hi err] crc_lo crc_hi
```

`err`: 1 帧格式/命令错，2 EVENTS 长度错，3 事件数 >4095，4 事件数不匹配，5 校验和错，6 未加载完就 PLAY。

## 4. 上板步骤

1. 用 Gowin IDE 打开 `fpga_project.gprj`，确认 5 个新 `.v` 已在文件列表里（`.gprj` 已改；若 IDE 缓存旧列表，手动 Add Files）。
2. 综合 → 布局布线 → 下载。
3. 先不接 ESP32，用 USB 线连 PC，打开串口（115200 8N1）。
4. 运行：

```bash
pip install pyserial
python bt_tools/pc_bt_test.py --port COM5 --ping
python bt_tools/pc_bt_test.py --port COM5 --note 0 --ms 500
python bt_tools/pc_bt_test.py --port COM5 --demo
```

预期：

- `--ping` 收到 `<- 0xE0 last=0x01 status=0 ...`
- `--note 0` 响 C4 半秒
- `--demo` 响《小星星》，D6 随数据闪

> 注意：上电后前 3 秒是原有的 440Hz 自检音，等它结束再测蓝牙，不然会以为“怎么一直是单音”。

## 5. ESP32-C3 固件

Arduino IDE：

- 开发板：**ESP32C3 Dev Module**
- USB CDC On Boot：**Enabled**
- Flash Size：4MB
- 分区：Default 4MB with spiffs
- 打开 `esp32c3/ble_uart_bridge/ble_uart_bridge.ino`，编译下载

上电后手机能搜到 **ACG720-Synth**。

## 6. 微信小程序

1. 微信开发者工具 → 导入 `miniprogram/` 目录。
2. `project.config.json` 里 AppID 是 `touristappid`，正式用请改成你的 AppID。
3. 手机打开蓝牙；Android 需允许位置权限。
4. 点“扫描设备” → 点 `ACG720-Synth` → 点“演奏《小星星》”。

## 7. 常见问题

| 现象 | 排查 |
|---|---|
| PING 无回复 | TX/RX 是否交叉；波特率 115200；GND 是否共地；量 M15/D15 有没有波形 |
| 模拟器提示 `openBluetoothAdapter:fail already opened` | 正常（适配器已经打开），代码已按成功处理；但模拟器仍搜不到设备，点“预览/真机调试”用手机 |
| 模拟器提示 `not supported` | 模拟器没有蓝牙，点“预览/真机调试”用手机 |
| 收到 `status=1 err=5` | 手机/PC 算的 sum 和 FPGA 不一致，检查事件字节序 |
| 收到 `status=1 err=4` | `SONG_BEGIN` 的 count 和实际事件数不一致 |
| 有回复但没声音 | 是否在 `test_mode`/`chord_mode`（SW6/SW7 会覆盖 song_gate）；ES8388 是否初始化 |
| D7 不亮 | `bt_state` 没接（C14 悬空被下拉），只影响“已连接常亮”，不影响功能 |
| 音高不对 | note 0..31 对应 C4..G6，检查映射 |

## 8. 综合注意

- 本机 Gowin 的 `gwlicense.ini` 指向 `C:\Users\HP\Downloads\gowin_E_189341B33134.lic`，这个文件现在不在了，所以 `gw_sh` 起不来，**这里没有跑综合**；代码只做了 Verilog 语法解析。
- 在 Gowin IDE 里综合后重点看两处：
  1. `song_engine` 的 `mem` 是否推断成 BSRAM（资源报告里应看到约 8 个 BSRAM，而不是几万个寄存器）。如果没有，给 `reg [31:0] mem [0:4095];` 加 `(* syn_ramstyle = "block_ram" *)`。
  2. `frame_payload` / `vel_flat` 的 variable part-select 有没有 latch 警告；有的话把日志发我。
- 第一次综合前确认文件列表里 5 个新 `.v` 都在；`.gprj` 已改，IDE 若缓存旧列表就手动 Add Files。

## 9. 已知限制（本批）

- 曲谱只在 BSRAM，**掉电丢失**；下一步存板载 QSPI 或 W25Q64。
- 最大 4095 个事件（约 3–5 分钟，视音符密度）。
- `PAUSE` 等同 `STOP`，不做断点续播。
- 没有录音回传、键位表、LED 指引、7 段数码管。
- 校验用 32 位累加和，不是 CRC32；够用，但不如 CRC 稳。
- `loop_capture` 还在工程里但未使用，下一批用新的 recorder 替换。

## 10. 下一批计划

1. 事件录音（note on/off + 时间戳）→ BLE 分块回传，小程序画钢琴卷帘。
2. 32 字节键位表 + 移调。
3. 32 颗 WS2812 曲目指引（同时满足扩展 3 的可视化）。
4. 8 位数码管显示曲号/BPM/状态。
5. 曲谱落盘：板载 QSPI 或外挂 W25Q64。

> 说明：本机没有 Gowin license，无法在这里跑综合；代码已用 Verilog 解析器做过语法检查。第一次综合若有 warning/error，把日志发我，我按报错改。

# ACG720 FPGA 数字合成器

基于 **Gowin GW5AT-LV60PG484AC1/I0** 的 32 声部数字合成器项目。

硬件实体琴 + ESP32-C3 蓝牙桥 + Windows PC 控制台 + 微信小程序，四端协同：

- FPGA：32 声部实时合成、3 音色、ADSR、效果器、FSR 弯音、录音、曲库、LCD 仪表盘；
- ESP32-C3：BLE UART 透传桥（NUS），连接 FPGA 与 PC/小程序；
- PC 控制台：演奏、曲库管理、真实波形/FFT 频谱/李萨如、参数调节；
- 微信小程序：曲谱 JSON 导入、16 槽曲库存储、录音控制。

---

## 1. 系统架构

```
                    ┌──────────────────────────── FPGA (GW5AT-60) ───────────────────────────┐
实体琴键/FSR ─────►│ key_scan / adc128s102 ─► 32× synth_voice ─► mix ─► audio_effects ─► I2S │
SW6 复音测试 ─────►│ poly_test                                                            │
旋转编码器 ───────►│ rotary_vol (0-19)                                                     │
Flash 曲库 ───────►│ flash_song / flash_xact / song_engine / recorder                      │
LCD ─────────────►│ lcd_dashboard (480×320, 主界面 + 32声部频谱)                            │
LED/数码管 ──────►│ ws2812_piano / seg7_595                                                │
                    └───────────────────────────▲───────────────────────────────────────────┘
                                                │ UART
                              ┌─────────────────┴──────────────────┐
                              │        ESP32-C3 BLE NUS 桥          │
                              └───────────┬────────────────────────┬────────┘
                                          │                        │
                                 Windows PC 控制台              微信小程序
```

## 2. 功能特性

- **32 声部复音**：同时发声 32 音，C4–C7（note 0–31）。
- **3 音色**：钢琴 / 古筝 / 箫（SW0 或 PC 切换）。
- **ADSR**：每个音色内置默认包络，PC 下发后覆盖：
  - 钢琴：A2ms D1342ms S0 R300ms
  - 古筝：A1ms D1342ms S0 R300ms
  - 箫：A120ms D224ms S85% R200ms
- **效果器**（点按切换）：颤音（浅/深，5.5Hz 淡入）、滑音（快/慢）、合唱（20.5ms）、延迟（327ms）。
- **FSR 弯音**：压感条向上弯音 0～+2 半音，数码管显示 `b 00–49`。
- **音量**：旋钮 0–19；按住琴键 60%→100% 渐强。
- **录音**：S3 开始/停止，4095 事件，固定力度 200，自动存 Flash。
- **曲库**：16 槽 Flash 存储，曲谱 4095 事件上限，加载/播放/删除。
- **SW6 复音测试**：每 200ms 累加一个声部，6.4s 后 32 音齐响保持 1s。
- **LCD 仪表盘**：主界面（音色名/效果状态/力度条/音量条/具体音名/真实包络滚动条）+ 32 声部频谱页（200ms 自动刷新）。
- **PC 控制台**：演奏、曲库、真实采样波形、**FFT 频谱（128 点 Hann 窗，0–24kHz，Δ381Hz）**、李萨如、参数与遥测。
- **微信小程序**：曲谱 JSON 导入、16 槽存储、录音控制（BLE）。

## 3. 目录结构

```
fpga\            FPGA 全部源码 + build.tcl + fpga_project.gprj
esp32c3\         ESP32-C3 BLE 固件源码 + 烧录 bin
pc\              PC 控制台源码 + requirements.txt
pc_program\      打包好的 Windows 程序（可选运行）
miniprogram\     微信小程序
docs\            设计/调试文档
README.md        本文件
```

## 4. 构建方法

### 4.1 FPGA（Gowin）

- 工具：Gowin IDE **1.9.12.04**（或更高）
- 器件：GW5AT-LV60PG484AC1/I0
- 步骤：
  1. 打开 `fpga\fpga_project.gprj`；
  2. Synthesize → Place & Route；
  3. 下载 `impl\pnr\fpga_project.fs`。
- 命令行（可选）：

```powershell
cd fpga
gw_sh.exe build.tcl
```

- 资源占用参考：

```
CLS  ~96%    BSRAM ~95%    DSP ~62%    Fmax ≈ 50.044MHz
```

### 4.2 ESP32-C3

- 用 Arduino IDE 编译烧录 `esp32c3\ble_uart_bridge.ino`；
- 或直接烧录 `esp32c3\ble_uart_bridge.merged.bin`；
- BLE 参数：名称 `ACG720-Synth`，地址 `9C:96:D5:B1:61:6A`，MTU 247。

### 4.3 PC 控制台

```powershell
pip install -r pc\requirements.txt
python pc\pc_app.py
```

或直接运行打包版：

```
pc_program\ACG720_Console\ACG720_Console.exe
```

连接蓝牙 `ACG720-Synth` 后使用。

### 4.4 微信小程序

1. 微信开发者工具导入 `miniprogram\`；
2. AppID：`wx149da67d5aac8e92`；
3. 真机预览（模拟器不支持 BLE）。

## 5. BLE 协议

帧格式：

```
AA 55 | CMD | LEN | PAYLOAD | CRC16(CCITT-FALSE)
```

常用命令：

| 命令 | 功能 |
|---|---|
| 0x40/0x41/0x42 | 音符开 / 关 / 全部关 |
| 0x43/0x44/0x45/0x46/0x47 | 音量 / 音色 / 效果 / 弯音 / ADSR |
| 0x20–0x2A | 曲谱传输与保存（BEGIN/EVENTS/END/PLAY/STOP/SAVE/LOAD/DELETE/LIST/NAME） |
| 0x2C | 录音控制 |
| 0x30 | 状态查询 |
| 0x48/0x49 | 遥测：按键/力度/音量、音色/效果参数 |
| 0x50/0x51 | 真实采样（128 点 16 位，22 块） |
| 0xE0/0xE1/0xE2 | 应答 / 曲名 / 采样块 |

## 6. 曲谱 JSON 格式

```json
{
  "name": "小星星",
  "events": [
    [0,   0, 200],
    [400, 0, 0]
  ]
}
```

- `events[i] = [delta_ms, note, velocity]`；
- `delta_ms`：距上一事件的毫秒数，0–65535；
- `note`：0–31（0=C4 … 31=C7）；
- `velocity`：1–255 按下，0 松开；
- 事件总数 ≤ 4095；`name` 最多 16 字节（5 个汉字）。

示例曲谱位于 `miniprogram\examples\`。

## 7. 实体琴操作

| 控件 | 功能 |
|---|---|
| 琴键 | 演奏（32 复音） |
| FSR 压感条 | 弯音 0～+2 半音 |
| 音量旋钮 | 主音量 0–19 |
| SW0 | 音色切换：钢琴→古筝→箫 |
| SW6 | 32 复音测试开/关 |
| S1 | LCD 第一页 ↔ 频谱页 |
| S2 | 曲库加载/播放 |
| S3 | 录音开始/停止 |
| 效果键 | 颤音 / 滑音 / 合唱 / 延迟（点按切换） |

## 8. 注意事项

- ESP32 同一时刻只允许一个 BLE 中心连接：PC 与小程序不能同时连；
- LCD 显示为横屏 480×320，实体屏若竖装请旋转 90°；
- 曲库曲名最多 5 个汉字或 16 个 ASCII 字符；
- PC 真实采样/FFT 依赖 BLE 传输，刷新率受限于无线链路。

## 9. 版本

- FPGA 合并版（3 音色 + 动态 LCD 仪表盘 + SW6 复音测试）
- PC 控制台、微信小程序、ESP32 固件同步更新

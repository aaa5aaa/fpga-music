# ESP32-C3 BLE 桥接固件（已编译）

## 文件

| 文件 | 说明 |
|---|---|
| `ble_uart_bridge.merged.bin` | 4MB 完整镜像（bootloader + 分区表 + app），从 0x0 烧录 |
| `ble_uart_bridge.app.bin` | 仅应用（0x10000），一般不用 |
| `flash_esp32.bat` | 一键烧录脚本 |

编译环境：Arduino ESP32 core **3.2.1-cn**，目标 **ESP32C3 Dev Module**，
`USB CDC On Boot = Enabled`，Flash 4MB，Default 4MB with spiffs。

## 方法一：批处理烧录（最快）

1. 用 **USB-C 数据线**把 SuperMini 插到电脑；
2. 设备管理器看 COM 口（例如 `COM7`）；
3. 双击 `flash_esp32.bat COM7`（把 COM7 换成实际端口）；
4. 看到 `Hash of data verified` / `Leaving...` 即成功；
5. 打开串口 115200，应打印：
   ```
   ACG720-Synth BLE bridge ready
   ```

> 烧录失败：按住 **BOOT**，点一下 **RST**，松开 BOOT，再运行脚本。

## 方法二：Arduino IDE

ESP32 core 3.2.1-cn 已经装到：
```
C:\Users\HP\AppData\Local\Arduino15\packages\esp32\hardware\esp32\3.2.1-cn
```

1. **完全关闭并重开 Arduino IDE**；
2. Tools → Board → ESP32 Arduino → **ESP32C3 Dev Module**；
3. Tools → **USB CDC On Boot → Enabled**；
4. Tools → Port 选 SuperMini 的 COM 口；
5. 打开：
   ```
   D:\musial_v22\musial_v12_bt_timbre_knob\esp32c3\ble_uart_bridge\ble_uart_bridge.ino
   ```
6. 点 Upload。

## 接线

| ESP32-C3 SuperMini | ACG720 |
|---|---|
| 5V | 扩展口 5V |
| GND | GND |
| GPIO4 (TX) | D14 (`bt_rx`) |
| GPIO5 (RX) | D15 (`bt_tx`) |
| GPIO3 | C14 (`bt_state`) |

- 5V/GND 并 100µF + 0.1µF；
- 天线远离 LCD 排线和金属；
- UART 是 **TX↔RX 交叉**，不要 TX-TX。

## 验证

- 手机蓝牙能搜到 `ACG720-Synth`；
- 微信小程序连接后，FPGA 的 D7 常亮；
- `pc_bt_test.py --port COMx --ping` 有回复（走板载 USB-UART 也可以）。

## 备注

- 固件是 **NUS 透传桥**：BLE ↔ UART 115200，协议全在 FPGA；
- `BLECharacteristic::getValue()` 在 core 3.x 返回 `String`，源码已按 3.x 适配；
- 若 IDE 里看不到 3.2.1-cn：检查 `Arduino15\packages\esp32\hardware\esp32\3.2.1-cn\boards.txt` 是否存在，或直接用批处理烧录。

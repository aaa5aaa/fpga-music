/*
 * ble_uart_bridge.ino — ESP32-C3 BLE-UART 透传（Nordic UART Service）
 *
 * 手机小程序 <--BLE--> ESP32-C3 <--UART 115200--> FPGA (D14/D15)
 *
 * 接线（ESP32-C3 SuperMini）:
 *   ESP32 5V   -> ACG720 扩展口 5V
 *   ESP32 GND  -> ACG720 GND
 *   ESP32 GPIO4 (TX) -> FPGA D14 (bt_rx)
 *   ESP32 GPIO5 (RX) <- FPGA D15 (bt_tx)
 *   ESP32 GPIO8 板载 LED（可选，连接指示）
 *
 * Arduino IDE:
 *   开发板: ESP32C3 Dev Module
 *   USB CDC On Boot: Enabled
 *   Flash Size: 4MB
 *   分区: Default 4MB with spiffs
 *
 * 依赖: ESP32 Arduino core 自带的 BLE 库（BLEDevice），无需额外安装。
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID      "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_RX_UUID      "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // 手机 -> FPGA
#define CHAR_TX_UUID      "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // FPGA -> 手机

#define PIN_UART_RX       5    // ESP32 RX  <- FPGA D15
#define PIN_UART_TX       4    // ESP32 TX  -> FPGA D14
#define PIN_LED           8    // SuperMini 板载 LED，低有效
#define PIN_STATE         3    // 连接状态 -> FPGA C14 (bt_state)，可选

static BLECharacteristic *tx_char = nullptr;
static BLECharacteristic *rx_char = nullptr;
static volatile bool     connected = false;

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *server) override {
        connected = true;
        digitalWrite(PIN_LED, LOW);          // 亮
        digitalWrite(PIN_STATE, HIGH);       // 通知 FPGA: 已连接
        Serial.println("BLE connected");
    }
    void onDisconnect(BLEServer *server) override {
        connected = false;
        digitalWrite(PIN_LED, HIGH);         // 灭
        digitalWrite(PIN_STATE, LOW);
        Serial.println("BLE disconnected");
        server->getAdvertising()->start();
    }
};

class RxCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *c) override {
        String v = c->getValue();
        if (v.length() > 0) {
            Serial1.write((const uint8_t *)v.c_str(), v.length());
        }
    }
};

void setup() {
    pinMode(PIN_LED, OUTPUT);
    digitalWrite(PIN_LED, HIGH);
    pinMode(PIN_STATE, OUTPUT);
    digitalWrite(PIN_STATE, LOW);

    Serial.begin(115200);
    delay(100);

    Serial1.begin(115200, SERIAL_8N1, PIN_UART_RX, PIN_UART_TX);

    BLEDevice::init("ACG720-Synth");
    // 如果所用的 ESP32 core 编译报 setMTU 不存在，删掉下面这一行即可
    BLEDevice::setMTU(247);

    BLEServer *server = BLEDevice::createServer();
    server->setCallbacks(new ServerCallbacks());

    BLEService *service = server->createService(SERVICE_UUID);

    rx_char = service->createCharacteristic(
        CHAR_RX_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    rx_char->setCallbacks(new RxCallbacks());

    tx_char = service->createCharacteristic(
        CHAR_TX_UUID,
        BLECharacteristic::PROPERTY_NOTIFY);
    tx_char->addDescriptor(new BLE2902());

    service->start();

    BLEAdvertising *adv = BLEDevice::getAdvertising();
    adv->addServiceUUID(SERVICE_UUID);
    adv->setScanResponse(true);
    adv->setMinPreferred(0x06);
    adv->setMinPreferred(0x12);
    BLEDevice::startAdvertising();

    Serial.println("ACG720-Synth BLE bridge ready");
}

void loop() {
    static uint8_t buf[128];
    int n = 0;

    while (Serial1.available() && n < (int)sizeof(buf)) {
        buf[n++] = (uint8_t)Serial1.read();
    }

    if (n > 0 && connected && tx_char != nullptr) {
        // 回复帧最长 14 字节，20 字节一包足够
        for (int i = 0; i < n; i += 20) {
            int len = (n - i > 20) ? 20 : (n - i);
            tx_char->setValue(buf + i, len);
            tx_char->notify();
            delay(4);
        }
    }

    delay(1);
}

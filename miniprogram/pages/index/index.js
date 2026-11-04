// ACG720 BLE 电子琴 —— 微信小程序
// 协议: AA 55 | CMD | LEN | PAYLOAD | CRC16(低,高)
// 事件: delta_ms(16) | note(8) | velocity(8)

const SERVICE_UUID  = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const CHAR_RX_UUID  = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
const CHAR_TX_UUID  = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

const CMD_PING        = 0x01;
const CMD_SONG_BEGIN  = 0x20;
const CMD_SONG_EVENTS = 0x21;
const CMD_SONG_END    = 0x22;
const CMD_PLAY        = 0x23;
const CMD_STOP        = 0x24;
const CMD_SAVE        = 0x26;
const CMD_LOAD        = 0x27;
const CMD_DELETE      = 0x28;
const CMD_LIST        = 0x29;
const CMD_NAME        = 0x2A;
const CMD_STATUS      = 0x30;
const CMD_REC         = 0x2C;
const RSP_STATUS      = 0xE0;
const RSP_NAME        = 0xE1;

function utf8Bytes(str, max) {
  const enc = encodeURIComponent(str || '');
  const out = [];
  for (let i = 0; i < enc.length && out.length < max;) {
    if (enc[i] === '%') {
      out.push(parseInt(enc.substr(i + 1, 2), 16));
      i += 3;
    } else {
      out.push(enc.charCodeAt(i));
      i += 1;
    }
  }
  while (out.length < max) out.push(0);
  return out;
}

function utf8Decode(bytes) {
  const clean = [];
  for (const b of bytes) {
    if (b === 0 || b === 0xFF) break;
    clean.push(b);
  }
  if (!clean.length) return '';
  let esc = '';
  clean.forEach(b => { esc += '%' + b.toString(16).padStart(2, '0'); });
  try { return decodeURIComponent(esc); } catch (e) { return ''; }
}

function crc16(bytes) {
  let crc = 0xFFFF;
  for (let i = 0; i < bytes.length; i++) {
    crc ^= (bytes[i] << 8) & 0xFFFF;
    for (let b = 0; b < 8; b++) {
      crc = (crc & 0x8000) ? (((crc << 1) ^ 0x1021) & 0xFFFF) : ((crc << 1) & 0xFFFF);
    }
  }
  return crc & 0xFFFF;
}

function buildFrame(cmd, payload) {
  const p = payload || [];
  const body = [cmd, p.length].concat(p);
  const c = crc16(body);
  return [0xAA, 0x55].concat(body, [c & 0xFF, (c >> 8) & 0xFF]);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function promisify(fn, opts) {
  return new Promise((resolve, reject) => fn(Object.assign({}, opts, { success: resolve, fail: reject })));
}

Page({
  data: {
    ready: false,
    connected: false,
    devices: [],
    slot: 0,
    slotNo: '01',
    slotLabel: '01 ○',
    slotMask: 0,
    slotCurrent: 0,
    slotNames: {},
    recActive: false,
    recEvents: 0,
    slots: ['01','02','03','04','05','06','07','08','09','10','11','12','13','14','15','16'],
    slotCards: [],
    fileName: '',
    fileEvents: 0,
    fileReady: false,
    recordName: '录音',
    status: '正在初始化蓝牙...'
  },

  onLoad() {
    this.rx = [];
    this.ble = null;
    this.namePending = null;
    this.fetchingNames = false;
    this.sendingSong = false;
    this.statusTimer = null;
    let names = {};
    try { names = wx.getStorageSync('slotNames') || {}; } catch (e) {}
    this.setData({
      slotNames: names,
      slotLabel: '01 ○'
    });
    this.refreshSlots(0, 0);
    this.initBLE();
  },

  initBLE() {
    const markReady = () => {
      if (this._adapterReady) return;
      this._adapterReady = true;

      const inDevtools = wx.getSystemInfoSync().platform === 'devtools';
      this.setData({
        ready: true,
        status: inDevtools
          ? '模拟器不支持蓝牙：请点顶部“预览”，用手机扫码测试'
          : '蓝牙已就绪，点“扫描设备”'
      });

      wx.onBLEConnectionStateChange(res => {
        if (!res.connected) {
          this.clearPending(new Error('连接已断开'));
          this.rejectNamePending(new Error('连接已断开'));
          this.stopStatusPoll();
          this.setData({ connected: false, recActive: false, status: '连接已断开' });
        }
      });
      wx.onBLECharacteristicValueChange(res => {
        this.rx = this.rx.concat(Array.from(new Uint8Array(res.value)));
        this.parseRx();
      });
    };

    wx.openBluetoothAdapter({
      success: markReady,
      fail: err => {
        const msg = (err && err.errMsg) || '';
        // 重新编译/热重载时适配器可能已经打开，这是正常的
        if (msg.indexOf('already opened') >= 0 || (err && err.errCode === 10001)) {
          markReady();
        } else if (msg.indexOf('not supported') >= 0) {
          markReady();
        } else {
          this.setData({ ready: false, status: '请打开手机蓝牙: ' + msg });
        }
      }
    });
  },

  scan() {
    if (!this.data.ready) return;

    // 模拟器没有蓝牙，点了也搜不到，直接提示用手机
    if (wx.getSystemInfoSync().platform === 'devtools') {
      wx.showModal({
        title: '模拟器不支持蓝牙',
        content: '请点顶部“预览”或“真机调试”，用手机微信扫码后测试。',
        showCancel: false
      });
      return;
    }

    this.setData({ devices: [], status: '扫描中...' });
    wx.onBluetoothDeviceFound(res => {
      const map = {};
      this.data.devices.forEach(d => { map[d.deviceId] = d; });
      (res.devices || []).forEach(d => {
        if (d.name && d.name.indexOf('ACG720') >= 0) {
          map[d.deviceId] = { deviceId: d.deviceId, name: d.name };
        }
      });
      this.setData({ devices: Object.keys(map).map(k => map[k]) });
    });
    wx.startBluetoothDevicesDiscovery({
      allowDuplicatesKey: false,
      fail: err => this.setData({ status: '扫描失败: ' + err.errMsg })
    });
  },

  async negotiateMTU(deviceId) {
    let mtu = 23;
    try {
      if (wx.setBLEMTU) {
        const r = await promisify(wx.setBLEMTU, { deviceId, mtu: 247 });
        if (r && r.mtu) mtu = r.mtu;
      }
    } catch (e) {}
    try {
      if (wx.getBLEMTU) {
        const g = await promisify(wx.getBLEMTU, { deviceId });
        if (g && g.mtu) mtu = g.mtu;
      }
    } catch (e) {}
    // 最大 247，最小 23；实际可用值由系统返回
    return Math.max(23, Math.min(mtu, 247));
  },

  async connect(e) {
    const id = e.currentTarget.dataset.id;
    try {
      this.setData({ status: '连接中...' });
      wx.stopBluetoothDevicesDiscovery();

      await promisify(wx.createBLEConnection, { deviceId: id, timeout: 10000 });

      // 先协商 MTU，后面才能一帧多发几个事件
      this.mtu = await this.negotiateMTU(id);

      const svc = await promisify(wx.getBLEDeviceServices, { deviceId: id });
      const service = svc.services.find(s => s.uuid.toUpperCase() === SERVICE_UUID);
      if (!service) throw new Error('找不到 NUS 服务');

      const ch = await promisify(wx.getBLEDeviceCharacteristics, {
        deviceId: id, serviceId: service.uuid
      });
      const rx = ch.characteristics.find(c => c.uuid.toUpperCase() === CHAR_RX_UUID);
      const tx = ch.characteristics.find(c => c.uuid.toUpperCase() === CHAR_TX_UUID);
      if (!rx || !tx) throw new Error('找不到 RX/TX 特征');

      await promisify(wx.notifyBLECharacteristicValueChange, {
        deviceId: id,
        serviceId: service.uuid,
        characteristicId: tx.uuid,
        state: true
      });

      this.ble = { deviceId: id, serviceId: service.uuid, rxId: rx.uuid, txId: tx.uuid };
      this.setData({
        connected: true,
        status: '已连接，可以演奏（MTU ' + (this.mtu || 23) + '）'
      });

      // 握手
      await this.writeFrame(CMD_PING, []);
      await this.writeFrame(CMD_LIST, []);
      this.startStatusPoll();
    } catch (err) {
      this.setData({ status: '连接失败: ' + (err.errMsg || err.message || err) });
    }
  },

  async disconnect() {
    if (!this.ble) {
      this.setData({ status: '当前没有蓝牙连接' });
      return;
    }
    const id = this.ble.deviceId;
    this.ble = null;
    this.stopStatusPoll();
    this.clearPending(new Error('断开连接'));
    this.rejectNamePending(new Error('断开连接'));
    this.setData({
      connected: false,
      recActive: false,
      recEvents: 0,
      status: '已断开蓝牙'
    });
    try { await promisify(wx.closeBLEConnection, { deviceId: id }); } catch (e) {}
    wx.stopBluetoothDevicesDiscovery();
  },

  clearPending(err) {
    if (!this.pending) return;
    clearTimeout(this.pending.timer);
    const p = this.pending;
    this.pending = null;
    if (err) p.reject(err);
  },

  waitStatus(cmd, timeoutMs) {
    return new Promise((resolve, reject) => {
      this.clearPending(new Error('新的命令开始'));
      const timer = setTimeout(() => {
        if (this.pending && this.pending.cmd === cmd) {
          this.pending = null;
          reject(new Error('等待 FPGA 回复超时'));
        }
      }, timeoutMs);
      this.pending = { cmd, resolve, reject, timer };
    });
  },

  writeFrame(cmd, payload) {
    if (!this.ble) return Promise.reject(new Error('未连接'));
    const arr = buildFrame(cmd, payload);
    const buf = new Uint8Array(arr).buffer;
    return promisify(wx.writeBLECharacteristicValue, {
      deviceId: this.ble.deviceId,
      serviceId: this.ble.serviceId,
      characteristicId: this.ble.rxId,
      value: buf
    });
  },

  refreshSlots(mask, current) {
    const arr = [];
    const cards = [];
    const names = this.data.slotNames || {};
    for (let i = 0; i < 16; i++) {
      const n = String(i + 1).padStart(2, '0');
      const has = (mask >> i) & 1;
      const name = has ? (names[i] || '已存曲谱') : '';
      arr.push(n + (has ? ' ●' : ' ○') + (name ? ' ' + name : ''));
      cards.push({
        idx: i,
        no: n,
        has: !!has,
        name: name,
        active: i === this.data.slot
      });
    }
    this.setData({
      slots: arr,
      slotCards: cards,
      slotNo: cards[this.data.slot] ? cards[this.data.slot].no : '01',
      slotLabel: arr[this.data.slot] || arr[0],
      slotMask: mask,
      slotCurrent: current
    });
  },

  selectSlot(e) {
    const idx = Number(e.currentTarget.dataset.index);
    const cards = this.data.slotCards.map(c => Object.assign({}, c, { active: c.idx === idx }));
    this.setData({
      slot: idx,
      slotNo: String(idx + 1).padStart(2, '0'),
      slotLabel: this.data.slots[idx] || String(idx + 1).padStart(2, '0'),
      slotCards: cards
    });
  },

  requestList() {
    if (!this.ble) return Promise.resolve();
    return this.writeFrame(CMD_LIST, []).catch(() => {});
  },

  startStatusPoll() {
    this.stopStatusPoll();
    this.statusTimer = setInterval(() => {
      if (!this.data.connected || this.sendingSong ||
          this.pending || this.namePending) return;
      this.writeFrame(CMD_STATUS, []).catch(() => {});
    }, 800);
  },

  stopStatusPoll() {
    if (this.statusTimer) {
      clearInterval(this.statusTimer);
      this.statusTimer = null;
    }
  },

  rejectNamePending(err) {
    if (!this.namePending) return;
    clearTimeout(this.namePending.timer);
    const p = this.namePending;
    this.namePending = null;
    if (err) p.reject(err);
  },

  queryName(slot, part) {
    return new Promise((resolve, reject) => {
      if (this.namePending) {
        reject(new Error('名称查询忙'));
        return;
      }
      const timer = setTimeout(() => {
        if (this.namePending && this.namePending.slot === slot &&
            this.namePending.part === part) {
          this.namePending = null;
          reject(new Error('读曲名超时'));
        }
      }, 800);
      this.namePending = { slot, part, resolve, reject, timer };
      this.writeFrame(CMD_NAME, [slot & 0xFF, part & 0xFF]).catch(err => {
        this.rejectNamePending(err);
      });
    });
  },

  async fetchMissingNames(mask) {
    if (this.fetchingNames || !this.ble) return;
    this.fetchingNames = true;
    const names = Object.assign({}, this.data.slotNames);
    let changed = false;
    try {
      for (let i = 0; i < 16; i++) {
        if (!((mask >> i) & 1) || names[i]) continue;
        const b0 = await this.queryName(i, 0);
        const b1 = await this.queryName(i, 1);
        const name = utf8Decode(b0.concat(b1));
        if (name) { names[i] = name; changed = true; }
      }
      if (changed) {
        this.setData({ slotNames: names });
        try { wx.setStorageSync('slotNames', names); } catch (e) {}
        this.refreshSlots(this.data.slotMask, this.data.slotCurrent);
      }
    } catch (e) {
      // 旧固件没有 NAME 命令时静默失败，列表显示“有曲”
    } finally {
      this.fetchingNames = false;
    }
  },

  errText(code) {
    const map = {
      0: '成功',
      1: '参数或状态错误',
      2: '事件数错误',
      3: '曲谱长度超限',
      4: '事件数不一致',
      5: '校验和错误',
      6: '没有可播放曲目',
      7: '保存校验失败',
      8: '保存超时',
      9: '加载超时',
      10: '删除超时',
      11: '加载播放超时',
      12: '槽位没有曲名'
    };
    return map[code] || ('错误码 ' + code);
  },

  async sendCommand(cmd, payload, timeoutMs) {
    if (this.pending) throw new Error('上一条命令还在等待回复');
    const statusP = this.waitStatus(cmd, timeoutMs);
    try {
      await this.writeFrame(cmd, payload);
    } catch (err) {
      this.clearPending(err);
      statusP.catch(() => {});
      throw err;
    }
    const r = await statusP;
    if (r.status !== 0 || r.err !== 0) {
      throw new Error(`status=${r.status}，${this.errText(r.err)}`);
    }
    return r;
  },

  parseRx() {
    while (this.rx.length >= 6) {
      let i = 0;
      while (i + 1 < this.rx.length && !(this.rx[i] === 0xAA && this.rx[i + 1] === 0x55)) i++;
      if (i > 0) this.rx = this.rx.slice(i);
      if (this.rx.length < 4) return;

      const len = this.rx[3];
      if (this.rx.length < 6 + len) return;

      const frame = this.rx.slice(0, 6 + len);
      this.rx = this.rx.slice(6 + len);

      if (frame[2] === RSP_NAME && len === 8) {
        const data = Array.from(frame.slice(4, 12));
        if (this.namePending) {
          clearTimeout(this.namePending.timer);
          const pending = this.namePending;
          this.namePending = null;
          pending.resolve(data);
        }
        continue;
      }

      if (frame[2] === RSP_STATUS && len === 8) {
        const p = frame.slice(4, 12);
        const pos = p[3] | ((p[4] & 0x0F) << 8);
        const slen = p[5] | ((p[6] & 0x0F) << 8);
        const isRec = (p[2] & 0x80) !== 0;
        const info = {
          cmd: p[0], status: p[1], playing: p[2] & 0x7F,
          pos: pos, len: slen, err: p[7],
          rec: isRec, recEvents: isRec ? pos : 0
        };
        if (this.pending && this.pending.cmd === info.cmd) {
          clearTimeout(this.pending.timer);
          const pending = this.pending;
          this.pending = null;
          pending.resolve(info);
        }
        const prefix = this.data.connected ? '已连接 · ' : '';
        if (info.cmd === CMD_LIST) {
          const mask = p[2] | (p[3] << 8);
          const current = p[4] & 0x0F;
          let count = 0;
          for (let b = 0; b < 16; b++) count += (mask >> b) & 1;
          this.refreshSlots(mask, current);
          this.fetchMissingNames(mask);
          this.setData({
            status: `${prefix}曲库 ${count} 首，当前槽 ${current + 1}`
          });
        } else if (info.cmd === CMD_STATUS) {
          if (isRec) {
            this.setData({ recActive: true, recEvents: pos });
          } else if (this.data.recActive) {
            this.setData({ recActive: false, recEvents: 0 });
            this.requestList();
            setTimeout(() => this.requestList(), 1500);
          }
          if (info.err !== 0) {
            this.setData({ status: `${prefix}状态错误 err=${info.err}` });
          }
        } else {
          this.setData({
            status: `${prefix}status=${info.status} playing=${info.playing} pos=${info.pos}/${info.len} err=${info.err}`
          });
        }
        if ((info.cmd === CMD_SAVE || info.cmd === CMD_LOAD || info.cmd === CMD_DELETE) &&
            info.status === 0) {
          this.requestList();
        }
      }
    }
  },

  demoEvents() {
    // 小星星完整版：0=C4 2=D4 4=E4 5=F4 7=G4 9=A4
    // C C G G A A G | F F E E D D C | G G F F E E D
    // G G F F E E D | C C G G A A G | F F E E D D C
    const notes = [
      0, 0, 7, 7, 9, 9, 7,
      5, 5, 4, 4, 2, 2, 0,
      7, 7, 5, 5, 4, 4, 2,
      7, 7, 5, 5, 4, 4, 2,
      0, 0, 7, 7, 9, 9, 7,
      5, 5, 4, 4, 2, 2, 0
    ];
    const durs = [
      400, 400, 400, 400, 400, 400, 800,
      400, 400, 400, 400, 400, 400, 800,
      400, 400, 400, 400, 400, 400, 800,
      400, 400, 400, 400, 400, 400, 800,
      400, 400, 400, 400, 400, 400, 800,
      400, 400, 400, 400, 400, 400, 800
    ];
    const ev = [];
    let first = true;
    for (let i = 0; i < notes.length; i++) {
      // 同一音符重复时留 30ms 间隙，保证 gate 能被 48.8kHz 采样到拉低
      ev.push([first ? 100 : 30, notes[i], 200]);
      ev.push([Math.max(50, durs[i] - 30), notes[i], 0]);
      first = false;
    }
    return ev;
  },

  normalizeSong(obj) {
    if (!obj || !Array.isArray(obj.events)) {
      throw new Error('JSON 需要 "events" 数组');
    }
    if (obj.events.length === 0) throw new Error('events 为空');
    if (obj.events.length > 4095) throw new Error('事件数超过 4095');

    return obj.events.map((e, idx) => {
      if (!Array.isArray(e) || e.length < 3) {
        throw new Error('第 ' + (idx + 1) + ' 个事件格式应为 [delta_ms, note, velocity]');
      }
      const d = Number(e[0]);
      const n = Number(e[1]);
      const v = Number(e[2]);
      if (!Number.isFinite(d) || !Number.isFinite(n) || !Number.isFinite(v)) {
        throw new Error('第 ' + (idx + 1) + ' 个事件不是数字');
      }
      if (d < 0 || d > 65535) throw new Error('第 ' + (idx + 1) + ' 个 delta 超出 0..65535');
      if (n < 0 || n > 31) throw new Error('第 ' + (idx + 1) + ' 个 note 超出 0..31');
      if (v < 0 || v > 255) throw new Error('第 ' + (idx + 1) + ' 个 velocity 超出 0..255');
      return [Math.round(d), Math.round(n), Math.round(v)];
    });
  },

  async importSong() {
    if (!this.data.connected) return;
    try {
      this.setData({ status: '请选择 JSON 曲谱文件...' });

      let res;
      try {
        res = await promisify(wx.chooseMessageFile, {
          count: 1, type: 'file', extension: ['json']
        });
      } catch (e) {
        const msg = (e && e.errMsg) || '';
        if (msg.indexOf('cancel') >= 0) throw e;
        // 有些 Android 文件选择器不认 extension，退化为全部文件
        res = await promisify(wx.chooseMessageFile, { count: 1, type: 'all' });
      }

      const file = res.tempFiles && res.tempFiles[0];
      if (!file) throw new Error('没有选择文件');
      const path = file.path || file.tempFilePath;
      if (!path) throw new Error('拿不到文件路径');

      const read = await promisify(wx.getFileSystemManager().readFile, {
        filePath: path,
        encoding: 'utf8'
      });
      let text = typeof read.data === 'string' ? read.data : '';
      text = text.replace(/^\uFEFF/, '');   // 去掉 BOM
      const obj = JSON.parse(text);
      const events = this.normalizeSong(obj);
      const name = obj.name || file.name || '曲谱';

      this.setData({
        fileName: name,
        fileEvents: events.length,
        fileReady: true,
        status: `导入 ${name}：${events.length} 个事件，发送中...`
      });
      await this.sendSong(events, false, name);
    } catch (err) {
      this.setData({ fileReady: false, status: '导入失败: ' + (err.errMsg || err.message || err) });
    }
  },

  async sendSong(events, autoPlay, songName) {
    this.currentSongName = songName || '未命名';
    this.sendingSong = true;
    let lastErr;
    try {
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          await this.sendSongOnce(events, autoPlay);
          return;
        } catch (err) {
          lastErr = err;
          if (attempt < 2) {
            this.setData({ status: `发送失败（${err.message || err}），重试 ${attempt + 1}/2...` });
            await sleep(300);
          }
        }
      }
      throw lastErr;
    } finally {
      this.sendingSong = false;
    }
  },

  async sendSongOnce(events, autoPlay) {
    const words = events.map(e => ((e[0] & 0xFFFF) << 16) | ((e[1] & 0xFF) << 8) | (e[2] & 0xFF));

    await this.writeFrame(CMD_SONG_BEGIN, [events.length & 0xFF, (events.length >> 8) & 0xFF]);

    // 帧总长 = 6 + payload；BLE 单次写上限 = MTU-3
    // 协议 LEN 只有 6 位，payload 最多 63 字节，所以每帧最多 15 个事件
    const mtu = this.mtu || 23;
    const maxEvents = Math.max(1, Math.min(15, Math.floor(Math.min(63, mtu - 9) / 4)));
    const totalChunks = Math.ceil(words.length / maxEvents);

    let sum = 0;
    let chunk = 0;
    for (let i = 0; i < words.length; i += maxEvents) {
      const part = words.slice(i, i + maxEvents);
      const payload = [];
      part.forEach(w => {
        payload.push(w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF);
        sum = (sum + w) >>> 0;
      });
      await this.writeFrame(CMD_SONG_EVENTS, payload);
      chunk += 1;
      if (chunk % 20 === 0 || chunk === totalChunks) {
        this.setData({ status: `发送中 ${Math.floor(chunk * 100 / totalChunks)}%...` });
      }
      await sleep(8);
    }

    // 先挂起等待，再发 SONG_END，避免回复比 Promise 先到
    const statusP = this.waitStatus(CMD_SONG_END, 8000);
    try {
      await this.writeFrame(CMD_SONG_END, [
        sum & 0xFF, (sum >> 8) & 0xFF, (sum >> 16) & 0xFF, (sum >> 24) & 0xFF
      ]);
    } catch (err) {
      this.clearPending(err);
      statusP.catch(() => {});
      throw err;
    }

    const r = await statusP;
    if (r.status !== 0 || r.err !== 0) {
      throw new Error(`FPGA 校验失败 status=${r.status} err=${r.err}`);
    }
    const expectLen = events.length & 0x0FFF;
    if (r.len !== expectLen) {
      throw new Error(`事件数不一致 ${r.len}/${events.length}`);
    }

    if (autoPlay) {
      await this.writeFrame(CMD_PLAY, []);
      this.setData({ status: '演奏中...' });
    } else {
      this.setData({ status: `已发送 ${events.length} 个事件，点“保存到琴”` });
    }
  },

  async playDemo() {
    if (!this.data.connected) return;
    try {
      this.setData({ status: '发送曲谱...' });
      await this.sendSong(this.demoEvents(), true, '小星星');
    } catch (err) {
      this.setData({ status: '发送失败: ' + (err.errMsg || err.message || err) });
    }
  },

  async stop() {
    if (!this.data.connected) return;
    try {
      await this.writeFrame(CMD_STOP, []);
      this.setData({ status: '已停止' });
    } catch (err) {
      this.setData({ status: '停止失败: ' + (err.errMsg || err) });
    }
  },

  async playStored() {
    if (!this.data.connected) return;
    try {
      await this.writeFrame(CMD_PLAY, []);
      this.setData({ status: '播放已存曲目...' });
    } catch (err) {
      this.setData({ status: '播放失败: ' + (err.errMsg || err) });
    }
  },

  onSlotChange(e) {
    const idx = Number(e.detail.value);
    this.setData({
      slot: idx,
      slotLabel: this.data.slots[idx] || String(idx + 1).padStart(2, '0')
    });
  },

  onRecordName(e) {
    this.setData({ recordName: e.detail.value });
  },

  async saveRecordName() {
    if (!this.data.connected) return;
    const name = (this.data.recordName || '录音').trim() || '录音';
    const slot = this.data.slot;
    try {
      const payload = [slot & 0xFF].concat(utf8Bytes(name, 16));
      await this.sendCommand(CMD_SAVE, payload, 3000);
      const names = Object.assign({}, this.data.slotNames);
      names[slot] = name;
      this.setData({ slotNames: names });
      try { wx.setStorageSync('slotNames', names); } catch (e) {}
      this.refreshSlots(this.data.slotMask | (1 << slot), this.data.slotCurrent);
      this.requestList();
    } catch (e) {
      this.setData({ status: '录音名保存失败: ' + (e.errMsg || e.message || e) });
    }
  },

  async toggleRecord() {
    if (!this.data.connected) return;
    const start = !this.data.recActive;
    const action = start ? 1 : 0;
    this.setData({ status: start ? '开始录音...' : '停止录音并保存...' });
    try {
      await this.sendCommand(CMD_REC, [action, this.data.slot & 0xFF], 1500);
      this.setData({
        recActive: start,
        recEvents: start ? 0 : this.data.recEvents,
        status: start ? '录音中，按 S3 或小程序按钮停止' : '录音已停止，正在保存...'
      });
      if (!start) {
        this.requestList();
        setTimeout(() => { this.saveRecordName(); }, 1800);
      }
    } catch (err) {
      this.setData({ status: '录音控制失败: ' + (err.errMsg || err.message || err) });
    }
  },

  async saveToFlash() {
    if (!this.data.connected) return;
    const slot = this.data.slot;
    const label = this.data.slotLabel;
    this.setData({ status: `保存到 ${label}（约 1 秒）...` });
    try {
      const payload = [slot & 0xFF].concat(utf8Bytes(this.currentSongName || '未命名', 16));
      await this.sendCommand(CMD_SAVE, payload, 3000);
      const names = Object.assign({}, this.data.slotNames);
      names[slot] = this.currentSongName || '未命名';
      this.setData({ slotNames: names });
      try { wx.setStorageSync('slotNames', names); } catch (e) {}
      this.setData({ status: `${label} 保存成功` });
      this.refreshSlots(this.data.slotMask, this.data.slotCurrent);      this.requestList();
    } catch (err) {
      this.setData({ status: '保存失败: ' + (err.errMsg || err.message || err) });
    }
  },

  async loadSlot() {
    if (!this.data.connected) return;
    const slot = this.data.slot;
    const label = this.data.slotLabel;
    this.setData({ status: `加载 ${label}...` });
    try {
      await this.sendCommand(CMD_LOAD, [slot & 0xFF], 2500);
      this.currentSongName = this.data.slotNames[slot] || '未命名';
      this.setData({ status: `已加载 ${label}，可以播放` });
      this.requestList();
    } catch (err) {
      this.setData({ status: '加载失败: ' + (err.errMsg || err.message || err) });
    }
  },

  async deleteSlot() {
    if (!this.data.connected) return;
    const slot = this.data.slot;
    const label = this.data.slotLabel;
    this.setData({ status: `删除 ${label}...` });
    try {
      await this.sendCommand(CMD_DELETE, [slot & 0xFF], 2500);
      const names = Object.assign({}, this.data.slotNames);
      delete names[slot];
      this.setData({ slotNames: names });
      try { wx.setStorageSync('slotNames', names); } catch (e) {}
      this.setData({ status: `${label} 已删除` });
      this.refreshSlots(this.data.slotMask & ~(1 << slot) & 0xFFFF, this.data.slotCurrent);
      this.requestList();
    } catch (err) {
      this.setData({ status: '删除失败: ' + (err.errMsg || err.message || err) });
    }
  },

  onUnload() {
    this.clearPending(new Error('页面关闭'));
    this.rejectNamePending(new Error('页面关闭'));
    this.stopStatusPoll();
    if (this.ble) wx.closeBLEConnection({ deviceId: this.ble.deviceId });
    wx.stopBluetoothDevicesDiscovery();
  }
});

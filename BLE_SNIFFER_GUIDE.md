# Hướng dẫn sử dụng BLE Sniffer để kiểm tra thiết bị BLE

## 📱 Công cụ BLE Sniffer phổ biến

### 1. **nRF Connect (Android/iOS)** ⭐ **KHUYẾN NGHỊ**
- **Link tải**: 
  - Android: [Google Play Store](https://play.google.com/store/apps/details?id=no.nordicsemi.android.mcp)
  - iOS: [App Store](https://apps.apple.com/app/nrf-connect/id1056142400)
- **Ưu điểm**: 
  - Miễn phí
  - Dễ sử dụng
  - Hiển thị tất cả BLE traffic
  - Log chi tiết
  - Có thể gửi/nhận data

### 2. **LightBlue (iOS)**
- **Link tải**: [App Store](https://apps.apple.com/app/lightblue/id557428110)
- **Ưu điểm**: 
  - Miễn phí
  - Giao diện đẹp
  - Hiển thị services/characteristics
  - Có thể gửi/nhận data

### 3. **BLE Scanner (Android)**
- **Link tải**: [Google Play Store](https://play.google.com/store/apps/details?id=com.macdom.ble.blescanner)
- **Ưu điểm**: 
  - Miễn phí
  - Hiển thị RSSI, services
  - Có thể connect và test

### 4. **Wireshark + BLE Dongle** (Chuyên nghiệp)
- **Link**: [Wireshark](https://www.wireshark.org/)
- **Yêu cầu**: BLE USB dongle (nRF52840, nRF51, etc.)
- **Ưu điểm**: 
  - Phân tích chi tiết nhất
  - Capture toàn bộ BLE traffic
  - Phân tích protocol

---

## 🔍 Hướng dẫn sử dụng nRF Connect (Khuyến nghị)

### **Bước 1: Tải và cài đặt**
1. Tải **nRF Connect** từ Google Play Store hoặc App Store
2. Mở app và cấp quyền Bluetooth

### **Bước 2: Scan thiết bị**
1. Nhấn nút **"Scan"** ở dưới màn hình
2. Tìm thiết bị **"AgriBeacon BLE"**
3. Nhấn vào thiết bị để xem chi tiết

### **Bước 3: Kết nối và xem Services**
1. Nhấn nút **"Connect"** trên thiết bị
2. Đợi kết nối thành công
3. Xem danh sách **Services** và **Characteristics**

### **Bước 4: Enable Notifications**
1. Tìm Service: `6e400001-b5a3-f393-e0a9-e50e24dcca9e` (Nordic UART)
2. Tìm Characteristic: `6e400003-b5a3-f393-e0a9-e50e24dcca9e` (RX - notify)
3. Nhấn vào characteristic
4. Nhấn nút **"Enable notifications"** (biểu tượng 3 dấu chấm → "Enable notifications")
5. Xem log để kiểm tra data nhận được

### **Bước 5: Gửi commands (nếu cần)**
1. Tìm Characteristic: `6e400002-b5a3-f393-e0a9-e50e24dcca9e` (TX - write)
2. Nhấn vào characteristic
3. Nhấn nút **"Write"**
4. Nhập command (ví dụ: `\n`, `START`, v.v.)
5. Chọn **"Text"** hoặc **"Byte Array"**
6. Nhấn **"Send"**

### **Bước 6: Xem Log**
1. Nhấn nút **"Log"** ở dưới màn hình
2. Xem tất cả BLE traffic:
   - Notifications nhận được
   - Data gửi đi
   - Timestamp
   - Hex/Text format

---

## 📊 Những gì cần kiểm tra

### **1. Thiết bị có gửi data tự động không?**
- Sau khi enable notifications, xem log có data tự động xuất hiện không
- Nếu có → Thiết bị tự động gửi data
- Nếu không → Thiết bị cần command để bắt đầu

### **2. Data format là gì?**
- Xem log để biết format:
  - Text: `HOME:123,456`
  - Hex: `48 4F 4D 45 3A 31 32 33`
  - Binary: `[72, 79, 77, 69, 58, 49, 50, 51]`

### **3. Thiết bị có response khi gửi command không?**
- Gửi command qua TX characteristic
- Xem RX characteristic có nhận được data không
- Nếu có → Thiết bị response
- Nếu không → Thiết bị không nhận diện command

### **4. Timing - Thiết bị gửi data khi nào?**
- Ngay sau khi kết nối?
- Sau khi enable notifications?
- Sau khi gửi command?
- Theo chu kỳ (mỗi X giây)?

---

## 🔧 Sử dụng nRF Connect - Chi tiết

### **Giao diện chính:**
```
┌─────────────────────────┐
│   nRF Connect           │
├─────────────────────────┤
│  [Scan]                 │
│                         │
│  AgriBeacon BLE         │
│  RSSI: -61              │
│  [Connect]              │
└─────────────────────────┘
```

### **Sau khi Connect:**
```
┌─────────────────────────┐
│   AgriBeacon BLE        │
├─────────────────────────┤
│  Services:              │
│  ├─ 1801                │
│  ├─ 1800                │
│  └─ 6e400001-...        │
│     ├─ 6e400002-... (TX)│
│     └─ 6e400003-... (RX)│
└─────────────────────────┘
```

### **Enable Notifications:**
1. Nhấn vào `6e400003-...` (RX characteristic)
2. Nhấn nút **"..."** (3 chấm)
3. Chọn **"Enable notifications"**
4. Icon sẽ đổi thành **"🔔"** (có notification)

### **Xem Log:**
```
┌─────────────────────────┐
│   Log                   │
├─────────────────────────┤
│  14:05:10.123           │
│  Notification received  │
│  6e400003-...           │
│  Data: 48 4F 4D 45      │
│  Text: "HOME"           │
└─────────────────────────┘
```

---

## 🎯 Checklist kiểm tra

### **Khi test với nRF Connect:**

- [ ] **Kết nối thành công** đến "AgriBeacon BLE"
- [ ] **Tìm thấy Service**: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- [ ] **Tìm thấy TX**: `6e400002-...` (write=true)
- [ ] **Tìm thấy RX**: `6e400003-...` (notify=true)
- [ ] **Enable notifications** trên RX characteristic
- [ ] **Xem log** để kiểm tra data nhận được
- [ ] **Gửi command** qua TX characteristic (nếu cần)
- [ ] **Kiểm tra response** trong log

### **Kết quả mong đợi:**

#### **Trường hợp 1: Thiết bị tự động gửi data**
```
Log:
14:05:10.123 - Notification received
Data: 48 4F 4D 45 3A 31 32 33
Text: "HOME:123"
```
→ **Kết luận**: Thiết bị tự động gửi data, code cần đợi lâu hơn

#### **Trường hợp 2: Thiết bị cần command**
```
Log:
14:05:10.123 - Write: "\n"
14:05:10.456 - Notification received
Data: 48 4F 4D 45 3A 31 32 33
Text: "HOME:123"
```
→ **Kết luận**: Thiết bị cần command, code cần gửi command đúng

#### **Trường hợp 3: Thiết bị không gửi data**
```
Log:
14:05:10.123 - Enable notifications
(No data received)
```
→ **Kết luận**: Thiết bị không gửi data hoặc firmware chưa sẵn sàng

---

## 💡 Tips

1. **Đợi lâu hơn**: Một số thiết bị gửi data theo chu kỳ (5-10 giây)
2. **Thử nhiều commands**: Gửi các command khác nhau để tìm command đúng
3. **Kiểm tra firmware**: Xem code firmware để biết cách thiết bị gửi data
4. **So sánh với app khác**: Nếu app khác nhận được data, so sánh cách họ làm

---

## 🔍 Phân tích kết quả

### **Nếu nRF Connect nhận được data:**
- ✅ Thiết bị hoạt động bình thường
- ✅ Code Flutter có vấn đề
- **Giải pháp**: So sánh cách nRF Connect làm với code Flutter

### **Nếu nRF Connect KHÔNG nhận được data:**
- ❌ Thiết bị không gửi data
- ❌ Firmware chưa sẵn sàng
- **Giải pháp**: Kiểm tra firmware hoặc thiết bị

---

## 📝 Ghi chú

- **nRF Connect** là công cụ tốt nhất để test BLE
- **Miễn phí** và dễ sử dụng
- **Log chi tiết** giúp debug
- **Có thể gửi/nhận data** để test

---

## 🚀 Bước tiếp theo

1. **Tải nRF Connect** và test thiết bị
2. **Ghi lại kết quả**: 
   - Thiết bị có gửi data tự động không?
   - Data format là gì?
   - Có cần command không?
3. **So sánh với code Flutter** để tìm vấn đề
4. **Báo cáo kết quả** để tiếp tục debug


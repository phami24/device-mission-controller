# BLE (Bluetooth Low Energy) - Thuật ngữ và Cách hoạt động

## 📚 Thuật ngữ BLE

### 1. **Device (Thiết bị)**
- **Định nghĩa**: Một thiết bị BLE có thể là **Peripheral** (thiết bị phát) hoặc **Central** (thiết bị nhận)
- **Ví dụ**: 
  - AgriBeacon BLE = Peripheral (gửi data)
  - Phone/App = Central (nhận data)

### 2. **Service (Dịch vụ)**
- **Định nghĩa**: Một nhóm các **Characteristic** liên quan đến nhau
- **UUID**: Mỗi service có UUID duy nhất
- **Ví dụ**: 
  - `6e400001-b5a3-f393-e0a9-e50e24dcca9e` = Nordic UART Service
  - `1800` = Generic Access Service (chuẩn BLE)
  - `1801` = Generic Attribute Service (chuẩn BLE)

### 3. **Characteristic (Đặc tính)**
- **Định nghĩa**: Đơn vị nhỏ nhất chứa dữ liệu trong BLE
- **UUID**: Mỗi characteristic có UUID duy nhấ
- **Vị trí**: Nằm trong một Service
- **Ví dụ trong log của bạn**:
  - `6e400002-b5a3-f393-e0a9-e50e24dcca9e` = TX Characteristic (gửi data TO device)
  - `6e400003-b5a3-f393-e0a9-e50e24dcca9e` = RX Characteristic (nhận data FROM device)

### 4. **UUID (Universally Unique Identifier)**
- **Định nghĩa**: Mã định danh duy nhất cho Service và Characteristic
- **Loại**:
  - **16-bit UUID**: Chuẩn BLE (ví dụ: `1800`, `2a00`)
  - **128-bit UUID**: Custom UUID (ví dụ: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`)

### 5. **Properties (Thuộc tính)**
Mỗi Characteristic có các thuộc tính sau:

#### a. **Read (Đọc)**
- **Định nghĩa**: Cho phép đọc giá trị từ characteristic
- **Cách dùng**: `characteristic.read()` → trả về `List<int>`
- **Khi nào dùng**: Khi muốn lấy data theo yêu cầu (polling)

#### b. **Write (Ghi)**
- **Định nghĩa**: Cho phép ghi dữ liệu vào characteristic
- **Cách dùng**: `characteristic.write(data)`
- **Khi nào dùng**: Gửi command, lệnh đến thiết bị

#### c. **Notify (Thông báo)**
- **Định nghĩa**: Thiết bị tự động gửi data khi có thay đổi
- **Cách dùng**: 
  1. `characteristic.setNotifyValue(true)` → bật notify
  2. `characteristic.onValueReceived.listen(...)` → lắng nghe data
- **Khi nào dùng**: Nhận data tự động (push mode)
- **Lưu ý**: Phải bật notify TRƯỚC khi thiết bị gửi data

#### d. **Indicate (Chỉ báo)**
- **Định nghĩa**: Giống Notify nhưng thiết bị đợi xác nhận từ app
- **Khi nào dùng**: Khi cần đảm bảo data được nhận (nhưng ít dùng hơn Notify)

### 6. **GATT (Generic Attribute Profile)**
- **Định nghĩa**: Giao thức định nghĩa cách dữ liệu được truyền trong BLE
- **Cấu trúc**: Device → Service → Characteristic
- **Ví dụ**:
  ```
  AgriBeacon BLE (Device)
    └── Nordic UART Service (6e400001-...)
        ├── TX Characteristic (6e400002-...) [write]
        └── RX Characteristic (6e400003-...) [read, notify]
  ```

### 7. **MTU (Maximum Transmission Unit)**
- **Định nghĩa**: Kích thước tối đa của một gói dữ liệu
- **Mặc định**: 23 bytes
- **Tăng lên**: 512 bytes (như trong code của bạn) để gửi nhiều data hơn

### 8. **RSSI (Received Signal Strength Indicator)**
- **Định nghĩa**: Cường độ tín hiệu (dBm)
- **Ý nghĩa**: 
  - `-60` đến `-70`: Gần, tín hiệu tốt
  - `-80` đến `-90`: Xa, tín hiệu yếu
  - `-100`: Rất xa, có thể mất kết nối

---

## 🔄 Cách hoạt động của BLE trong code của bạn

### **Bước 1: Scan (Quét thiết bị)**
```dart
FlutterBluePlus.startScan(timeout: Duration(seconds: 20))
```
- Tìm thiết bị có tên "AgriBeacon BLE"
- Log: `[BLE] Found device: Name: AgriBeacon BLE, RSSI: -61`

### **Bước 2: Connect (Kết nối)**
```dart
await device.connect(timeout: Duration(seconds: 30), mtu: 512)
```
- Kết nối đến thiết bị
- Đợi trạng thái `connected`
- Log: `[BLE] ✓ Connection established!`

### **Bước 3: Discover Services (Khám phá dịch vụ)**
```dart
List<BluetoothService> services = await device.discoverServices()
```
- Tìm tất cả services và characteristics
- Log: `[BLE] Found 3 services`

### **Bước 4: Chọn Characteristic**
- Tìm characteristic có `notify: true` → RX Characteristic
- Tìm characteristic có `write: true` → TX Characteristic
- Log: `[BLE] Found characteristic with notify: 6e400003-...`

### **Bước 5: Bật Notify**
```dart
await characteristic.setNotifyValue(true)
await characteristic.onValueReceived.listen((data) { ... })
```
- Bật notify để nhận data tự động
- Setup listener để xử lý data khi nhận được
- Log: `[BLE] ✓ Notify should now be fully enabled`

### **Bước 6: Nhận Data**
- **Notify mode**: Thiết bị tự động gửi → `onValueReceived` được gọi
- **Polling mode**: Đọc định kỳ bằng `characteristic.read()` mỗi 500ms

---

## ⚠️ Vấn đề hiện tại: Không nhận được data

### **Từ log của bạn:**
```
[BLE] ✓ Notify should now be fully enabled
[BLE] ✓ onValueReceived listener is now active
[BLE] Received data: 0 bytes  ← VẤN ĐỀ
```

### **Nguyên nhân có thể:**

1. **Thiết bị chưa gửi data**
   - Thiết bị có thể cần command để bắt đầu gửi
   - Thiết bị có thể chưa sẵn sàng (cần thời gian khởi động)

2. **Thiết bị cần được "đánh thức"**
   - Một số thiết bị cần gửi command để bắt đầu gửi data
   - Ví dụ: Gửi `"START"` hoặc `"\n"` đến TX characteristic

3. **Thiết bị gửi data quá sớm**
   - Thiết bị gửi data ngay khi kết nối
   - Nhưng notify chưa bật xong → mất data đầu tiên

### **Giải pháp:**

1. **Thử gửi command để bắt đầu:**
   ```dart
   await bleService.writeString("\n");  // Hoặc command khác
   ```

2. **Tăng delay sau khi bật notify:**
   - Đã có delay 500ms, có thể cần tăng lên 1000ms

3. **Kiểm tra firmware:**
   - Xem firmware có tự động gửi data không
   - Xem firmware có cần command để bắt đầu không

---

## 📊 Cấu trúc BLE trong thiết bị của bạn

```
AgriBeacon BLE
├── Service: 1801 (Generic Attribute Service)
│   └── Characteristic: 2a05 (Service Changed) [indicate]
├── Service: 1800 (Generic Access Service)
│   ├── Characteristic: 2a00 (Device Name) [read]
│   ├── Characteristic: 2a01 (Appearance) [read]
│   └── Characteristic: 2aa6 (Central Address Resolution) [read]
└── Service: 6e400001-b5a3-f393-e0a9-e50e24dcca9e (Nordic UART)
    ├── Characteristic: 6e400002-... (TX) [write] ← GỬI DATA TO DEVICE
    └── Characteristic: 6e400003-... (RX) [read, notify] ← NHẬN DATA FROM DEVICE
```

---

## 🎯 Tóm tắt

- **BLE** = Bluetooth Low Energy (tiết kiệm pin)
- **Service** = Nhóm các characteristic
- **Characteristic** = Đơn vị chứa data
- **UUID** = Mã định danh duy nhất
- **Notify** = Nhận data tự động (push)
- **Read** = Đọc data theo yêu cầu (pull/poll)
- **Write** = Gửi data đến thiết bị

---

## 🔍 Kiểm tra code của bạn

✅ **Đúng:**
- UUID đúng: `6e400003-b5a3-f393-e0a9-e50e24dcca9e`
- Notify đã bật
- Listener đã setup
- Delay 500ms sau khi bật notify

❓ **Cần kiểm tra:**
- Thiết bị có cần command để bắt đầu gửi data không?
- Thiết bị có tự động gửi data không?
- Có cần gửi command đến TX characteristic không?

---

## 💡 Gợi ý tiếp theo

1. **Thử gửi command:** Gửi `"\n"` hoặc `"START"` đến TX characteristic
2. **Kiểm tra firmware:** Xem code firmware có tự động gửi data không
3. **Tăng delay:** Tăng delay sau khi bật notify lên 1000ms
4. **Kiểm tra polling:** Polling đang chạy nhưng chỉ nhận được 0 bytes


import 'dart:async';
import 'dart:core';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'event_bus.dart';

// ============================================================================
// BLE Event Handler - Simple event handler with on() and emit() methods
// ============================================================================
class BleEventHandler {
  final Map<String, Function> _callbacks = {};

  /// Register a callback for an event type
  /// Example: bleHandler.on("HOME", (data) => print(data));
  void on(String eventType, Function callback) {
    _callbacks[eventType] = callback;
  }

  /// Emit an event with data
  /// Example: bleHandler.emit("HOME", "133278830,108547396");
  void emit(String eventType, String data) {
    final callback = _callbacks[eventType];
    if (callback != null) {
      callback(data);
    }
  }

}

// ============================================================================
// BLE Message Parser - Parses incoming messages from BLE device
// ============================================================================
class BleMessageParser {
  final String prefix;

  BleMessageParser({this.prefix = ':'});

  /// Parse a raw message string and return event type and data
  /// Format: "EVENT_TYPE:data"
  /// Example: "HOME:133278830,108547396" -> {"event": "HOME", "data": "133278830,108547396"}
  Map<String, String>? parse(String message) {
    if (message.isEmpty) return null;

    final index = message.indexOf(prefix);
    if (index == -1) return null;

    final eventType = message.substring(0, index).trim();
    final data = message.substring(index + 1).trim();

    if (eventType.isEmpty) return null;

    return {'event': eventType, 'data': data};
  }

}

// ============================================================================
// BLE Service - Main BLE connection and communication service
// ============================================================================

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  // Nordic UART Service UUIDs (from firmware)
  // NOTE: Firmware defines RX/TX but actual BLE properties are reversed:
  // - 6e400002 has write=true → Use to SEND data TO device (TX in BLE terms)
  // - 6e400003 has notify=true → Use to RECEIVE data FROM device (RX in BLE terms)
  static const String nordicServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String nordicRxUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // Receive FROM device (notify=true)
  static const String nordicTxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // Transmit TO device (write=true)

  BluetoothDevice? _connectedDevice;
  BluetoothDevice? _currentDeviceForListener; // Lưu device reference cho listener
  BluetoothCharacteristic? _characteristic;
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<List<int>>? _valueSubscription;
  final List<StreamSubscription<List<int>>> _extraNotifySubscriptions = [];
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  String? _lastDeviceName; // Lưu tên device để reconnect
  String? _lastDeviceId; // Lưu device ID để reconnect trực tiếp (không cần scan)
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSettingUp = false; // Flag để tránh duplicate setup
  String? _deviceName;
  
  // Streams for connection status
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;
  
  // Event Bus for messages (backward compatibility)
  final EventBus _eventBus = EventBus();
  
  // New event handler (clean pattern like nt.txt)
  final BleEventHandler _eventHandler = BleEventHandler();
  final BleMessageParser _messageParser = BleMessageParser(prefix: ':');
  
  // Public streams - access via EventBus (backward compatibility)
  Stream<BleHomeEvent> get homeMessages => _eventBus.onHome;
  Stream<BleWpEvent> get wpMessages => _eventBus.onWp;
  Stream<BleStatusEvent> get statusMessages => _eventBus.onStatus;
  
  // New event handler access (clean API)
  BleEventHandler get on => _eventHandler;
  
  bool _isListening = false;
  final StringBuffer _messageBuffer = StringBuffer();
  
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  bool get isListening => _isListening;
  String? get deviceName => _deviceName;
  BluetoothDevice? get connectedDevice => _connectedDevice;

  /// Enable CCCD (Client Characteristic Configuration Descriptor) manually
  /// Some Android stacks require explicitly writing 0x2902 descriptor values.
  Future<void> _writeCccdForCharacteristic(BluetoothCharacteristic ch) async {
    try {
      // Find CCCD descriptor (0x2902)
      final descriptors = ch.descriptors;
      BluetoothDescriptor? cccd;
      for (final d in descriptors) {
        final id = d.uuid.toString().toLowerCase();
        if (id.endsWith('2902') || id == '2902') {
          cccd = d;
          break;
        }
      }
      if (cccd == null) {
        return;
      }
      // Determine value for notify/indicate
      final List<int> value = ch.properties.indicate
          ? <int>[0x02, 0x00] // Indications enabled
          : <int>[0x01, 0x00] // Notifications enabled
          ;
      await cccd.write(value);
    } catch (e) {
      // Ignore CCCD write errors
    }
  }

  /// Reconnect trực tiếp bằng device ID (không cần scan - nhanh hơn)
  Future<bool> _reconnectDirectly({int scanDurationSeconds = 10}) async {
    // Kiểm tra kỹ hơn: nếu đã connected hoặc đang connecting/setting up, không reconnect
    if (_lastDeviceId == null || _isConnecting || _isConnected || _isSettingUp) {
      return _isConnected;
    }

    try {
      print('[BLE] 🔄 QUICK RECONNECT: Kết nối trực tiếp bằng device ID...');

      _isConnecting = true;

      // Check Bluetooth adapter
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Bluetooth adapter is not on');
      }

      // Tìm device bằng ID - scan với thời gian dài hơn để đảm bảo tìm thấy
      // Stop any ongoing scan first
      try {
        await FlutterBluePlus.stopScan();
      } catch (e) {
        // Ignore
      }
      
      await FlutterBluePlus.startScan(timeout: Duration(seconds: scanDurationSeconds));
      
      BluetoothDevice? foundDevice;
      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (var result in results) {
          if (result.device.remoteId.toString() == _lastDeviceId) {
            foundDevice = result.device;
            break;
          }
        }
      });

      // Đợi tối đa scanDurationSeconds giây hoặc khi tìm thấy device
      final stopwatch = Stopwatch()..start();
      while (foundDevice == null && stopwatch.elapsedMilliseconds < scanDurationSeconds * 1000) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      
      await subscription.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (e) {
        // Ignore
      }
      
      final device = foundDevice;

      if (device == null) {
        throw Exception('Device not found in scan');
      }

      // Disconnect nếu đang connected
      try {
        final state = await device.connectionState.first;
        if (state == BluetoothConnectionState.connected) {
          await device.disconnect();
          await device.connectionState
              .where((s) => s == BluetoothConnectionState.disconnected)
              .first
              .timeout(const Duration(seconds: 5));
        }
      } catch (e) {
        // Ignore
      }

      // Connect trực tiếp
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: true,
        mtu: 512,
      );

      await device.connectionState
          .where((state) => state == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 10));

      print('[BLE] ✓ Reconnect thành công!');

      // Tiếp tục setup như connectToDevice (discover services, setup characteristics, etc.)
      // Gọi lại phần setup từ connectToDevice
      await _setupDeviceAfterConnection(device);

      return true;
    } catch (e) {
      _isConnecting = false;
      return false;
    }
  }

  /// Setup device sau khi connect (discover services, setup characteristics, etc.)
  Future<void> _setupDeviceAfterConnection(BluetoothDevice device) async {
    // Tránh duplicate setup: nếu đang setup hoặc đã connected và có characteristic, skip
    if (_isSettingUp || (_isConnected && _characteristic != null)) {
      return;
    }
    
    _isSettingUp = true;
    try {
      // Request MTU
      try {
        await device.requestMtu(517);
      } catch (e) {
        // Ignore MTU errors
      }

      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      
      // Verify Nordic UART service
      final hasNordicService = services.any((s) => s.uuid.toString().toLowerCase() == nordicServiceUuid);
      if (!hasNordicService) {
        throw Exception('Missing Nordic UART service');
      }

      // Find characteristics
      BluetoothCharacteristic? characteristic;
      BluetoothCharacteristic? writeCharacteristic;
      
      for (var service in services) {
        for (var char in service.characteristics) {
          final charUuid = char.uuid.toString().toLowerCase();
          if (charUuid == nordicRxUuid.toLowerCase()) {
            characteristic = char;
          }
          if (charUuid == nordicTxUuid.toLowerCase()) {
            writeCharacteristic = char;
          }
        }
      }

      if (characteristic == null || writeCharacteristic == null) {
        throw Exception('Missing required characteristics');
      }

      _connectedDevice = device;
      _characteristic = characteristic;
      _writeCharacteristic = writeCharacteristic;
      _deviceName = device.platformName.isNotEmpty 
          ? device.platformName 
          : device.advName.isNotEmpty 
              ? device.advName 
              : 'Unknown Device';
      _isConnected = true;
      _isConnecting = false;
      _currentDeviceForListener = device; // Update device reference cho listener

      _connectionStatusController.add(true);

      // Start listening
      if (characteristic.properties.notify || characteristic.properties.indicate) {
        await startListening();
      }

      // Setup connection state listener
      _lastDeviceName = _deviceName;
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          print('[BLE] ⚠️ DISCONNECTED: Bluetooth connection lost!');
          _handleDisconnection();
        } else if (state == BluetoothConnectionState.connected) {
          // Hủy reconnect timer ngay lập tức
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
        }
      });
    } catch (e) {
      _isSettingUp = false;
      rethrow;
    } finally {
      _isSettingUp = false;
    }
  }

  /// Handle disconnection
  void _handleDisconnection() {
    for (final s in _extraNotifySubscriptions) {
      s.cancel();
    }
    _extraNotifySubscriptions.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _isConnected = false;
    _isSettingUp = false; // Reset setup flag khi disconnect
    _deviceName = null;
    _connectedDevice = null;
    _characteristic = null;
    _isListening = false;
    _messageBuffer.clear();
    _connectionStatusController.add(false);

    // Auto-reconnect với retry logic
    if (_lastDeviceId != null && !_isConnecting) {
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 2), () {
        _attemptReconnectWithRetry();
      });
    }
  }

  /// Attempt reconnect với retry logic (tăng dần thời gian scan)
  void _attemptReconnectWithRetry({int attempt = 1, int maxAttempts = 3}) async {
    // Kiểm tra kỹ hơn: nếu đã connected, đang connecting, hoặc đang setting up, không reconnect
    if (_isConnected || _isConnecting || _isSettingUp || _lastDeviceId == null) {
      return;
    }

    try {
      // Tăng thời gian scan mỗi lần retry: 10s, 15s, 20s
      final scanDuration = 10 + (attempt - 1) * 5;
      print('[BLE] 🔄 Auto-reconnect attempt $attempt/$maxAttempts (scan: ${scanDuration}s)');
      
      final success = await _reconnectDirectly(scanDurationSeconds: scanDuration);
      if (success) {
        print('[BLE] ✓ Auto-reconnect thành công!');
        return;
      } else {
        throw Exception('Reconnect returned false');
      }
    } catch (e) {
      // Retry với thời gian scan dài hơn
      if (attempt < maxAttempts) {
        final nextAttempt = attempt + 1;
        final delaySeconds = 2 * attempt; // Exponential backoff: 2s, 4s, 6s
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
          _attemptReconnectWithRetry(attempt: nextAttempt, maxAttempts: maxAttempts);
        });
      } else {
        // Sau maxAttempts, fallback về scan by name
        print('[BLE] ⚠️ Quick reconnect failed, falling back to scan by name...');
        if (_lastDeviceName != null && !_isConnecting) {
          try {
            await connectToDevice(_lastDeviceName!);
            print('[BLE] ✓ Fallback reconnect by name thành công!');
          } catch (e) {
            // Sẽ thử lại lần sau khi detect disconnect
          }
        }
      }
    }
  }

  /// Connect to a BLE device by name
  Future<bool> connectToDevice(String deviceName, {int maxRetries = 3}) async {
    if (_isConnecting || _isConnected) {
      return _isConnected;
    }

    int retryCount = 0;
    Exception? lastException;
    bool isScanning = false;

    while (retryCount < maxRetries) {
      try {
        _isConnecting = true;
        
        // Check if Bluetooth is available
        if (await FlutterBluePlus.isSupported == false) {
          throw Exception('Bluetooth không được hỗ trợ trên thiết bị này');
        }

        // Turn on Bluetooth if it's off
        final adapterState = await FlutterBluePlus.adapterState.first;
        if (adapterState == BluetoothAdapterState.off) {
          await FlutterBluePlus.turnOn();
          // Wait for adapter to turn on (with timeout)
          await FlutterBluePlus.adapterState
              .where((state) => state == BluetoothAdapterState.on)
              .first
              .timeout(const Duration(seconds: 10));
        } else if (adapterState != BluetoothAdapterState.on) {
          // Wait for adapter to be on
          await FlutterBluePlus.adapterState
              .where((state) => state == BluetoothAdapterState.on)
              .first
              .timeout(const Duration(seconds: 10));
        }

        // Stop any ongoing scan first (only if we're not already scanning)
        if (!isScanning) {
          try {
            await FlutterBluePlus.stopScan();
          } catch (e) {
            // Ignore if scan is not running - this is normal
          }
        }

        // Start scanning for the device
        isScanning = true;
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 20),
          androidUsesFineLocation: true,
        );
        
        BluetoothDevice? foundDevice;
        
        // Listen for scan results
        final subscription = FlutterBluePlus.scanResults.listen((results) {
          for (var result in results) {
            final platformName = result.device.platformName;
            final advName = result.device.advName;
            
            // Check both platformName and advName (case insensitive) - ONLY exact match
            final name1 = platformName.toLowerCase();
            final name2 = advName.toLowerCase();
            final searchName = deviceName.toLowerCase();
            
            // Strict: accept ONLY exact match on advertised or platform name
            if (name1 == searchName || name2 == searchName) {
              foundDevice = result.device;
            }
          }
        });

        // Wait for device to be found (with timeout)
        final stopwatch = Stopwatch()..start();
        while (foundDevice == null && stopwatch.elapsedMilliseconds < 20000) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        
        await subscription.cancel();
        isScanning = false;
        
        // Stop scan - only if we started it
        try {
          await FlutterBluePlus.stopScan();
        } catch (e) {
          // Ignore stop scan errors - already stopped is normal
        }

        if (foundDevice == null) {
          throw Exception('Không tìm thấy thiết bị "$deviceName".\n'
              'Vui lòng kiểm tra:\n'
              '- Thiết bị BLE đã bật và ở gần\n'
              '- Tên thiết bị chính xác: "AgriBeacon BLE"\n'
              '- Thử tắt/bật Bluetooth');
        }

        // Disconnect device first if it was previously connected (clean state)
        try {
          final connectionState = await foundDevice!.connectionState.first;
          if (connectionState == BluetoothConnectionState.connected) {
            await foundDevice!.disconnect();
            await foundDevice!.connectionState
                .where((state) => state == BluetoothConnectionState.disconnected)
                .first
                .timeout(const Duration(seconds: 5));
          }
        } catch (e) {
          // Try to disconnect anyway
          try {
            await foundDevice!.disconnect();
          } catch (e2) {
            // Ignore
          }
        }

        // Connect to the device with retry
        try {
          // Try with autoConnect first (more reliable on Android)
          await foundDevice!.connect(
            timeout: const Duration(seconds: 30),
            autoConnect: true,
            mtu: 512,
          );
        } on fbp.FlutterBluePlusException catch (e) {
          final errorString = e.toString();
          // Check for error code 133 (GATT_ERROR) or ANDROID_SPECIFIC_ERROR
          if (errorString.contains('133') || 
              errorString.contains('ANDROID_SPECIFIC_ERROR') ||
              errorString.contains('ANDROID_SPECIFIC_ERRROR')) {
            // GATT_ERROR - retry with delay
            if (retryCount < maxRetries - 1) {
              retryCount++;
              // Wait longer before retry (exponential backoff)
              int delayMs = 2000 * retryCount;
              await Future.delayed(Duration(milliseconds: delayMs));
              // Disconnect before retry
              try {
                if (foundDevice!.isConnected) {
                  await foundDevice!.disconnect();
                }
              } catch (e) {
                // Ignore
              }
              continue;
            }
            throw Exception('Lỗi kết nối BLE (133): Không thể kết nối sau $maxRetries lần thử. Vui lòng:\n'
                '- Kiểm tra thiết bị BLE đã bật và ở gần\n'
                '- Kiểm tra quyền Bluetooth trong Settings\n'
                '- Thử tắt/bật Bluetooth');
          }
          rethrow;
        }

        // Wait for connection to be established
        try {
          await foundDevice!.connectionState
              .where((state) => state == BluetoothConnectionState.connected)
              .first
              .timeout(const Duration(seconds: 10));
          print('[BLE] ✓ Connected to device: ${foundDevice!.platformName.isNotEmpty ? foundDevice!.platformName : foundDevice!.advName}');
        } catch (e) {
          // Check current state
          final currentState = await foundDevice!.connectionState.first;
          if (currentState != BluetoothConnectionState.connected) {
            throw Exception('Connection timeout: device state is $currentState');
          }
        }
        
        // Explicitly request high MTU (Android only). iOS ignores/auto-negotiates.
        try {
          await foundDevice!.requestMtu(517);
        } catch (e) {
          // Ignore MTU errors
        }

        // Discover services
        List<BluetoothService> services = await foundDevice!.discoverServices();
        
        // Verify Nordic UART service exists; otherwise: disconnect and retry
        final hasNordicService = services.any((s) => s.uuid.toString().toLowerCase() == nordicServiceUuid);
        if (!hasNordicService) {
          try {
            await foundDevice!.disconnect();
          } catch (_) {}
          throw Exception('Wrong device connected: missing Nordic UART service');
        }
        
        // Find characteristics using exact UUIDs from firmware
        BluetoothCharacteristic? characteristic; // For receiving data (notify)
        BluetoothCharacteristic? writeCharacteristic; // For sending data (write)
        
        // Find RX characteristic (6e400003) - for receiving data FROM device (has notify=true)
        for (var service in services) {
          for (var char in service.characteristics) {
            final charUuid = char.uuid.toString().toLowerCase();
            if (charUuid == nordicRxUuid.toLowerCase()) {
              characteristic = char;
              break;
            }
          }
          if (characteristic != null) break;
        }
        
        // Find TX characteristic (6e400002) - for sending data TO device (has write=true)
        for (var service in services) {
          for (var char in service.characteristics) {
            final charUuid = char.uuid.toString().toLowerCase();
            if (charUuid == nordicTxUuid.toLowerCase()) {
              writeCharacteristic = char;
              break;
            }
          }
          if (writeCharacteristic != null) break;
        }
        
        // Fallback: If exact UUIDs not found, try to find by properties
        if (characteristic == null) {
          for (var service in services) {
            for (var char in service.characteristics) {
              if (char.properties.notify) {
                characteristic = char;
                break;
              }
            }
            if (characteristic != null) break;
          }
        }
        
        if (writeCharacteristic == null) {
          for (var service in services) {
            for (var char in service.characteristics) {
              if (char.properties.write) {
                writeCharacteristic = char;
                break;
              }
            }
            if (writeCharacteristic != null) break;
          }
        }

        _connectedDevice = foundDevice;
        _characteristic = characteristic;
        _writeCharacteristic = writeCharacteristic;
        _deviceName = foundDevice!.platformName.isNotEmpty 
            ? foundDevice!.platformName 
            : foundDevice!.advName.isNotEmpty 
                ? foundDevice!.advName 
                : 'Unknown Device';
        // Lưu device ID để reconnect trực tiếp (không cần scan)
        _lastDeviceId = foundDevice!.remoteId.toString();
        _lastDeviceName = _deviceName;
        _isConnected = true;
        _isConnecting = false;
        
        print('[BLE] ✓ Connected to device: $_deviceName');
        _connectionStatusController.add(true);

        // Start listening for messages if characteristic supports notify/indicate
        if (characteristic != null && (characteristic.properties.notify || characteristic.properties.indicate)) {
          try {
            await startListening();
          } catch (e) {
            // Ignore listening errors
          }
        } else if (characteristic != null && characteristic.properties.read) {
          // Try reading immediately
          try {
            final data = await characteristic.read();
            if (data.isNotEmpty) {
              _processMessage(data);
            }
          } catch (e) {
            // Ignore read errors
          }
          
          // Start polling for data every 500ms
          _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
            if (_characteristic == null || !_isConnected) {
              timer.cancel();
              return;
            }
            
            try {
              final data = await _characteristic!.read();
              if (data.isNotEmpty) {
                _processMessage(data);
              }
            } catch (e) {
              // Don't cancel timer on error, just continue
            }
          });
        }

        // Listen for disconnection and auto-reconnect
        _lastDeviceName = _deviceName; // Lưu tên device để reconnect
        _currentDeviceForListener = foundDevice; // Lưu device reference cho listener
        _connectionStateSubscription?.cancel(); // Cancel subscription cũ nếu có
        
        _connectionStateSubscription = foundDevice!.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            print('[BLE] ⚠️ DISCONNECTED: Bluetooth connection lost!');
            
            // Stop extra notify subscriptions
            for (final s in _extraNotifySubscriptions) {
              s.cancel();
            }
            _extraNotifySubscriptions.clear();
            _pollTimer?.cancel();
            _pollTimer = null;
            _isConnected = false;
            _deviceName = null;
            _connectedDevice = null;
            _characteristic = null;
            _isListening = false;
            _messageBuffer.clear();
            _connectionStatusController.add(false);
            
            // Tự động reconnect sau 2 giây
            _handleDisconnection();
          } else if (state == BluetoothConnectionState.connected) {
            // Hủy reconnect timer ngay lập tức khi detect connected
            _reconnectTimer?.cancel();
            _reconnectTimer = null;
            
            // Nếu device tự động reconnect (autoConnect) nhưng chưa setup, cần setup lại
            if (_currentDeviceForListener != null && (!_isConnected || _characteristic == null) && !_isSettingUp) {
              _setupDeviceAfterConnection(_currentDeviceForListener!).catchError((e) {
                // Ignore setup errors
              });
            }
          }
        });

        return true;
      } on fbp.FlutterBluePlusException catch (e) {
        final errorString = e.toString();
        lastException = Exception('Lỗi BLE: $errorString');
        
        // Retry on connection errors (133, permission errors, etc.)
        if (errorString.contains('133') || 
            errorString.contains('ANDROID_SPECIFIC_ERROR') ||
            errorString.contains('ANDROID_SPECIFIC_ERRROR')) {
          if (retryCount < maxRetries - 1) {
            retryCount++;
            int delayMs = 2000 * retryCount;
            await Future.delayed(Duration(milliseconds: delayMs));
            continue;
          }
        }
        // Don't retry on permission errors - just throw
        if (errorString.contains('permission') || errorString.contains('Permission')) {
          throw Exception('Lỗi quyền Bluetooth: Vui lòng cấp quyền Bluetooth và Location trong Settings');
        }
        break;
      } catch (e) {
        lastException = e is Exception ? e : Exception(e.toString());
        if (retryCount < maxRetries - 1) {
          retryCount++;
          await Future.delayed(Duration(milliseconds: 1000 * retryCount));
          continue;
        }
        break;
      }
    }

    _isConnecting = false;
    _connectionStatusController.add(false);
    
    if (lastException != null) {
      throw lastException;
    }
    
    throw Exception('Không thể kết nối đến thiết bị "$deviceName" sau $maxRetries lần thử');
  }

  /// Disconnect from the current device
  Future<void> disconnect() async {
    try {
      // Hủy auto-reconnect khi disconnect thủ công
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _lastDeviceName = null; // Không reconnect khi disconnect thủ công
      _lastDeviceId = null; // Xóa device ID để không reconnect
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      
      // Stop extra notify subscriptions
      for (final s in _extraNotifySubscriptions) {
        await s.cancel();
      }
      _extraNotifySubscriptions.clear();
      
      // Stop polling timer
      _pollTimer?.cancel();
      _pollTimer = null;
      
      if (_connectedDevice != null) {
        await _valueSubscription?.cancel();
        await _connectedDevice!.disconnect();
      }
      _isConnected = false;
      _deviceName = null;
      _connectedDevice = null;
      _characteristic = null;
      _writeCharacteristic = null;
      _connectionStatusController.add(false);
      
      print('[BLE] Disconnected manually');
    } catch (e) {
      // Ignore disconnect errors
    }
  }

  /// Write data to the connected device
  Future<void> writeData(List<int> data) async {
    if (!_isConnected || _writeCharacteristic == null) {
      throw Exception('Không có kết nối BLE hoặc không có write characteristic');
    }

    final ch = _writeCharacteristic!;
    final supportsWriteNoResp = ch.properties.writeWithoutResponse;

    if (ch.properties.write || supportsWriteNoResp) {
      await ch.write(data, withoutResponse: supportsWriteNoResp);
    } else {
      throw Exception('Characteristic không hỗ trợ ghi dữ liệu');
    }
  }
  
  /// Write string to the connected device
  Future<void> writeString(String message) async {
    final data = utf8.encode(message);
    await writeData(data);
  }

  /// Start listening for messages from BLE device
  Future<void> startListening() async {
    if (_characteristic == null || !_isConnected) {
      return;
    }

    if (_isListening) {
      return;
    }

    if (!_characteristic!.properties.notify && !_characteristic!.properties.indicate) {
      throw Exception('Characteristic không hỗ trợ thông báo (notify/indicate)');
    }

    try {
      // Enable notify or indicate
      if (_characteristic!.properties.notify) {
        await _characteristic!.setNotifyValue(true);
        await _writeCccdForCharacteristic(_characteristic!);
      } else if (_characteristic!.properties.indicate) {
        await _characteristic!.setNotifyValue(true); // Same API for indicate
        await _writeCccdForCharacteristic(_characteristic!);
      }
      
      _isListening = true;
      
      // Listen for incoming data
      _valueSubscription = _characteristic!.onValueReceived.listen((data) {
        if (data.isNotEmpty) {
          _processMessage(data);
        }
      }, onError: (error) {
        // Ignore stream errors
      }, onDone: () {
        _isListening = false;
      });
    } catch (e) {
      _isListening = false;
      throw Exception('Lỗi khi bắt đầu lắng nghe: $e');
    }
  }

  /// Stop listening for messages
  void stopListening() {
    if (_isListening) {
      _valueSubscription?.cancel();
      _isListening = false;
      _messageBuffer.clear();
    }
  }

  /// Process incoming message data
  void _processMessage(List<int> data) {
    // Try UTF-8 decode first
    try {
      String message = utf8.decode(data);
      
      // Append to buffer (handle fragmented packets)
      _messageBuffer.write(message);
      final bufferStr = _messageBuffer.toString();

      // Only process complete lines (terminated by \n)
      final lastNewline = bufferStr.lastIndexOf('\n');
      if (lastNewline == -1) {
        return;
      }

      // Separate complete part and remainder
      final completePart = bufferStr.substring(0, lastNewline);
      final remainder = bufferStr.substring(lastNewline + 1);
      _messageBuffer
        ..clear()
        ..write(remainder);

      // Process each complete line
      final lines = completePart.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        
        _parseAndRouteMessage(trimmed);
      }
    } catch (e) {
      // Try to decode as ASCII if UTF-8 fails
      try {
        String message = String.fromCharCodes(data);
        _messageBuffer.write(message);
        final bufferStr = _messageBuffer.toString();
        final lastNewline = bufferStr.lastIndexOf('\n');
        if (lastNewline == -1) return;
        
        final completePart = bufferStr.substring(0, lastNewline);
        final remainder = bufferStr.substring(lastNewline + 1);
        _messageBuffer
          ..clear()
          ..write(remainder);
        
        final lines = completePart.split('\n');
        for (final line in lines) {
          final l = line.trim();
          if (l.isEmpty) continue;
          _parseAndRouteMessage(l);
        }
      } catch (e2) {
        // Ignore decode errors
      }
    }
  }

  /// Parse message and route to appropriate handler (using new parser)
  void _parseAndRouteMessage(String message) {    
    // Use message parser to extract event type and data
    final parsed = _messageParser.parse(message);
    if (parsed == null) return;
    
    final eventType = parsed['event']!;
    final data = parsed['data']!;
    
    // Emit to new event handler (clean pattern)
    _eventHandler.emit(eventType, data);
    
    // Also emit to EventBus for backward compatibility
    switch (eventType.toUpperCase()) {
      case 'HOME':
        _eventBus.emitHome(data);
        break;
      case 'WP':
        _eventBus.emitWp(data);
        break;
      case 'STATUS':
        _eventBus.emitStatus(data);
        break;
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    stopListening();
    _valueSubscription?.cancel();
    _connectionStatusController.close();
  }
}


import 'dart:async';
import 'dart:core';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'event_bus.dart';

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
  
  // Event Bus for messages
  final EventBus _eventBus = EventBus();
  
  // Public streams - access via EventBus
  Stream<BleHomeEvent> get homeMessages => _eventBus.onHome;
  Stream<BleWpEvent> get wpMessages => _eventBus.onWp;
  Stream<BleStatusEvent> get statusMessages => _eventBus.onStatus;
  Stream<BleBatteryEvent> get batteryMessages => _eventBus.onBattery;
  Stream<BleEfkEvent> get ekfMessages => _eventBus.onEfk;
  Stream<BleRawMessageEvent> get rawMessages => _eventBus.onRawMessage;
  
  bool _isListening = false;
  StringBuffer _messageBuffer = StringBuffer();
  int _dataReceivedCount = 0;
  
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
        print('[BLE] CCCD (0x2902) descriptor not found for ${ch.uuid}');
        return;
      }
      // Determine value for notify/indicate
      final List<int> value = ch.properties.indicate
          ? <int>[0x02, 0x00] // Indications enabled
          : <int>[0x01, 0x00] // Notifications enabled
          ;
      print('[BLE] Writing CCCD 0x2902 for ${ch.uuid}: ${value.map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
      await cccd.write(value);
      print('[BLE] ✓ CCCD write completed for ${ch.uuid}');
    } catch (e) {
      print('[BLE] ERROR writing CCCD for ${ch.uuid}: $e');
    }
  }

  /// Reconnect trực tiếp bằng device ID (không cần scan - nhanh hơn)
  Future<bool> _reconnectDirectly({int scanDurationSeconds = 10}) async {
    // Kiểm tra kỹ hơn: nếu đã connected hoặc đang connecting/setting up, không reconnect
    if (_lastDeviceId == null || _isConnecting || _isConnected || _isSettingUp) {
      if (_isConnected) {
        print('[BLE] Skip reconnect: already connected');
      } else if (_isConnecting) {
        print('[BLE] Skip reconnect: already connecting');
      } else if (_isSettingUp) {
        print('[BLE] Skip reconnect: already setting up');
      }
      return _isConnected;
    }

    try {
      print('[BLE] ========================================');
      print('[BLE] 🔄 QUICK RECONNECT: Kết nối trực tiếp bằng device ID...');
      print('[BLE] Device ID: $_lastDeviceId');
      print('[BLE] Device Name: $_lastDeviceName');
      print('[BLE] Scan duration: ${scanDurationSeconds}s');
      print('[BLE] Time: ${DateTime.now()}');
      print('[BLE] ========================================');

      _isConnecting = true;

      // Check Bluetooth adapter
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Bluetooth adapter is not on');
      }

      // Tìm device bằng ID - scan với thời gian dài hơn để đảm bảo tìm thấy
      print('[BLE] Scanning for device by ID (${scanDurationSeconds}s)...');
      
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
            print('[BLE] ✓ Found device in scan: ${foundDevice!.platformName}');
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
      print('[BLE] Connecting directly to device...');
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: true,
        mtu: 512,
      );

      await device.connectionState
          .where((state) => state == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 10));

      print('[BLE] ✓ Direct connection established!');

      // Tiếp tục setup như connectToDevice (discover services, setup characteristics, etc.)
      // Gọi lại phần setup từ connectToDevice
      await _setupDeviceAfterConnection(device);

      return true;
    } catch (e) {
      print('[BLE] ✗ Quick reconnect failed: $e');
      _isConnecting = false;
      return false;
    }
  }

  /// Setup device sau khi connect (discover services, setup characteristics, etc.)
  Future<void> _setupDeviceAfterConnection(BluetoothDevice device) async {
    // Tránh duplicate setup: nếu đang setup hoặc đã connected và có characteristic, skip
    if (_isSettingUp) {
      print('[BLE] Already setting up, skipping duplicate setup...');
      return;
    }
    
    if (_isConnected && _characteristic != null) {
      print('[BLE] Already connected and setup, skipping duplicate setup...');
      return;
    }
    
    _isSettingUp = true;
    try {
      // Request MTU
      try {
        await device.requestMtu(517);
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        print('[BLE] MTU request failed: $e');
      }

      // Discover services
      await Future.delayed(const Duration(milliseconds: 500));
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
        print('[BLE] Connection state changed: $state');
        if (state == BluetoothConnectionState.disconnected) {
          print('[BLE] ⚠️ DISCONNECTED: Bluetooth connection lost!');
          _handleDisconnection();
        } else if (state == BluetoothConnectionState.connected) {
          // Hủy reconnect timer ngay lập tức
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          // Không cần setup lại ở đây vì đã setup trong _setupDeviceAfterConnection
          // Listener này chỉ để cancel reconnect timer
        }
      });

      print('[BLE] ✓ Device setup completed');
    } catch (e) {
      print('[BLE] Error in device setup: $e');
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
      print('[BLE] Auto-reconnect sẽ bắt đầu sau 2 giây...');
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
      if (_isConnected) {
        print('[BLE] Skip reconnect attempt: already connected');
      } else if (_isConnecting) {
        print('[BLE] Skip reconnect attempt: already connecting');
      } else if (_isSettingUp) {
        print('[BLE] Skip reconnect attempt: already setting up');
      }
      return;
    }

    try {
      // Tăng thời gian scan mỗi lần retry: 10s, 15s, 20s
      final scanDuration = 10 + (attempt - 1) * 5;
      print('[BLE] ========================================');
      print('[BLE] 🔄 Auto-reconnect attempt $attempt/$maxAttempts');
      print('[BLE] Scan duration: ${scanDuration}s');
      print('[BLE] ========================================');
      
      final success = await _reconnectDirectly(scanDurationSeconds: scanDuration);
      if (success) {
        print('[BLE] ✓ Auto-reconnect thành công!');
        return;
      } else {
        throw Exception('Reconnect returned false');
      }
    } catch (e) {
      print('[BLE] ✗ Auto-reconnect attempt $attempt failed: $e');
      
      // Retry với thời gian scan dài hơn
      if (attempt < maxAttempts) {
        final nextAttempt = attempt + 1;
        final delaySeconds = 2 * attempt; // Exponential backoff: 2s, 4s, 6s
        print('[BLE] Retrying in ${delaySeconds}s (attempt ${nextAttempt}/$maxAttempts)...');
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
          _attemptReconnectWithRetry(attempt: nextAttempt, maxAttempts: maxAttempts);
        });
      } else {
        // Sau maxAttempts, fallback về scan by name
        print('[BLE] ========================================');
        print('[BLE] ⚠️ Quick reconnect failed after $maxAttempts attempts');
        print('[BLE] Falling back to scan by name...');
        print('[BLE] ========================================');
        if (_lastDeviceName != null && !_isConnecting) {
          try {
            await connectToDevice(_lastDeviceName!);
            print('[BLE] ✓ Fallback reconnect by name thành công!');
          } catch (e) {
            print('[BLE] ✗ Fallback reconnect by name thất bại: $e');
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
        print('[BLE] Starting scan for device: "$deviceName"');
        print('[BLE] Scanning for 20 seconds...');
        
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
            final remoteId = result.device.remoteId.toString();
            
            // Check both platformName and advName (case insensitive) - ONLY exact match
            final name1 = platformName.toLowerCase();
            final name2 = advName.toLowerCase();
            final searchName = deviceName.toLowerCase();
            
            // Strict: accept ONLY exact match on advertised or platform name
            if (name1 == searchName || name2 == searchName) {
              final deviceInfo = 'Name: ${platformName.isNotEmpty ? platformName : advName}, '
                  'RSSI: ${result.rssi}, '
                  'ID: $remoteId';
              print('[BLE] ✓ Found target device: $deviceInfo');
              foundDevice = result.device;
            }
          }
        });

        // Wait for device to be found (with timeout)
        final stopwatch = Stopwatch()..start();
        while (foundDevice == null && stopwatch.elapsedMilliseconds < 20000) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        
        print('[BLE] Scan completed');
        
        await subscription.cancel();
        isScanning = false;
        
        // Stop scan - only if we started it
        try {
          await FlutterBluePlus.stopScan();
          print('[BLE] Scan stopped');
        } catch (e) {
          // Ignore stop scan errors - already stopped is normal
        }
        
        // Wait a bit after stopping scan before connecting
        await Future.delayed(const Duration(milliseconds: 500));

        if (foundDevice == null) {
          print('[BLE] ERROR: Device "$deviceName" not found!');
          throw Exception('Không tìm thấy thiết bị "$deviceName".\n'
              'Vui lòng kiểm tra:\n'
              '- Thiết bị BLE đã bật và ở gần\n'
              '- Tên thiết bị chính xác: "AgriBeacon BLE"\n'
              '- Thử tắt/bật Bluetooth');
        }
        
        print('[BLE] ✓ Device found: ${foundDevice!.platformName.isNotEmpty ? foundDevice!.platformName : foundDevice!.advName}');

        // Wait a bit after finding device before connecting
        await Future.delayed(const Duration(milliseconds: 500));

        // Disconnect device first if it was previously connected (clean state)
        try {
          print('[BLE] Checking device connection state...');
          final connectionState = await foundDevice!.connectionState.first;
          print('[BLE] Current connection state: $connectionState');
          
          if (connectionState == BluetoothConnectionState.connected) {
            print('[BLE] Device already connected, disconnecting...');
            await foundDevice!.disconnect();
            // Wait for disconnection to complete
            await foundDevice!.connectionState
                .where((state) => state == BluetoothConnectionState.disconnected)
                .first
                .timeout(const Duration(seconds: 5));
            print('[BLE] Device disconnected, waiting 2 seconds...');
            await Future.delayed(const Duration(milliseconds: 2000));
          }
        } catch (e) {
          print('[BLE] Error checking/disconnecting: $e');
          // Try to disconnect anyway
          try {
            await foundDevice!.disconnect();
            await Future.delayed(const Duration(milliseconds: 2000));
          } catch (e2) {
            // Ignore
          }
        }

        // Connect to the device with retry
        print('[BLE] Attempting to connect to device...');
        try {
          // Try with autoConnect first (more reliable on Android)
          await foundDevice!.connect(
            timeout: const Duration(seconds: 30),
            autoConnect: true,
            mtu: 512,
          );
          print('[BLE] Connect call completed, waiting for connection state...');
        } on fbp.FlutterBluePlusException catch (e) {
          final errorString = e.toString();
          // Check for error code 133 (GATT_ERROR) or ANDROID_SPECIFIC_ERROR
          if (errorString.contains('133') || 
              errorString.contains('ANDROID_SPECIFIC_ERROR') ||
              errorString.contains('ANDROID_SPECIFIC_ERRROR')) {
            print('[BLE] GATT_ERROR 133 detected, retry count: $retryCount');
            // GATT_ERROR - retry with delay
            if (retryCount < maxRetries - 1) {
              retryCount++;
              // Wait longer before retry (exponential backoff)
              int delayMs = 2000 * retryCount;
              print('[BLE] Retrying in ${delayMs}ms...');
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
        print('[BLE] Waiting for connection to be established...');
        try {
          await foundDevice!.connectionState
              .where((state) => state == BluetoothConnectionState.connected)
              .first
              .timeout(const Duration(seconds: 10));
          print('[BLE] ✓ Connection established!');
        } catch (e) {
          // Check current state
          final currentState = await foundDevice!.connectionState.first;
          print('[BLE] Connection state after timeout: $currentState');
          if (currentState != BluetoothConnectionState.connected) {
            throw Exception('Connection timeout: device state is $currentState');
          }
        }
        
        // Explicitly request high MTU (Android only). iOS ignores/auto-negotiates.
        try {
          print('[BLE] Requesting MTU 517...');
          await foundDevice!.requestMtu(517);
          print('[BLE] ✓ MTU request issued (requested 517)');
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          print('[BLE] MTU request not supported or failed: $e');
        }

        // Discover services - add delay to ensure connection is stable
        print('[BLE] Waiting 500ms before discovering services...');
        await Future.delayed(const Duration(milliseconds: 500));
        print('[BLE] Discovering services...');
        List<BluetoothService> services = await foundDevice!.discoverServices();
        print('[BLE] Found ${services.length} services');
        
        // Log all services and characteristics for debugging - DETAILED
        print('[BLE] ========================================');
        
        // Verify Nordic UART service exists; otherwise: disconnect and retry
        final hasNordicService = services.any((s) => s.uuid.toString().toLowerCase() == nordicServiceUuid);
        if (!hasNordicService) {
          print('[BLE] ERROR: Expected Nordic UART service ($nordicServiceUuid) NOT found on this device');
          try {
            await foundDevice!.disconnect();
          } catch (_) {}
          throw Exception('Wrong device connected: missing Nordic UART service');
        }
        print('[BLE] ALL SERVICES AND CHARACTERISTICS:');
        print('[BLE] ========================================');
        for (var service in services) {
          print('[BLE] Service UUID: ${service.uuid}');
          print('[BLE] Service UUID (lowercase): ${service.uuid.toString().toLowerCase()}');
          print('[BLE] Number of characteristics: ${service.characteristics.length}');
          for (var char in service.characteristics) {
            print('[BLE]   ┌─ Characteristic: ${char.uuid}');
            print('[BLE]   │  UUID (lowercase): ${char.uuid.toString().toLowerCase()}');
            print('[BLE]   │  Properties:');
            print('[BLE]   │    - read: ${char.properties.read}');
            print('[BLE]   │    - write: ${char.properties.write}');
            print('[BLE]   │    - notify: ${char.properties.notify}');
            print('[BLE]   │    - indicate: ${char.properties.indicate}');
            print('[BLE]   └─────────────────────────────────');
          }
        }
        print('[BLE] ========================================');
        
        // Find characteristics using exact UUIDs from firmware
        // NOTE: Based on actual BLE properties:
        // - 6e400003 has notify=true → Use for RECEIVING data FROM device
        // - 6e400002 has write=true → Use for SENDING data TO device
        BluetoothCharacteristic? characteristic; // For receiving data (notify)
        BluetoothCharacteristic? writeCharacteristic; // For sending data (write)
        
        print('[BLE] Looking for Nordic UART characteristics...');
        print('[BLE] Target RX UUID: $nordicRxUuid (6e400003 - for receiving data, notify=true)');
        print('[BLE] Target TX UUID: $nordicTxUuid (6e400002 - for sending data, write=true)');
        
        // Find RX characteristic (6e400003) - for receiving data FROM device (has notify=true)
        for (var service in services) {
          for (var char in service.characteristics) {
            final charUuid = char.uuid.toString().toLowerCase();
            if (charUuid == nordicRxUuid.toLowerCase()) {
              characteristic = char;
              print('[BLE] ✓ Found RX characteristic (6e400003): ${char.uuid}');
              print('[BLE]   Properties: read=${char.properties.read}, notify=${char.properties.notify}, indicate=${char.properties.indicate}');
              if (!char.properties.notify && !char.properties.indicate) {
                print('[BLE]   ⚠️ WARNING: This characteristic does NOT have notify/indicate!');
              }
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
              print('[BLE] ✓ Found TX characteristic (6e400002): ${char.uuid}');
              print('[BLE]   Properties: write=${char.properties.write}');
              if (!char.properties.write) {
                print('[BLE]   ⚠️ WARNING: This characteristic does NOT have write!');
              }
              break;
            }
          }
          if (writeCharacteristic != null) break;
        }
        
        // Fallback: If exact UUIDs not found, try to find by properties
        if (characteristic == null) {
          print('[BLE] WARNING: RX UUID not found, trying fallback by properties...');
          for (var service in services) {
            for (var char in service.characteristics) {
              if (char.properties.notify) {
                characteristic = char;
                print('[BLE] Found characteristic with notify (fallback): ${char.uuid}');
                break;
              }
            }
            if (characteristic != null) break;
          }
        }
        
        if (writeCharacteristic == null) {
          print('[BLE] WARNING: TX UUID not found, trying fallback by properties...');
          for (var service in services) {
            for (var char in service.characteristics) {
              if (char.properties.write) {
                writeCharacteristic = char;
                print('[BLE] Found characteristic with write (fallback): ${char.uuid}');
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
        
        print('[BLE] Connected to device: $_deviceName');
        print('[BLE] Device ID saved for quick reconnect: $_lastDeviceId');
        print('[BLE] Using characteristic for reading: ${characteristic?.uuid ?? "NONE"}');
        if (writeCharacteristic != null) {
          print('[BLE] Write characteristic available: ${writeCharacteristic.uuid}');
        }
        
        _connectionStatusController.add(true);

        // DEBUG: also subscribe to ALL notify/indicate characteristics to ensure we don't miss data
        print('[BLE] Checking for any other notifiable characteristics to subscribe (debug) ...');
        for (final service in services) {
          for (final ch in service.characteristics) {
            final isTarget = characteristic != null && ch.uuid == characteristic.uuid;
            if (!isTarget && (ch.properties.notify || ch.properties.indicate)) {
              try {
                print('[BLE] Subscribing (debug) to ${ch.uuid} notify=${ch.properties.notify} indicate=${ch.properties.indicate}');
                await ch.setNotifyValue(true);
                // Also write CCCD explicitly
                await _writeCccdForCharacteristic(ch);
                final sub = ch.onValueReceived.listen((data) {
                  final ts = DateTime.now();
                  print('[BLE DEBUG NOTIFY @${ts.toString()}] from ${ch.uuid} -> len=${data.length} hex=${data.map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
                });
                _extraNotifySubscriptions.add(sub);
              } catch (e) {
                print('[BLE] Could not subscribe (debug) to ${ch.uuid}: $e');
              }
            }
          }
        }

        // Start listening for messages if characteristic supports notify/indicate
        if (characteristic != null && (characteristic.properties.notify || characteristic.properties.indicate)) {
          print('[BLE] ========================================');
          print('[BLE] Starting to listen for notifications...');
          print('[BLE TEST] Listening on characteristic: ${characteristic.uuid}');
          print('[BLE TEST] Full UUID: ${characteristic.uuid.toString().toLowerCase()}');
          print('[BLE TEST] Expected RX UUID: $nordicRxUuid');
          print('[BLE TEST] UUID matches RX (6e400003)? ${characteristic.uuid.toString().toLowerCase() == nordicRxUuid.toLowerCase()}');
          print('[BLE] ========================================');
          try {
            await startListening();
            print('[BLE] Successfully started listening');
            print('[BLE] Listening only. Waiting for device notifications...');
          } catch (e) {
            print('[BLE] Error starting listening: $e');
          }
        } else if (characteristic != null && characteristic.properties.read) {
          print('[BLE] Characteristic only supports read, will poll for data');
          // Try reading immediately
          try {
            final data = await characteristic.read();
            if (data.isNotEmpty) {
              print('[BLE] Initial data read: ${data.length} bytes');
              _processMessage(data);
            } else {
              print('[BLE] No initial data available');
            }
          } catch (e) {
            print('[BLE] Could not read data: $e');
          }
          
          // Start polling for data every 500ms
          print('[BLE] Starting polling timer (every 500ms)...');
          _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
            if (_characteristic == null || !_isConnected) {
              print('[BLE] Polling stopped: characteristic is null or disconnected');
              timer.cancel();
              return;
            }
            
            try {
              print('[BLE] Polling: Reading characteristic...');
              final data = await _characteristic!.read();
              if (data.isNotEmpty) {
                print('[BLE] Polling: Data received: ${data.length} bytes');
                _processMessage(data);
              } else {
                print('[BLE] Polling: No data (0 bytes)');
              }
            } catch (e) {
              print('[BLE] Polling error: $e');
              // Don't cancel timer on error, just log and continue
            }
          });
          print('[BLE] ✓ Polling timer started');
        } else {
          print('[BLE] WARNING: No suitable characteristic found for receiving data!');
        }

        // Listen for disconnection and auto-reconnect
        _lastDeviceName = _deviceName; // Lưu tên device để reconnect
        _currentDeviceForListener = foundDevice; // Lưu device reference cho listener
        _connectionStateSubscription?.cancel(); // Cancel subscription cũ nếu có
        
        print('[BLE] ========================================');
        print('[BLE] Setting up connection state listener...');
        print('[BLE] Device: $_lastDeviceName');
        print('[BLE] ========================================');
        
        _connectionStateSubscription = foundDevice!.connectionState.listen((state) {
          // Log tất cả connection state changes để debug
          print('[BLE] ========================================');
          print('[BLE] Connection state changed: $state');
          print('[BLE] Device: $_lastDeviceName');
          print('[BLE] Time: ${DateTime.now()}');
          print('[BLE] ========================================');
          
          if (state == BluetoothConnectionState.disconnected) {
            // Log khi bị ngắt kết nối
            print('[BLE] ========================================');
            print('[BLE] ⚠️ DISCONNECTED: Bluetooth connection lost!');
            print('[BLE] Device: $_lastDeviceName');
            print('[BLE] Time: ${DateTime.now()}');
            print('[BLE] ========================================');
            
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
            print('[BLE] ✓ Connection state: CONNECTED');
            // Hủy reconnect timer ngay lập tức khi detect connected
            _reconnectTimer?.cancel();
            _reconnectTimer = null;
            
            // Nếu device tự động reconnect (autoConnect) nhưng chưa setup, cần setup lại
            // Chỉ setup nếu thực sự chưa connected hoặc chưa có characteristic
            if (_currentDeviceForListener != null && (!_isConnected || _characteristic == null) && !_isSettingUp) {
              print('[BLE] Device tự động reconnect, đang setup lại...');
              // Gọi async function không await (trong listener callback)
              _setupDeviceAfterConnection(_currentDeviceForListener!).then((_) {
                print('[BLE] ✓ Setup lại device sau auto-reconnect thành công!');
              }).catchError((e) {
                print('[BLE] ✗ Lỗi khi setup lại device: $e');
              });
            } else {
              if (_isConnected && _characteristic != null) {
                print('[BLE] Device đã connected và setup, không cần setup lại');
              } else if (_isSettingUp) {
                print('[BLE] Đang setup, không cần setup lại');
              }
            }
          }
          // Note: connecting/disconnecting states are deprecated and not streamed by Android/iOS
        }, onError: (error) {
          print('[BLE] ========================================');
          print('[BLE] ERROR in connection state listener: $error');
          print('[BLE] Time: ${DateTime.now()}');
          print('[BLE] ========================================');
        }, onDone: () {
          print('[BLE] ========================================');
          print('[BLE] Connection state listener closed');
          print('[BLE] Time: ${DateTime.now()}');
          print('[BLE] ========================================');
        });
        
        print('[BLE] ✓ Connection state listener setup completed');

        return true;
      } on fbp.FlutterBluePlusException catch (e) {
        final errorString = e.toString();
        print('[BLE Exception] $errorString');
        lastException = Exception('Lỗi BLE: $errorString');
        
        // Retry on connection errors (133, permission errors, etc.)
        if (errorString.contains('133') || 
            errorString.contains('ANDROID_SPECIFIC_ERROR') ||
            errorString.contains('ANDROID_SPECIFIC_ERRROR')) {
          if (retryCount < maxRetries - 1) {
            retryCount++;
            int delayMs = 2000 * retryCount;
            print('[BLE] Retrying connection in ${delayMs}ms (attempt ${retryCount + 1}/$maxRetries)');
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
      print('[BLE] Error during disconnect: $e');
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
      print('[BLE] Writing data: ${data.length} bytes, hex: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      print('[BLE] Writing as string: "${String.fromCharCodes(data)}"');
      await ch.write(data, withoutResponse: supportsWriteNoResp);
      print('[BLE] ✓ Data written successfully (withoutResponse=${supportsWriteNoResp})');
    } else {
      throw Exception('Characteristic không hỗ trợ ghi dữ liệu');
    }
  }
  
  /// Write string to the connected device
  Future<void> writeString(String message) async {
    final data = utf8.encode(message);
    await writeData(data);
  }

  /// Write string with line ending (e.g., CRLF) to the connected device
  Future<void> writeStringWithEnding(String message, {String lineEnding = '\\r\\n'}) async {
    final payload = '$message$lineEnding';
    await writeString(payload);
  }

  /// Read data from the connected device
  Future<List<int>> readData() async {
    if (_characteristic == null || !_isConnected) {
      throw Exception('Không có kết nối BLE');
    }

    if (_characteristic!.properties.read) {
      return await _characteristic!.read();
    } else {
      throw Exception('Characteristic không hỗ trợ đọc dữ liệu');
    }
  }

  /// Subscribe to notifications
  Future<void> subscribeToNotifications(Function(List<int>) onData) async {
    if (_characteristic == null || !_isConnected) {
      throw Exception('Không có kết nối BLE');
    }

    if (_characteristic!.properties.notify) {
      await _characteristic!.setNotifyValue(true);
      _valueSubscription = _characteristic!.onValueReceived.listen(onData);
    } else {
      throw Exception('Characteristic không hỗ trợ thông báo');
    }
  }

  /// Start listening for messages from BLE device
  Future<void> startListening() async {
    if (_characteristic == null || !_isConnected) {
      print('[BLE] Cannot start listening: characteristic=${_characteristic != null}, connected=$_isConnected');
      return;
    }

    if (_isListening) {
      print('[BLE] Already listening, skipping...');
      return;
    }

    if (!_characteristic!.properties.notify && !_characteristic!.properties.indicate) {
      print('[BLE] ERROR: Characteristic ${_characteristic!.uuid} does not support notify/indicate');
      print('[BLE] Properties: notify=${_characteristic!.properties.notify}, indicate=${_characteristic!.properties.indicate}');
      throw Exception('Characteristic không hỗ trợ thông báo (notify/indicate)');
    }

    try {
      print('[BLE] ========================================');
      print('[BLE] ENABLING NOTIFICATIONS');
      print('[BLE] Characteristic UUID: ${_characteristic!.uuid}');
      print('[BLE] Full UUID: ${_characteristic!.uuid.toString().toLowerCase()}');
      print('[BLE] Characteristic properties: notify=${_characteristic!.properties.notify}, indicate=${_characteristic!.properties.indicate}');
      print('[BLE] ========================================');
      
      // Enable notify or indicate
      if (_characteristic!.properties.notify) {
        print('[BLE] Calling setNotifyValue(true)...');
        await _characteristic!.setNotifyValue(true);
        print('[BLE] ✓ setNotifyValue(true) completed');
        print('[BLE] Waiting 500ms to ensure notify is fully enabled...');
        await Future.delayed(const Duration(milliseconds: 500));
        print('[BLE] ✓ Notify should now be fully enabled');
        // Also write CCCD explicitly for reliability
        await _writeCccdForCharacteristic(_characteristic!);
      } else if (_characteristic!.properties.indicate) {
        print('[BLE] Calling setNotifyValue(true) for indicate...');
        await _characteristic!.setNotifyValue(true); // Same API for indicate
        print('[BLE] ✓ setNotifyValue(true) completed');
        print('[BLE] Waiting 500ms to ensure indicate is fully enabled...');
        await Future.delayed(const Duration(milliseconds: 500));
        print('[BLE] ✓ Indicate should now be fully enabled');
        // Also write CCCD explicitly for reliability
        await _writeCccdForCharacteristic(_characteristic!);
      }
      
      _isListening = true;
      print('[BLE] Notifications enabled, waiting for data...');
      
      // Listen for incoming data - log EVERYTHING with timestamp
      print('[BLE] Setting up onValueReceived listener...');
      _dataReceivedCount = 0; // Reset counter
      _valueSubscription = _characteristic!.onValueReceived.listen((data) {
        _dataReceivedCount++;
        final timestamp = DateTime.now();
        print('[BLE] ========================================');
        print('[BLE] ===== DATA RECEIVED #$_dataReceivedCount @${timestamp.toString()} =====');
        print('[BLE DATA RECEIVED #$_dataReceivedCount @${timestamp.toString()}] ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        print('[BLE] Received data: ${data.length} bytes');
        if (data.isEmpty) {
          print('[BLE] ⚠️ WARNING: Received 0 bytes - this might be a notification trigger without data');
        } else {
          print('[BLE] ✓ Received ${data.length} bytes of actual data!');
        }
        print('[BLE] Raw bytes: ${data.join(', ')}');
        print('[BLE] Hex: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        _processMessage(data);
        print('[BLE] ========================================');
      }, onError: (error) {
        final timestamp = DateTime.now();
        print('[BLE] ========================================');
        print('[BLE] ERROR in data stream @${timestamp.toString()}: $error');
        print('[BLE] Error type: ${error.runtimeType}');
        print('[BLE] Stack trace: ${StackTrace.current}');
        print('[BLE] ========================================');
      }, onDone: () {
        final timestamp = DateTime.now();
        print('[BLE] ========================================');
        print('[BLE] Data stream closed @${timestamp.toString()}');
        print('[BLE] Total data received: $_dataReceivedCount times');
        print('[BLE] ========================================');
        _isListening = false;
      });
      print('[BLE] ✓ onValueReceived listener is now active');
      print('[BLE] Listener will trigger whenever device sends data via notify');
      
      print('[BLE] ✓ Listening started successfully - ready to receive data!');
    } catch (e) {
      _isListening = false;
      print('[BLE] ERROR starting listening: $e');
      print('[BLE] Stack trace: ${StackTrace.current}');
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

  /// Process incoming message data - LOG EVERYTHING
  void _processMessage(List<int> data) {
    print('[BLE] _processMessage called with ${data.length} bytes');
    
    // Try UTF-8 decode first
    try {
      String message = utf8.decode(data);
      print('[BLE] UTF-8 decoded: "$message"');
      print('[BLE] Message length: ${message.length}');
      print('[BLE] Message bytes: ${message.codeUnits.join(', ')}');
      
      // Append to buffer (handle fragmented packets)
      _messageBuffer.write(message);
      final bufferStr = _messageBuffer.toString();
      print('[BLE] Buffer after write: "$bufferStr"');

      // Only process complete lines (terminated by \n). If no newline yet, wait for next packets.
      final lastNewline = bufferStr.lastIndexOf('\n');
      if (lastNewline == -1) {
        print('[BLE] No newline found yet - waiting for more data');
        return;
      }

      // Separate complete part and remainder
      final completePart = bufferStr.substring(0, lastNewline);
      final remainder = bufferStr.substring(lastNewline + 1); // after \n
      // Keep remainder (incomplete line) in buffer
      _messageBuffer
        ..clear()
        ..write(remainder);

      // Split and process each complete line
      final lines = completePart.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) {
          continue;
        }
        _eventBus.emitRawMessage(line);
        _parseAndRouteMessage(line);
      }
    } catch (e) {
      print('[BLE ERROR] UTF-8 decode failed: $e');
      // Try to decode as ASCII if UTF-8 fails
      try {
        String message = String.fromCharCodes(data);
        _messageBuffer.write(message);
        final bufferStr = _messageBuffer.toString();
        final lastNewline = bufferStr.lastIndexOf('\n');
        if (lastNewline == -1) {
          return;
        }
        final completePart = bufferStr.substring(0, lastNewline);
        final remainder = bufferStr.substring(lastNewline + 1);
        _messageBuffer
          ..clear()
          ..write(remainder);
        final lines = completePart.split('\n');
        for (final line in lines) {
          final l = line.trim();
          if (l.isEmpty) continue;
          _eventBus.emitRawMessage(l);
          _parseAndRouteMessage(l);
        }
      } catch (e2) {
        print('[BLE ERROR] ASCII decode also failed: $e2');
        // Print everything we can
        print('[BLE] Raw bytes: ${data.join(', ')}');
        print('[BLE] Hex: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        print('[BLE] As string from codes: "${String.fromCharCodes(data)}"');
      }
    }
  }

  /// Parse message and route to appropriate handler
  void _parseAndRouteMessage(String message) {
    // Log giá trị nhận được (chỉ log giá trị, không có text)
    print(message);
    
    // HOME message
    if (message.startsWith('HOME:')) {
      String data = message.substring(5).trim(); // Remove "HOME:" prefix
      _eventBus.emitHome(data);
      return;
    }
    // WP (Waypoint) message
    else if (message.startsWith('WP:')) {
      String data = message.substring(3).trim(); // Remove "WP:" prefix
      _eventBus.emitWp(data);
    }
    // STATUS message
    else if (message.startsWith('STATUS:')) {
      String data = message.substring(7).trim(); // Remove "STATUS:" prefix
      _eventBus.emitStatus(data);
    }
    // BATTERY message
    else if (message.startsWith('BATTERY:')) {
      String data = message.substring(8).trim(); // Remove "BATTERY:" prefix
      _eventBus.emitBattery(data);
    }
    // EKF message
    else if (message.startsWith('EKF:')) {
      String data = message.substring(4).trim(); // Remove "EKF:" prefix
      _eventBus.emitEfk(data);
    }
    // Unknown message format - chỉ log giá trị (đã log ở đầu hàm)
    else {
      // Do not emit raw again here to avoid duplication
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
    // EventBus will be disposed separately if needed
  }
}


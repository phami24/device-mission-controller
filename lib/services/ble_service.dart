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
  Timer? _stateDebounceTimer; // Debounce timer cho connection state changes
  BluetoothConnectionState? _lastState; // Lưu state cuối cùng để debounce
  
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isSettingUp = false; // Flag để tránh duplicate setup
  bool _reconnectLock = false; // Global lock để prevent multiple reconnect tasks
  bool _isProcessingStateChange = false; // Flag để tránh race condition trong state listener
  String? _deviceName;
  
  // Store all reconnect timers để cleanup memory leaks
  final List<Timer> _allReconnectTimers = [];
  
  // Connection health check timer
  Timer? _connectionHealthCheckTimer;
  
  // Streams for connection status
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;
  
  // Reconnect attempt info for UI
  int _reconnectAttempt = 0;
  final _reconnectStatusController = StreamController<String>.broadcast();
  Stream<String> get reconnectStatus => _reconnectStatusController.stream;
  
  int get reconnectAttempt => _reconnectAttempt;
  
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

  /// Force disconnect tất cả devices có cùng ID/name để cleanup stale connections
  Future<void> _forceDisconnectAllDevices(String? deviceId, String? deviceName) async {
    try {
      print('[BLE] 🧹 [FORCE_DISCONNECT] Bắt đầu cleanup stale connections...');
      print('[BLE] 🧹 [FORCE_DISCONNECT] Device ID: $deviceId, Device Name: $deviceName');
      print('[BLE] 🧹 [FORCE_DISCONNECT] Current device: ${_currentDeviceForListener?.remoteId.toString()}');
      
      // Lấy danh sách tất cả connected devices
      final connectedDevices = await FlutterBluePlus.connectedDevices;
      print('[BLE] 🧹 [FORCE_DISCONNECT] Tìm thấy ${connectedDevices.length} connected device(s)');
      
      int disconnectedCount = 0;
      for (final device in connectedDevices) {
        try {
          final deviceIdStr = device.remoteId.toString();
          final platformName = device.platformName;
          final advName = device.advName;
          final currentState = await device.connectionState.first;
          
          print('[BLE] 🧹 [FORCE_DISCONNECT] Checking device: ID=$deviceIdStr, PlatformName=$platformName, AdvName=$advName, State=$currentState');
          
          // QUAN TRỌNG: KHÔNG disconnect device đang được sử dụng bởi app này
          final isCurrentDevice = _currentDeviceForListener != null && 
                                  _currentDeviceForListener!.remoteId.toString() == deviceIdStr;
          
          if (isCurrentDevice) {
            print('[BLE] 🧹 [FORCE_DISCONNECT] ⚠️ Skip - đây là device đang được sử dụng bởi app này');
            continue;
          }
          
          // Disconnect nếu device ID hoặc name khớp
          final shouldDisconnect = (deviceId != null && deviceIdStr == deviceId) ||
                                   (deviceName != null && 
                                    (platformName.toLowerCase() == deviceName.toLowerCase() ||
                                     advName.toLowerCase() == deviceName.toLowerCase()));
          
          if (shouldDisconnect) {
            print('[BLE] 🧹 [FORCE_DISCONNECT] ⚠️ MATCH FOUND! Disconnecting stale device: ${platformName.isNotEmpty ? platformName : advName} (State: $currentState)');
            try {
              if (currentState == BluetoothConnectionState.connected) {
                // QUAN TRỌNG: Chỉ gửi disconnect command, KHÔNG đợi state change
                // Android BLE stack không đảm bảo onConnectionStateChange được gọi
                // Đợi state change có thể làm stuck BLE stack
                await device.disconnect();
                print('[BLE] 🧹 [FORCE_DISCONNECT] Disconnect command sent (not waiting for state change)');
                disconnectedCount++;
              } else {
                print('[BLE] 🧹 [FORCE_DISCONNECT] Device already in state: $currentState, skipping disconnect');
              }
            } catch (e) {
              print('[BLE] 🧹 [FORCE_DISCONNECT] ⚠️ Error disconnecting device: $e');
              // Ignore disconnect errors - device might already be disconnected
            }
          } else {
            print('[BLE] 🧹 [FORCE_DISCONNECT] Device không khớp, bỏ qua');
          }
        } catch (e) {
          print('[BLE] 🧹 [FORCE_DISCONNECT] ⚠️ Error checking device: $e');
          // Ignore errors for individual devices
        }
      }
      
      print('[BLE] 🧹 [FORCE_DISCONNECT] Đã disconnect $disconnectedCount device(s)');
      
      // QUAN TRỌNG: Android cần ~1-2 giây để cleanup GATT connection sau disconnect
      // Đợi đủ thời gian để OS cleanup hoàn toàn trước khi connect lại
      // Delay ngắn → device chưa hoàn toàn disconnected → scan bị conflict
      print('[BLE] 🧹 [FORCE_DISCONNECT] Đợi 2000ms để OS cleanup GATT connection...');
      await Future.delayed(const Duration(milliseconds: 2000));
      print('[BLE] 🧹 [FORCE_DISCONNECT] Cleanup hoàn tất');
    } catch (e) {
      // Ignore errors - this is a cleanup operation
      print('[BLE] 🧹 [FORCE_DISCONNECT] ⚠️ ERROR: Could not force disconnect all devices: $e');
      print('[BLE] 🧹 [FORCE_DISCONNECT] Stack trace: ${StackTrace.current}');
    }
  }

  /// Setup state listener (tách riêng để có thể gọi lại)
  void _setupStateListener(BluetoothDevice device) {
    // QUAN TRỌNG: Cancel listener cũ trước khi setup mới để tránh duplicate
    if (_connectionStateSubscription != null) {
      print('[BLE] [SETUP] Canceling old state listener before setting up new one...');
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
    }
    
    _lastDeviceName = _deviceName;
    _currentDeviceForListener = device; // Update device reference
    _stateDebounceTimer?.cancel();
    _lastState = BluetoothConnectionState.connected; // Set initial state
    
    print('[BLE] [SETUP] Setting up state listener AFTER setup completed...');
    _connectionStateSubscription = device.connectionState.listen((state) {
      print('[BLE] [STATE_LISTENER] Connection state changed: $state (last: $_lastState)');
      
      // Debounce: chỉ xử lý nếu state thực sự thay đổi
      if (_lastState == state) {
        print('[BLE] [STATE_LISTENER] State unchanged, ignoring');
        return;
      }
      
      _lastState = state;
      
      // QUAN TRỌNG: Debounce với 2000ms để cho Android đủ thời gian cleanup GATT
      // Debounce ngắn → xử lý state change quá nhanh → stack stuck
      _stateDebounceTimer?.cancel();
      _stateDebounceTimer = Timer(const Duration(milliseconds: 2000), () {
        // QUAN TRỌNG: Check flag để tránh race condition
        if (_isProcessingStateChange) {
          print('[BLE] [STATE_LISTENER] Already processing state change, ignoring');
          return;
        }
        
        // Double check: chỉ xử lý nếu state vẫn còn như vậy sau debounce
        device.connectionState.first.then((currentState) {
          if (currentState == state && !_isProcessingStateChange) {
            _isProcessingStateChange = true;
            _processConnectionStateChange(state, device).then((_) {
              _isProcessingStateChange = false;
            }).catchError((e) {
              print('[BLE] [STATE_LISTENER] Error processing state change: $e');
              _isProcessingStateChange = false;
            });
          } else {
            print('[BLE] [STATE_LISTENER] State changed during debounce, ignoring: $state -> $currentState');
          }
        });
      });
    });
    print('[BLE] [SETUP] ✓ State listener setup completed');
  }

  /// Process connection state change với debounce
  Future<void> _processConnectionStateChange(BluetoothConnectionState state, BluetoothDevice device) async {
    print('[BLE] [STATE_PROCESS] Processing state: $state');
    print('[BLE] [STATE_PROCESS] Current flags: _isConnected=$_isConnected, _isConnecting=$_isConnecting, _isSettingUp=$_isSettingUp, hasCharacteristic=${_characteristic != null}');
    
    if (state == BluetoothConnectionState.disconnected) {
      // Chỉ xử lý disconnect nếu:
      // 1. Không đang setup
      // 2. Đã connected (có characteristic)
      // 3. Device ID khớp (so sánh bằng ID, không phải object reference)
      if (!_isSettingUp && _isConnected && _characteristic != null && _isSameDevice(_currentDeviceForListener, device)) {
        print('[BLE] [STATE_PROCESS] ⚠️ DISCONNECTED: Bluetooth connection lost!');
        _handleDisconnection();
      } else {
        print('[BLE] [STATE_PROCESS] Ignoring disconnect - isSettingUp=$_isSettingUp, isConnected=$_isConnected, hasCharacteristic=${_characteristic != null}, deviceMatch=${_isSameDevice(_currentDeviceForListener, device)}');
      }
    } else if (state == BluetoothConnectionState.connected) {
      print('[BLE] [STATE_PROCESS] ✓ CONNECTED: Cancelling reconnect timer');
      // Hủy tất cả reconnect timers
      _cancelAllReconnectTimers();
      
      // Chỉ setup lại nếu:
      // 1. Device ID khớp
      // 2. Chưa connected hoặc chưa có characteristic
      // 3. Không đang setup
      // 4. Không đang connecting
      if (_isSameDevice(_currentDeviceForListener, device) && 
          (!_isConnected || _characteristic == null) && 
          !_isSettingUp && 
          !_isConnecting) {
        print('[BLE] [STATE_PROCESS] Setup needed, calling _setupDeviceAfterConnection...');
        _setupDeviceAfterConnection(device).catchError((e) {
          print('[BLE] [STATE_PROCESS] ⚠️ Setup error (ignored): $e');
        });
      } else {
        print('[BLE] [STATE_PROCESS] Skip setup - deviceMatch=${_isSameDevice(_currentDeviceForListener, device)}, isConnected=$_isConnected, hasCharacteristic=${_characteristic != null}, isSettingUp=$_isSettingUp, isConnecting=$_isConnecting');
      }
    } else {
      print('[BLE] [STATE_PROCESS] State: $state');
    }
  }
  
  /// So sánh device bằng ID thay vì object reference (tránh multiple instances issue)
  bool _isSameDevice(BluetoothDevice? device1, BluetoothDevice? device2) {
    if (device1 == null || device2 == null) return false;
    return device1.remoteId.toString() == device2.remoteId.toString();
  }
  
  /// Cancel tất cả reconnect timers để cleanup memory leaks
  void _cancelAllReconnectTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    for (final timer in _allReconnectTimers) {
      timer.cancel();
    }
    _allReconnectTimers.clear();
  }
  
  /// Wrap GATT operations với retry logic để handle error 133
  /// Error 133 (GATT_ERROR) có thể xảy ra ở nhiều nơi: discoverServices, setNotifyValue, read, write
  Future<T> _withGattRetry<T>(Future<T> Function() operation) async {
    int retries = 0;
    const maxRetries = 3;
    
    while (retries < maxRetries) {
      try {
        return await operation();
      } on fbp.FlutterBluePlusException catch (e) {
        final errorString = e.toString();
        // Retry nếu là GATT error 133 và chưa hết retry
        if (errorString.contains('133') && retries < maxRetries - 1) {
          retries++;
          final delaySeconds = retries * 2; // Exponential backoff: 2s, 4s, 6s
          print('[BLE] [GATT_RETRY] GATT error 133 detected, retrying in ${delaySeconds}s (attempt $retries/$maxRetries)...');
          await Future.delayed(Duration(seconds: delaySeconds));
          continue;
        }
        // Nếu không phải error 133 hoặc đã hết retry, rethrow
        rethrow;
      } catch (e) {
        // Nếu không phải FlutterBluePlusException, rethrow ngay
        rethrow;
      }
    }
    
    throw Exception('GATT operation failed after $maxRetries retries');
  }

  /// Setup device sau khi connect (discover services, setup characteristics, etc.)
  Future<void> _setupDeviceAfterConnection(BluetoothDevice device) async {
    // Tránh duplicate setup: nếu đang setup, skip
    if (_isSettingUp) {
      print('[BLE] [SETUP] Skip setup - isSettingUp=true');
      return;
    }
    
    // QUAN TRỌNG: Khi reconnect, Android drop notify subscription silently
    // Characteristic object vẫn còn nhưng notify đã bị disable
    // PHẢI LUÔN rediscover và re-enable notify, KHÔNG được skip
    print('[BLE] [SETUP] Step 1: Starting setup device (luôn rediscover để re-enable notify)...');
    
    _isSettingUp = true;
    _isConnecting = false; // Reset connecting flag khi bắt đầu setup
    
    try {
      // QUAN TRỌNG: Luôn request MTU và discover services khi reconnect
      // Vì notify subscription đã bị drop, cần rediscover để có characteristic mới
      print('[BLE] [SETUP] Step 2: Requesting MTU...');
      try {
        await device.requestMtu(517).timeout(const Duration(seconds: 2));
        print('[BLE] [SETUP] Step 2: ✓ MTU requested');
      } catch (e) {
        print('[BLE] [SETUP] Step 2: ⚠️ MTU request error (ignored): $e');
        // Ignore MTU errors - continue anyway
      }

      // QUAN TRỌNG: Luôn discover services để có characteristic mới với notify enabled
      // Wrap với GATT retry để handle error 133
      print('[BLE] [SETUP] Step 3: Discovering services...');
      List<BluetoothService> services;
      try {
        services = await _withGattRetry(() => device.discoverServices().timeout(const Duration(seconds: 10)));
        print('[BLE] [SETUP] Step 3: ✓ Discovered ${services.length} service(s)');
      } on TimeoutException {
        print('[BLE] [SETUP] Step 3: ⚠️ Discovery timeout, cleaning up connection...');
        // QUAN TRỌNG: Disconnect device khi discovery timeout để cleanup
        try {
          await device.disconnect();
          await Future.delayed(const Duration(milliseconds: 2000));
        } catch (e) {
          print('[BLE] [SETUP] Cleanup error (ignored): $e');
        }
        throw Exception('Discovery timeout - cleaned up connection');
      }
    
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

      // QUAN TRỌNG: Stop listening cũ trước khi set characteristic mới
      if (_isListening) {
        print('[BLE] [SETUP] Stopping old listening...');
        stopListening();
      }

      _connectedDevice = device;
      _characteristic = characteristic;
      _writeCharacteristic = writeCharacteristic;
      _deviceName = device.platformName.isNotEmpty 
          ? device.platformName 
          : device.advName.isNotEmpty 
              ? device.advName 
              : 'Unknown Device';
      // QUAN TRỌNG: CHƯA SET _isConnected = true - chỉ set sau khi verify notify thành công
      _isConnecting = false; // Reset connecting flag
      _currentDeviceForListener = device; // Update device reference cho listener

      print('[BLE] [SETUP] Step 4: Found characteristics, device info set');

      // QUAN TRỌNG: Setup connection state listener TRƯỚC khi enable notify
      // để có thể catch disconnect events ngay lập tức
      print('[BLE] [SETUP] Step 5: Setting up state listener...');
      _setupStateListener(device);
      print('[BLE] [SETUP] Step 6: State listener setup completed');
      
      // QUAN TRỌNG: Verify device vẫn connected TRƯỚC KHI enable notify
      print('[BLE] [SETUP] Step 7: Verifying device connection state...');
      final currentState = await device.connectionState.first
          .timeout(const Duration(seconds: 2));
      
      if (currentState != BluetoothConnectionState.connected) {
        throw Exception('Device disconnected during setup (state: $currentState)');
      }
      print('[BLE] [SETUP] Step 8: Device connection verified');
      
      // QUAN TRỌNG: Start listening SAU KHI discovery và setup listener xong
      // Không được gọi startListening() trước discovery vì notify không được enable
      // QUAN TRỌNG: Đợi 500ms để GATT connection ổn định trước khi enable notify
      if (!_isListening && _characteristic != null) {
        if (_characteristic!.properties.notify || _characteristic!.properties.indicate) {
          print('[BLE] [SETUP] Step 9: Waiting 500ms for GATT connection to stabilize...');
          await Future.delayed(const Duration(milliseconds: 500));
          print('[BLE] [SETUP] Step 10: Starting to listen...');
          await startListening(); // ← Có thể throw error nếu notify fail
          print('[BLE] [SETUP] Step 11: ✓ Listening started successfully');
        }
      }
      
      // ✅ CHỈ SET TRUE KHI ĐÃ VERIFY NOTIFY THÀNH CÔNG
      print('[BLE] [SETUP] Step 12: Setting _isConnected = true (all setup verified)');
      _isConnected = true;
      _connectionStatusController.add(true);
      
      // Start health check để monitor connection
      _startConnectionHealthCheck();
      
      print('[BLE] [SETUP] ✅ Setup completed successfully - isConnected=$_isConnected, hasCharacteristic=${_characteristic != null}');
    } catch (e) {
      // ← Cleanup khi fail
      print('[BLE] [SETUP] ⚠️ Setup failed: $e');
      _isConnected = false;
      _characteristic = null;
      _writeCharacteristic = null;
      _connectedDevice = null;
      _currentDeviceForListener = null;
      _isListening = false;
      _connectionStatusController.add(false);
      _stopConnectionHealthCheck();
      _isSettingUp = false;
      rethrow;
    } finally {
      _isSettingUp = false;
    }
  }

  /// Handle disconnection
  void _handleDisconnection() {
    print('[BLE] [HANDLE_DISCONNECT] Bắt đầu xử lý disconnection...');
    print('[BLE] [HANDLE_DISCONNECT] Current state: _isConnected=$_isConnected, _isConnecting=$_isConnecting, _isSettingUp=$_isSettingUp');
    print('[BLE] [HANDLE_DISCONNECT] Device info: _lastDeviceId=$_lastDeviceId, _lastDeviceName=$_lastDeviceName');
    
    // Cancel debounce timer
    _stateDebounceTimer?.cancel();
    _lastState = null;
    
    // Cancel state listener - QUAN TRỌNG: Cancel trước khi reset để tránh race condition
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _currentDeviceForListener = null;
    
    for (final s in _extraNotifySubscriptions) {
      s.cancel();
    }
    _extraNotifySubscriptions.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    
    // Stop health check
    _stopConnectionHealthCheck();
    
    // QUAN TRỌNG: Chỉ reset các flags cần thiết, KHÔNG reset _isConnecting và _isSettingUp
    // Vì có thể đang có reconnect task đang chạy
    _isConnected = false;
    _characteristic = null;
    _writeCharacteristic = null;
    _isListening = false;
    _messageBuffer.clear();
    _connectionStatusController.add(false);
    
    // Reset reconnect attempt
    _reconnectAttempt = 0;
    _reconnectStatusController.add('');

    print('[BLE] [HANDLE_DISCONNECT] State reset completed');
    print('[BLE] [HANDLE_DISCONNECT] Checking auto-reconnect: _lastDeviceId=$_lastDeviceId, _isConnecting=$_isConnecting');

    // Auto-reconnect với retry logic - chỉ schedule nếu không có reconnect lock
    // QUAN TRỌNG: Tăng delay lên 5s để cho Android đủ thời gian cleanup GATT
    if (_lastDeviceId != null && !_reconnectLock) {
      print('[BLE] [HANDLE_DISCONNECT] Scheduling auto-reconnect in 5 seconds...');
      _cancelAllReconnectTimers();
      Timer? timer;
      timer = Timer(const Duration(seconds: 5), () {
        _allReconnectTimers.remove(timer!);
        print('[BLE] [HANDLE_DISCONNECT] Auto-reconnect timer fired, calling _attemptReconnectWithRetry...');
        _attemptReconnectWithRetry();
      });
      _allReconnectTimers.add(timer);
      _reconnectTimer = timer;
    } else {
      print('[BLE] [HANDLE_DISCONNECT] ⚠️ Skip auto-reconnect: _lastDeviceId=$_lastDeviceId, _reconnectLock=$_reconnectLock');
    }
  }

  /// Attempt reconnect với retry logic - hợp nhất thành 1 pipeline
  void _attemptReconnectWithRetry({int attempt = 1, int maxAttempts = 3}) async {
    // QUAN TRỌNG: Global reconnect lock - chỉ cho phép 1 reconnect task chạy
    if (_reconnectLock) {
      print('[BLE] [AUTO_RECONNECT] ⚠️ Reconnect lock active, skipping duplicate reconnect');
      return;
    }
    
    print('[BLE] [AUTO_RECONNECT] Attempt $attempt/$maxAttempts started');
    print('[BLE] [AUTO_RECONNECT] State check: _isConnected=$_isConnected, _isConnecting=$_isConnecting, _isSettingUp=$_isSettingUp, _lastDeviceId=$_lastDeviceId');
    
    // Kiểm tra: nếu đã connected hoặc không có device ID, không reconnect
    if (_isConnected || _lastDeviceId == null) {
      print('[BLE] [AUTO_RECONNECT] ⚠️ Skip reconnect - already connected or no device ID');
      return;
    }

    // Set reconnect lock
    _reconnectLock = true;
    
    // Update reconnect attempt for UI
    _reconnectAttempt = attempt;
    _reconnectStatusController.add('Đang kết nối lại (Lần $attempt/$maxAttempts)...');

    try {
      // Tăng thời gian scan mỗi lần retry: 10s, 15s, 20s
      final scanDuration = 10 + (attempt - 1) * 5;
      print('[BLE] [AUTO_RECONNECT] 🔄 Auto-reconnect attempt $attempt/$maxAttempts (scan: ${scanDuration}s)');
      
      // Force cleanup trước khi reconnect
      print('[BLE] [AUTO_RECONNECT] Calling force disconnect...');
      await _forceDisconnectAllDevices(_lastDeviceId, _lastDeviceName);
      print('[BLE] [AUTO_RECONNECT] Force disconnect completed');
      
      // Thử reconnect bằng ID trước
      print('[BLE] [AUTO_RECONNECT] Attempting reconnect by ID...');
      bool success = await _reconnectById(scanDurationSeconds: scanDuration);
      
      // Nếu fail, fallback về scan by name
      if (!success && _lastDeviceName != null && attempt >= maxAttempts) {
        print('[BLE] [AUTO_RECONNECT] Reconnect by ID failed, falling back to scan by name...');
        _reconnectStatusController.add('Đang thử kết nối bằng tên thiết bị...');
        success = await _scanAndConnectByName(_lastDeviceName!);
      }
      
      if (success) {
        print('[BLE] [AUTO_RECONNECT] ✓ Auto-reconnect thành công!');
        _reconnectAttempt = 0;
        _reconnectStatusController.add('');
        _reconnectLock = false; // Release lock
        _isConnecting = false; // Reset connecting flag
        _isSettingUp = false; // Reset setup flag
        return;
      } else {
        throw Exception('Reconnect failed');
      }
    } catch (e) {
      print('[BLE] [AUTO_RECONNECT] ⚠️ Reconnect attempt $attempt failed: $e');
      
      // Retry với thời gian scan dài hơn
      if (attempt < maxAttempts) {
        final nextAttempt = attempt + 1;
        final delaySeconds = 2 * attempt; // Exponential backoff: 2s, 4s, 6s
        print('[BLE] [AUTO_RECONNECT] Scheduling next attempt in ${delaySeconds}s...');
        _reconnectStatusController.add('Kết nối thất bại. Thử lại sau ${delaySeconds}s (Lần $nextAttempt/$maxAttempts)...');
        _reconnectLock = false; // Release lock trước khi schedule retry
        _cancelAllReconnectTimers();
        Timer? timer;
        timer = Timer(Duration(seconds: delaySeconds), () {
          _allReconnectTimers.remove(timer!);
          _attemptReconnectWithRetry(attempt: nextAttempt, maxAttempts: maxAttempts);
        });
        _allReconnectTimers.add(timer);
        _reconnectTimer = timer;
      } else {
        // Hết retry
        print('[BLE] [AUTO_RECONNECT] ⚠️ All reconnect attempts failed');
        _reconnectStatusController.add('Không thể kết nối. Vui lòng kiểm tra thiết bị.');
        _reconnectAttempt = 0;
        _reconnectLock = false; // Release lock
      }
    }
  }
  
  /// Reconnect bằng device ID (quick reconnect)
  Future<bool> _reconnectById({int scanDurationSeconds = 10}) async {
    if (_lastDeviceId == null) return false;
    
    try {
      _isConnecting = true;
      _reconnectStatusController.add('Đang quét thiết bị...');
      
      // Check Bluetooth adapter
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Bluetooth adapter is not on');
      }

      // Scan và tìm device
      // QUAN TRỌNG: Subscribe scanResults TRƯỚC khi start scan để không miss devices
      print('[BLE] [RECONNECT_ID] Scanning for device ID: $_lastDeviceId');
      BluetoothDevice? foundDevice;
      final completer = Completer<BluetoothDevice?>();
      
      // Subscribe scanResults TRƯỚC khi start scan
      final scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final scanResult in results) {
          if (scanResult.device.remoteId.toString() == _lastDeviceId) {
            if (!completer.isCompleted) {
              completer.complete(scanResult.device);
              print('[BLE] [RECONNECT_ID] ✓ Device found in scan: ${scanResult.device.platformName}');
            }
            break;
          }
        }
      });
      
      try {
        await FlutterBluePlus.startScan(timeout: Duration(seconds: scanDurationSeconds));
        print('[BLE] [RECONNECT_ID] Scan started, waiting for device...');
        
        // Đợi device xuất hiện hoặc timeout
        foundDevice = await completer.future.timeout(
          Duration(seconds: scanDurationSeconds),
          onTimeout: () {
            print('[BLE] [RECONNECT_ID] ⚠️ Scan timeout, device not found');
            return null;
          },
        );
      } finally {
        await scanSubscription.cancel();
        try {
          await FlutterBluePlus.stopScan();
        } catch (e) {
          print('[BLE] [RECONNECT_ID] Stop scan error (ignored): $e');
        }
      }
      
      if (foundDevice == null) {
        print('[BLE] [RECONNECT_ID] ⚠️ Device not found in scan');
        return false;
      }
      
      print('[BLE] [RECONNECT_ID] ✓ Device found: ${foundDevice.platformName}');
      
      // Connect
      final currentState = await foundDevice.connectionState.first;
      if (currentState != BluetoothConnectionState.disconnected) {
        await foundDevice.disconnect();
        // QUAN TRỌNG: Đợi OS cleanup sau disconnect
        await Future.delayed(const Duration(milliseconds: 1000));
      }
      
      await foundDevice.connect(timeout: const Duration(seconds: 15));
      await foundDevice.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 15));
      
      print('[BLE] [RECONNECT_ID] ✓ Connected');
      _reconnectStatusController.add('Đang thiết lập kết nối...');
      
      // Setup device
      await _setupDeviceAfterConnection(foundDevice);
      
      // QUAN TRỌNG: Chỉ reset _isConnecting khi success
      // KHÔNG reset khi fail để giữ reconnect lock
      _isConnecting = false;
      return true;
    } catch (e) {
      print('[BLE] [RECONNECT_ID] ⚠️ Error: $e');
      // QUAN TRỌNG: KHÔNG reset _isConnecting khi fail
      // Để giữ reconnect lock và tránh race condition
      return false;
    }
  }
  
  /// Scan và connect bằng device name (fallback)
  Future<bool> _scanAndConnectByName(String deviceName) async {
    try {
      _isConnecting = true;
      
      // Use connectToDevice which handles scanning by name
      final success = await connectToDevice(deviceName, maxRetries: 1);
      _isConnecting = false;
      return success;
    } catch (e) {
      print('[BLE] [SCAN_CONNECT_NAME] ⚠️ Error: $e');
      _isConnecting = false;
      return false;
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
              '- Tên thiết bị chính xác: "AgriBeacon DRONE"\n'
              '- Thử tắt/bật Bluetooth');
        }

        // Force disconnect tất cả devices có cùng ID/name để cleanup stale connections từ app khác
        print('[BLE] [CONNECT] Retry $retryCount: Calling force disconnect...');
        await _forceDisconnectAllDevices(foundDevice!.remoteId.toString(), deviceName);
        print('[BLE] [CONNECT] Retry $retryCount: Force disconnect completed');

        // Disconnect device first if it was previously connected (clean state)
        // Double check sau khi force disconnect
        try {
          final connectionState = await foundDevice!.connectionState.first;
          print('[BLE] [CONNECT] Retry $retryCount: Device state after force disconnect: $connectionState');
          if (connectionState == BluetoothConnectionState.connected) {
            print('[BLE] [CONNECT] Retry $retryCount: ⚠️ Device still connected after force disconnect, disconnecting...');
            await foundDevice!.disconnect();
            await foundDevice!.connectionState
                .where((state) => state == BluetoothConnectionState.disconnected)
                .first
                .timeout(const Duration(seconds: 5));
            print('[BLE] [CONNECT] Retry $retryCount: ✓ Device disconnected');
            // Đợi thêm để OS cleanup hoàn toàn
            await Future.delayed(const Duration(milliseconds: 500));
          } else {
            print('[BLE] [CONNECT] Retry $retryCount: Device state is $connectionState, không cần disconnect');
          }
        } catch (e) {
          print('[BLE] [CONNECT] Retry $retryCount: ⚠️ Error checking/disconnecting: $e');
          // Try to disconnect anyway
          try {
            await foundDevice!.disconnect();
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e2) {
            print('[BLE] [CONNECT] Retry $retryCount: Disconnect error (ignored): $e2');
          }
        }

        // Connect to the device with retry
        print('[BLE] [CONNECT] Retry $retryCount: Bắt đầu connect với timeout 30s...');
        try {
          // Try with autoConnect first (more reliable on Android)
          await foundDevice!.connect(
            timeout: const Duration(seconds: 30),
            autoConnect: true,
            mtu: 512,
          );
          print('[BLE] [CONNECT] Retry $retryCount: Connect command sent');
        } on fbp.FlutterBluePlusException catch (e) {
          print('[BLE] [CONNECT] Retry $retryCount: ⚠️ FlutterBluePlusException: $e');
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
        print('[BLE] [CONNECT] Retry $retryCount: Đợi connection state = connected...');
        try {
          await foundDevice!.connectionState
              .where((state) => state == BluetoothConnectionState.connected)
              .first
              .timeout(const Duration(seconds: 10));
          print('[BLE] [CONNECT] Retry $retryCount: ✓ Connected to device: ${foundDevice!.platformName.isNotEmpty ? foundDevice!.platformName : foundDevice!.advName}');
        } catch (e) {
          print('[BLE] [CONNECT] Retry $retryCount: ⚠️ Error waiting for connected state: $e');
          // Check current state
          final currentState = await foundDevice!.connectionState.first;
          print('[BLE] [CONNECT] Retry $retryCount: Current device state: $currentState');
          if (currentState != BluetoothConnectionState.connected) {
            throw Exception('Connection timeout: device state is $currentState');
          }
        }
        
        // Request MTU ngay lập tức (không đợi) - optimize speed
        print('[BLE] [CONNECT] Retry $retryCount: Requesting MTU...');
        try {
          await foundDevice!.requestMtu(517).timeout(const Duration(seconds: 2));
          print('[BLE] [CONNECT] Retry $retryCount: ✓ MTU requested');
        } catch (e) {
          print('[BLE] [CONNECT] Retry $retryCount: ⚠️ MTU error (ignored): $e');
          // Ignore MTU errors - continue anyway
        }

        // Discover services
        print('[BLE] [CONNECT] Retry $retryCount: Discovering services...');
        List<BluetoothService> services = await foundDevice!.discoverServices().timeout(const Duration(seconds: 10));
        print('[BLE] [CONNECT] Retry $retryCount: ✓ Discovered ${services.length} service(s)');
        
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
        _currentDeviceForListener = foundDevice; // Lưu device reference cho listener
        
        // Reset connecting flag TRƯỚC KHI set connected
        _isConnecting = false;
        _isConnected = true;
        
        print('[BLE] [CONNECT] Retry $retryCount: ✓ Connected to device: $_deviceName');
        print('[BLE] [CONNECT] Retry $retryCount: Calling _setupDeviceAfterConnection() to complete setup...');
        
        // QUAN TRỌNG: KHÔNG setup state listener ở đây!
        // State listener sẽ được setup trong _setupDeviceAfterConnection() SAU KHI setup hoàn tất
        // Điều này tránh race condition khi state thay đổi trong lúc discover services
        
        // Cancel subscription cũ nếu có (nhưng không setup mới)
        _connectionStateSubscription?.cancel();
        _connectionStateSubscription = null;
        _stateDebounceTimer?.cancel();
        _lastState = null;
        
        // Gọi _setupDeviceAfterConnection để setup state listener và start listening
        // _setupDeviceAfterConnection sẽ:
        // 1. Skip discovery nếu đã có characteristic
        // 2. Setup state listener SAU KHI discovery xong
        // 3. Start listening SAU KHI setup listener xong (QUAN TRỌNG: không được gọi trước discovery)
        await _setupDeviceAfterConnection(foundDevice!);
        
        _connectionStatusController.add(true);
        _reconnectAttempt = 0;
        _reconnectStatusController.add('');
        
        print('[BLE] [CONNECT] Retry $retryCount: ✓ Setup completed successfully');

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
      print('[BLE] [LISTEN] Already listening, skipping duplicate enable');
      return;
    }

    if (!_characteristic!.properties.notify && !_characteristic!.properties.indicate) {
      throw Exception('Characteristic không hỗ trợ thông báo (notify/indicate)');
    }

    try {
      // QUAN TRỌNG: Đơn giản hóa - luôn enable notify, bỏ qua error nếu đã enabled
      // read() CCCD có thể fail trên một số devices, không reliable
      if (_characteristic!.properties.notify) {
        try {
          await _withGattRetry(() => _characteristic!.setNotifyValue(true));
          await _writeCccdForCharacteristic(_characteristic!);
        } on fbp.FlutterBluePlusException catch (e) {
          // Ignore "already enabled" errors
          if (!e.toString().contains('already') && !e.toString().contains('133')) {
            rethrow;
          }
          print('[BLE] [LISTEN] Notify already enabled or GATT error (ignored): $e');
        }
      } else if (_characteristic!.properties.indicate) {
        try {
          await _withGattRetry(() => _characteristic!.setNotifyValue(true)); // Same API for indicate
          await _writeCccdForCharacteristic(_characteristic!);
        } on fbp.FlutterBluePlusException catch (e) {
          // Ignore "already enabled" errors
          if (!e.toString().contains('already') && !e.toString().contains('133')) {
            rethrow;
          }
          print('[BLE] [LISTEN] Indicate already enabled or GATT error (ignored): $e');
        }
      }
      
      _isListening = true;
      
      // Listen for incoming data
      _valueSubscription = _characteristic!.onValueReceived.listen(
        (data) {
          if (data.isNotEmpty) {
            _processMessage(data);
          }
        },
        onError: (error) {
          print('[BLE] [LISTEN] Stream error: $error');
          // ✅ Reset connection state khi stream error
          _isListening = false;
          // Chỉ reset connection nếu thực sự đang connected
          if (_isConnected) {
            _isConnected = false;
            _connectionStatusController.add(false);
            // Schedule disconnect handling
            Future.delayed(const Duration(milliseconds: 100), () {
              _handleDisconnection();
            });
          }
        },
        onDone: () {
          print('[BLE] [LISTEN] Stream done');
          _isListening = false;
          // Chỉ reset connection nếu thực sự đang connected
          if (_isConnected) {
            _isConnected = false;
            _connectionStatusController.add(false);
            // Schedule disconnect handling
            Future.delayed(const Duration(milliseconds: 100), () {
              _handleDisconnection();
            });
          }
        },
      );
    } catch (e) {
      _isListening = false;
      // ✅ Propagate error để caller biết notify fail
      print('[BLE] [LISTEN] ⚠️ Failed to enable notify: $e');
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
    // Cancel tất cả reconnect timers để cleanup memory leaks
    _cancelAllReconnectTimers();
    _stateDebounceTimer?.cancel();
    _stateDebounceTimer = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _stopConnectionHealthCheck();
    stopListening();
    _valueSubscription?.cancel();
    _connectionStatusController.close();
    _reconnectStatusController.close();
  }

  /// Start connection health check để verify connection
  void _startConnectionHealthCheck() {
    _stopConnectionHealthCheck(); // Stop existing timer if any
    
    print('[BLE] [HEALTH_CHECK] Starting connection health check...');
    _connectionHealthCheckTimer = Timer.periodic(
      const Duration(seconds: 5),
      (timer) async {
        if (!_isConnected || _connectedDevice == null) {
          print('[BLE] [HEALTH_CHECK] Skip - not connected');
          return;
        }
        
        try {
          // ✅ Verify device vẫn connected
          final state = await _connectedDevice!.connectionState.first
              .timeout(const Duration(seconds: 2));
          
          if (state != BluetoothConnectionState.connected) {
            print('[BLE] [HEALTH_CHECK] ⚠️ Health check failed: device disconnected (state: $state)');
            _handleDisconnection();
          } else {
            print('[BLE] [HEALTH_CHECK] ✓ Connection healthy');
          }
        } catch (e) {
          print('[BLE] [HEALTH_CHECK] ⚠️ Health check error: $e');
          _handleDisconnection();
        }
      },
    );
  }

  /// Stop connection health check
  void _stopConnectionHealthCheck() {
    if (_connectionHealthCheckTimer != null) {
      print('[BLE] [HEALTH_CHECK] Stopping connection health check...');
      _connectionHealthCheckTimer?.cancel();
      _connectionHealthCheckTimer = null;
    }
  }
}


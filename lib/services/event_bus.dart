import 'dart:async';

/// Event types for BLE messages
class BleHomeEvent {
  final String data;
  BleHomeEvent(this.data);
}

class BleWpEvent {
  final String data;
  BleWpEvent(this.data);
}

class BleStatusEvent {
  final String data;
  final bool isReady;
  BleStatusEvent(this.data, {bool? isReady}) 
      : isReady = isReady ?? (data == '1');
}

class BleBatteryEvent {
  final String data;
  BleBatteryEvent(this.data);
}

class BleEfkEvent {
  final String data;
  BleEfkEvent(this.data);
}

class BleRawMessageEvent {
  final String message;
  BleRawMessageEvent(this.message);
}

/// Simple Event Bus implementation
class EventBus {
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;
  EventBus._internal();

  // Stream controllers for each event type
  final _homeEventController = StreamController<BleHomeEvent>.broadcast();
  final _wpEventController = StreamController<BleWpEvent>.broadcast();
  final _statusEventController = StreamController<BleStatusEvent>.broadcast();
  final _batteryEventController = StreamController<BleBatteryEvent>.broadcast();
  final _ekfEventController = StreamController<BleEfkEvent>.broadcast();
  final _rawMessageEventController = StreamController<BleRawMessageEvent>.broadcast();

  // Public streams
  Stream<BleHomeEvent> get onHome => _homeEventController.stream;
  Stream<BleWpEvent> get onWp => _wpEventController.stream;
  Stream<BleStatusEvent> get onStatus => _statusEventController.stream;
  Stream<BleBatteryEvent> get onBattery => _batteryEventController.stream;
  Stream<BleEfkEvent> get onEfk => _ekfEventController.stream;
  Stream<BleRawMessageEvent> get onRawMessage => _rawMessageEventController.stream;

  /// Emit HOME event
  void emitHome(String data) {
    _homeEventController.add(BleHomeEvent(data));
  }

  /// Emit WP event
  void emitWp(String data) {
    _wpEventController.add(BleWpEvent(data));
  }

  /// Emit STATUS event
  void emitStatus(String data) {
    _statusEventController.add(BleStatusEvent(data));
  }

  /// Emit BATTERY event
  void emitBattery(String data) {
    _batteryEventController.add(BleBatteryEvent(data));
  }

  /// Emit EKF event
  void emitEfk(String data) {
    _ekfEventController.add(BleEfkEvent(data));
  }

  /// Emit raw message event
  void emitRawMessage(String message) {
    _rawMessageEventController.add(BleRawMessageEvent(message));
  }

  void dispose() {
    _homeEventController.close();
    _wpEventController.close();
    _statusEventController.close();
    _batteryEventController.close();
    _ekfEventController.close();
    _rawMessageEventController.close();
  }
}


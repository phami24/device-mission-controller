import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/path_generator.dart';
import '../services/ble_service.dart';
import '../services/event_bus.dart';

// ============================================================================
// Mission Progress Dialog Widget - Hiển thị tiến độ nhiệm vụ với StreamSubscription
// ============================================================================
class _MissionProgressDialog extends StatefulWidget {
  final int wpDone;
  final int wpTotal;
  final DateTime? dialogOpenTime;
  final bool forceLoading;
  final EventBus eventBus;
  final VoidCallback onClose;

  const _MissionProgressDialog({
    required this.wpDone,
    required this.wpTotal,
    required this.dialogOpenTime,
    required this.forceLoading,
    required this.eventBus,
    required this.onClose,
  });

  @override
  State<_MissionProgressDialog> createState() => _MissionProgressDialogState();
}

class _MissionProgressDialogState extends State<_MissionProgressDialog> {
  int _wpDone = 0;
  int _wpTotal = 0;
  StreamSubscription<BleWpEvent>? _wpSubscription;
  Timer? _closeTimer;

  @override
  void initState() {
    super.initState();
    _wpDone = widget.wpDone;
    _wpTotal = widget.wpTotal;
    
    // Listen to WP events via StreamSubscription
    _wpSubscription = widget.eventBus.onWp.listen((event) {
      final raw = event.data.trim();
      final text = raw.contains(':') ? raw.split(':').last : raw;
      final parts = text.split('/');
      
      if (parts.length == 2) {
        final a = int.tryParse(parts[0].trim()) ?? 0;
        final b = int.tryParse(parts[1].trim()) ?? 0;
        
        setState(() {
          _wpDone = a.clamp(0, b);
          _wpTotal = b;
        });
        
        // Trường hợp 0/0: đợi 3s rồi đóng
        if (a == 0 && b == 0) {
          _closeTimer?.cancel();
          _closeTimer = Timer(const Duration(seconds: 3), () {
            if (mounted && _wpDone == 0 && _wpTotal == 0) {
              // Đóng dialog trước, sau đó cập nhật state
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop(); // Đóng dialog
              }
              // Cập nhật state sau khi đóng dialog
              widget.onClose();
            }
          });
        }
        
        // Khi hoàn thành (a == b > 0): đợi 1s rồi đóng (sau khi đã mở ít nhất 3s)
        if (_wpDone == _wpTotal && _wpTotal > 0) {
          final bool dialogOpenedLongEnough = widget.dialogOpenTime != null && 
              DateTime.now().difference(widget.dialogOpenTime!).inSeconds >= 3;
          
          if (dialogOpenedLongEnough) {
            _closeTimer?.cancel();
            _closeTimer = Timer(const Duration(seconds: 1), () {
              if (mounted && _wpDone == _wpTotal && _wpTotal > 0) {
                // Đóng dialog trước, sau đó cập nhật state
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop(); // Đóng dialog
                }
                // Cập nhật state sau khi đóng dialog
                widget.onClose();
              }
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _wpSubscription?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Tính toán display values
    final bool hasProgress = _wpTotal > _wpDone && _wpTotal > 0;
    final bool showLoading = widget.dialogOpenTime != null && 
        DateTime.now().difference(widget.dialogOpenTime!).inSeconds < 3 &&
        !hasProgress;
    
    final bool isComplete = (_wpTotal > 0) && (_wpDone == _wpTotal);
    final bool forceLoading = widget.forceLoading && (_wpDone == _wpTotal);
    final int displayDone = showLoading ? 0 : _wpDone;
    final int displayTotal = showLoading ? 0 : (forceLoading ? _wpTotal : _wpTotal);
    final progress = (displayTotal > 0) ? (displayDone / displayTotal).clamp(0.0, 1.0) : 0.0;
    
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      title: const Row(
        children: [
          Icon(Icons.flight, color: Color(0xff2e7d32)),
          SizedBox(width: 8),
          Text('Tiến độ nhiệm vụ'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Hiển thị loading trong 3s đầu, sau đó hiển thị giá trị wp
          if (showLoading) ...[
            const SizedBox(
              width: 120,
              height: 120,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 8,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xff2e7d32)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Đang tải...',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade700,
              ),
            ),
          ] else ...[
            // a/b ở trên cùng
            Text(
              '$displayDone/$displayTotal',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xff2e7d32),
              ),
            ),
            const SizedBox(height: 12),
            // Circular progress indicator
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 8,
                    backgroundColor: Colors.grey.shade300,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xff2e7d32)),
                  ),
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              forceLoading
                  ? 'Đang tải đường bay lên...'
                  : (isComplete ? 'Hoàn thành!' : 'Đang tải đường bay lên...'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ],
      ),
      actions: [
        // Close button (only show when done)
        if (_wpDone == _wpTotal && _wpTotal > 0)
          TextButton(
            onPressed: () {
              widget.onClose();
              Navigator.of(context).pop();
            },
            child: const Text('Đóng'),
          ),
      ],
    );
  }
}

// ============================================================================
// Compass Arrow Widget - Hiển thị la bàn với vòng ngoài cố định và vòng trong xoay
// ============================================================================
class CompassArrow extends StatelessWidget {
  /// Bearing angle in degrees (góc xoay của vòng trong)
  final double bearingDeg;
  /// Highlight north direction (tô sáng hướng bắc)
  final bool highlightNorth;
  
  const CompassArrow({
    super.key,
    required this.bearingDeg,
    this.highlightNorth = true,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            children: [
              // Outer ring (fixed) - geo_north (vòng lớn bên ngoài, đứng yên) - viền hồng
              Image.asset(
                'lib/assets/nautical_compass_rose_geo_north.png',
                width: size,
                height: size,
                fit: BoxFit.contain,
              ),
              // Inner ring (rotating) - mag_north (vòng nhỏ bên trong, xoay theo bearing)
              Transform.rotate(
                angle: bearingDeg * math.pi / 180.0,
                alignment: Alignment.center,
                child: Image.asset(
                  'lib/assets/nautical_compass_rose_mag_north.png',
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================================
// Undo State Class - Lưu trữ state để hoàn tác
// ============================================================================
class _UndoState {
  final List<LatLng> points;
  final List<List<LatLng>> acceptedPolygons;
  final List<LatLng> waypoints;
  final List<LatLng> waypointPath;
  final bool hasWaypoints;
  
  _UndoState({
    required this.points,
    required this.acceptedPolygons,
    required this.waypoints,
    required this.waypointPath,
    required this.hasWaypoints,
  });
}

// Custom draggable marker widget
class _DraggableMarker extends Marker {
  _DraggableMarker({
    required LatLng point,
    required int index,
    required Function(int, LatLng) onDragEnd,
    required MapController mapController,
    required bool disabled,
    required bool isDeleteMode,
    VoidCallback? onDragStart,
    VoidCallback? onDragEndCallback,
    Function(int)? onTap,
  }) : super(
          point: point,
          width: 28, // Tăng kích thước để dễ kéo thả
          height: 28,
          child: _DraggableMarkerWidget(
            point: point,
            index: index,
            onDragEnd: onDragEnd,
            mapController: mapController,
            disabled: disabled,
            isDeleteMode: isDeleteMode,
            onDragStart: onDragStart,
            onDragEndCallback: onDragEndCallback,
            onTap: onTap,
          ),
        );
}

class _DraggableMarkerWidget extends StatefulWidget {
  final LatLng point;
  final int index;
  final Function(int, LatLng) onDragEnd;
  final MapController mapController;
  final bool disabled;
  final bool isDeleteMode;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEndCallback;
  final Function(int)? onTap;

  const _DraggableMarkerWidget({
    required this.point,
    required this.index,
    required this.onDragEnd,
    required this.mapController,
    required this.disabled,
    required this.isDeleteMode,
    this.onDragStart,
    this.onDragEndCallback,
    this.onTap,
  });

  @override
  State<_DraggableMarkerWidget> createState() => _DraggableMarkerWidgetState();
}

class _DraggableMarkerWidgetState extends State<_DraggableMarkerWidget> {
  bool _isDragging = false;
  bool _isPressed = false; // Track khi nhấn vào marker
  LatLng? _dragStartPoint; // Lưu vị trí ban đầu khi bắt đầu drag
  Offset? _pointerStartPosition; // Lưu vị trí pointer ban đầu
  bool _hasMoved = false; // Track xem đã move chưa để phân biệt tap và drag
  bool _isTapped = false; // Track khi tap (để block map tap ngay lập tức)

  @override
  Widget build(BuildContext context) {
    if (widget.disabled) {
      return Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: const Color(0xffe53935),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white,
            width: 2,
          ),
        ),
      );
    }
    
    return Listener(
      onPointerDown: (event) {
        setState(() {
          _isPressed = true;
          _isDragging = false; // Chưa drag, chờ move
          _hasMoved = false; // Reset flag move
          _isTapped = true; // Đánh dấu đã tap (để block map tap ngay lập tức)
          _pointerStartPosition = event.position;
          _dragStartPoint = widget.point; // Lưu vị trí ban đầu
        });
        // Notify parent để block map tap ngay khi tap vào marker
        widget.onDragStart?.call();
      },
      onPointerMove: (event) {
        if (_pointerStartPosition == null || _dragStartPoint == null) return;
        // Block drag khi đang ở chế độ xóa
        if (widget.isDeleteMode) return;
        
        // Tính khoảng cách di chuyển từ vị trí ban đầu
        final dx = event.position.dx - _pointerStartPosition!.dx;
        final dy = event.position.dy - _pointerStartPosition!.dy;
        final distance = math.sqrt(dx * dx + dy * dy);
        
        // Nếu move quá 5px thì coi là drag
        if (distance > 5.0) {
          if (!_hasMoved) {
            // Lần đầu move: bắt đầu drag
            setState(() {
              _isDragging = true;
              _hasMoved = true;
              _isTapped = false; // Không phải tap nữa, là drag
            });
          }
          
          // Get map camera
          final camera = widget.mapController.camera;
          final zoom = camera.zoom;
          
          // Dùng delta từ event để mượt hơn (delta từ lần move trước)
          final deltaX = event.delta.dx;
          final deltaY = event.delta.dy;
          
          // Convert pixel offset to lat/lng offset using Web Mercator projection
          final metersPerPixel = 156543.03392 * math.cos(_dragStartPoint!.latitude * math.pi / 180) / math.pow(2, zoom);
          
          // Convert meters to degrees
          final metersPerDegreeLat = 111320.0;
          final metersPerDegreeLng = 111320.0 * math.cos(_dragStartPoint!.latitude * math.pi / 180);
          
          // Calculate offset from pointer delta
          final latOffset = -deltaY * metersPerPixel / metersPerDegreeLat;
          final lngOffset = deltaX * metersPerPixel / metersPerDegreeLng;
          
          // Cập nhật vị trí ban đầu để tính toán tiếp theo dựa trên vị trí hiện tại
          final newLat = _dragStartPoint!.latitude + latOffset;
          final newLng = _dragStartPoint!.longitude + lngOffset;
          
          // Clamp to valid lat/lng range
          final clampedLat = newLat.clamp(-90.0, 90.0);
          final clampedLng = newLng.clamp(-180.0, 180.0);
          
          final newPosition = LatLng(clampedLat, clampedLng);
          
          // Cập nhật _dragStartPoint để lần move tiếp theo tính từ vị trí mới
          _dragStartPoint = newPosition;
          _pointerStartPosition = event.position;
          
          // Update position immediately during drag
          widget.onDragEnd(widget.index, newPosition);
        }
      },
      onPointerUp: (event) {
        final wasTap = !_hasMoved && _isTapped;
        
        setState(() {
          _isPressed = false;
          _isDragging = false;
          _hasMoved = false;
          _isTapped = false;
          _pointerStartPosition = null;
          _dragStartPoint = null;
        });
        
        // Nếu không move (tap) thì gọi onTap
        if (wasTap && widget.onTap != null) {
          widget.onTap!(widget.index);
        }
        
        // Notify parent để enable lại map interaction
        widget.onDragEndCallback?.call();
      },
      onPointerCancel: (event) {
        setState(() {
          _isPressed = false;
          _isDragging = false;
          _hasMoved = false;
          _isTapped = false;
          _pointerStartPosition = null;
          _dragStartPoint = null;
        });
        // Notify parent để enable lại map interaction
        widget.onDragEndCallback?.call();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Vô hiệu hóa long press để tránh xóa điểm khi giữ lâu
        onLongPress: () {
          // Không làm gì, vô hiệu hóa long press
        },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: _isDragging ? 32 : (_isPressed ? 28 : 24), // Scale up khi drag hoặc press
        height: _isDragging ? 32 : (_isPressed ? 28 : 24),
        transform: Matrix4.identity()..scale(_isDragging ? 1.3 : (_isPressed ? 1.15 : 1.0)), // Scale animation
        decoration: BoxDecoration(
          color: _isDragging 
              ? Colors.orange // Đổi màu khi đang drag
              : (_isPressed 
                  ? const Color(0xffe53935).withValues(alpha: 0.8) // Đổi màu khi nhấn
                  : const Color(0xffe53935)),
          shape: BoxShape.circle,
          border: Border.all(
            color: _isDragging ? Colors.orange : Colors.white,
            width: _isDragging ? 3 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: _isDragging 
                  ? Colors.orange.withValues(alpha: 0.5)
                  : Colors.black.withValues(alpha: 0.3),
              blurRadius: _isDragging ? 12 : (_isPressed ? 6 : 3),
              offset: Offset(0, _isDragging ? 6 : (_isPressed ? 3 : 2)),
            ),
          ],
        ),
        child: _isDragging 
            ? const Icon(Icons.drag_handle, color: Colors.white, size: 16)
            : null, // Hiển thị icon khi đang drag
      ),
      ),
    );
  }
}

class _ZeroDegreeIndicatorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.75 / 2 + 10;
    final rad = (-90) * math.pi / 180.0; // top
    final sx = center.dx + math.cos(rad) * (radius - 22);
    final sy = center.dy + math.sin(rad) * (radius - 22);
    final ex = center.dx + math.cos(rad) * (radius + 8);
    final ey = center.dy + math.sin(rad) * (radius + 8);
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(sx, sy), Offset(ex, ey), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class CompassScreen extends StatefulWidget {
  const CompassScreen({super.key});

  @override
  State<CompassScreen> createState() => _CompassScreenState();
}

class _CompassScreenState extends State<CompassScreen> {
  final MapController _mapController = MapController();
  final PathGenerator _pathGenerator = PathGenerator();

  // Drawing state
  final List<LatLng> _points = [];
  final List<List<LatLng>> _acceptedPolygons = []; // Store multiple accepted polygons
  LatLng _center = const LatLng(21.002937374996904, 105.73366074425239);
  double _zoom = 18.0;
  bool _isDrawingMode = true;
  bool _isDraggingMarker = false; // Track khi đang drag marker để disable map interaction
  bool _hasSavedDragState = false; // Track xem đã lưu state cho lần drag hiện tại chưa
  
  // Undo history
  final List<_UndoState> _undoHistory = [];

  // Bearing control
  bool _showBearing = false;
  double _bearingDeg = 0.0; // Can be any value for rotation, but normalized to -180..180 for display/upload
  Offset? _compassPanStartPosition; // Lưu vị trí ban đầu khi bắt đầu pan la bàn

  // Altitude control
  double _altitude = 10.0; // meters, range 5.5 .. 100

  // Waypoints
  List<LatLng> _waypoints = [];
  List<LatLng> _waypointPath = [];
  bool _hasWaypoints = false; // Track if waypoints have been generated
  
  // Delete mode (toggle ON/OFF để xóa từng điểm)
  bool _isDeleteMode = false; // Chế độ xóa ON/OFF
  
  // Home point comes from BLE HOME event only
  LatLng? _selectedHomePoint;
  bool _hasFocusedHome = false; // Track xem đã focus HOME lần đầu chưa

  // Floating button bar state
  bool _isFloatingBarExpanded = true;
  
  // Map key to force rebuild on orientation change
  final GlobalKey _mapKey = GlobalKey();

  // BLE connection state
  final BleService _bleService = BleService();
  bool _isBleConnected = false;
  String _reconnectStatus = ''; // Status message for reconnect attempts
  StreamSubscription<bool>? _bleConnectionSubscription;
  StreamSubscription<String>? _reconnectStatusSubscription;
  Timer? _bleReconnectTimer;
  
  // BLE message subscriptions via EventBus (backward compatible)
  // Can also use: _bleService.on.on("HOME", (data) => ...) for clean pattern
  final EventBus _eventBus = EventBus();
  StreamSubscription<BleHomeEvent>? _homeEventSubscription;
  StreamSubscription<BleWpEvent>? _wpEventSubscription;
  StreamSubscription<BleStatusEvent>? _statusEventSubscription;
  
  // Mission progress
  int _wpDone = 0;
  int _wpTotal = 0;
  bool _isMissionDialogOpen = false;
  bool _forceLoading = false; // Ép dialog hiển thị loading dù a==b
  DateTime? _dialogOpenTime; // Thời gian mở dialog để tính loading 3s
  Timer? _wpDialogTimer; // Timer để đóng dialog sau 3s nếu 0/0
  
  // Delete dialog state
  bool _isDeleteDialogOpen = false; // Track khi dialog xóa đang mở

  // Status: 0 = chưa sẵn sàng, 1 = sẵn sàng
  int _status = 0; // Lưu status từ BLE để hiển thị chấm trạng thái

  // Compass drag state (deprecated: using joystick knob)

  @override
  void initState() {
    super.initState();
    
    // Check initial BLE connection status
    _isBleConnected = _bleService.isConnected;
    
    // Listen to BLE connection status changes
    _bleConnectionSubscription = _bleService.connectionStatus.listen((isConnected) {
      if (mounted) {
        setState(() {
          _isBleConnected = isConnected;
        });
      }
    });
    
    // Listen to reconnect status (reconnect attempts)
    _reconnectStatusSubscription = _bleService.reconnectStatus.listen((status) {
      if (mounted) {
        setState(() {
          _reconnectStatus = status;
        });
      }
    });

    // Periodically check BLE and reconnect to AgriBeacon BLE every 3s if disconnected
    // Note: BLE service tự động reconnect, timer này chỉ backup nếu service reconnect fail
    _bleReconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) return;
      // Chỉ reconnect nếu thực sự disconnected và không đang reconnect
      // BLE service sẽ tự động reconnect, timer này chỉ backup
      if (!_bleService.isConnected && !_bleService.isConnecting) {
        try {
          await _connectBle();
        } catch (_) {}
      }
    });
    
    // Subscribe to BLE messages
    _subscribeToBleMessages();
    // Auto connect BLE now
    _connectBle();
    // Set landscape orientation immediately when entering compass screen
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    // Force map to render properly on mobile after orientation change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Wait for orientation change to complete
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          // Force map to recalculate size after orientation change
          setState(() {
            // Trigger rebuild to ensure map renders properly on mobile
          });
        }
      });
    });
  }

  Future<void> _connectBle() async {
    if (_isBleConnected) return;
    // show header text while connecting; no extra overlay state
    try {
      await _bleService.connectToDevice('AgriBeacon BLE');
    } catch (_) {
      // BleService may retry internally
    } finally {
      if (mounted) setState(() {});
    }
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Force map to recalculate when orientation changes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          setState(() {
            // Force map rebuild on mobile
          });
        }
      });
    });
  }

  /// Subscribe to BLE messages via EventBus
  void _subscribeToBleMessages() {
    // Listen to HOME events
    _homeEventSubscription = _eventBus.onHome.listen((event) {
      // Handle HOME event and set as drone home/start point
      // Format: "HOME:lat_e7,lon_e7" (e.g., "HOME:133278830,108547396")
      // Parse: divide by 1e7 to get lat/lng in degrees
      final raw = event.data.trim();
      final payload = raw.contains(':') ? raw.split(':').last.trim() : raw.trim();
      final parts = payload.split(',');
      
      if (parts.length == 2) {
        LatLng? parsed;
        // Try integer E7 first (format from BLE: lat_e7,lon_e7)
        try {
          final latI = int.parse(parts[0].trim());
          final lonI = int.parse(parts[1].trim());
          // Divide by 1e7 to convert from E7 format to degrees
          final lat = latI / 1e7;
          final lon = lonI / 1e7;
          parsed = LatLng(lat, lon);
        } catch (e) {
          // Fallback to double decimal
          try {
            final latD = double.parse(parts[0].trim());
            final lonD = double.parse(parts[1].trim());
            parsed = LatLng(latD, lonD);
          } catch (_) {
            // Parse failed, ignore
          }
        }
        
        if (parsed != null && parsed.latitude.abs() <= 90 && parsed.longitude.abs() <= 180) {
          setState(() {
            _selectedHomePoint = parsed; // treat HOME as flight start point
          });
          // Chỉ center map to HOME lần đầu khi nhận được HOME, không center lại khi nhận HOME mới
          if (!_hasFocusedHome) {
            final home = parsed;
            _mapController.move(home, _zoom);
            setState(() {
              _center = home;
              _hasFocusedHome = true; // Đánh dấu đã focus HOME lần đầu
            });
          }
        }
      }
    });

    // Listen to WP events for mission progress: "x/y" or "WP:x/y"
    _wpEventSubscription = _eventBus.onWp.listen((event) {
      final raw = event.data.trim();
      final text = raw.contains(':') ? raw.split(':').last : raw;
      final parts = text.split('/');
      if (parts.length == 2) {
        final a = int.tryParse(parts[0].trim()) ?? 0;
        final b = int.tryParse(parts[1].trim()) ?? 0;
        setState(() {
          _wpDone = a.clamp(0, b);
          _wpTotal = b;
        });
        // Trường hợp 0/0: nếu dialog đang mở, dùng Timer.periodic để check và đóng sau 3s
        if (a == 0 && b == 0 && mounted) {
          if (_isMissionDialogOpen) {
            // Hủy timer cũ nếu có
            _wpDialogTimer?.cancel();
            // Tạo timer mới để check sau 3s
            _wpDialogTimer = Timer(const Duration(seconds: 3), () {
              if (!mounted) return;
              if (_wpDone == 0 && _wpTotal == 0 && _isMissionDialogOpen) {
                _hideMissionProgressDialog();
              }
            });
          }
        }
        // Khi hoàn thành (a == b > 0), chỉ xử lý đóng sau 1s nếu dialog đang mở
        // Đảm bảo đã qua 3s để tránh đóng dialog khi nhận được WP event cũ ngay sau khi upload
        if (_wpDone == _wpTotal && _wpTotal > 0 && mounted) {
          // Kiểm tra xem dialog đã mở được ít nhất 3s chưa để tránh đóng khi nhận WP event cũ
          final bool dialogOpenedLongEnough = _dialogOpenTime != null && 
              DateTime.now().difference(_dialogOpenTime!).inSeconds >= 3;
          
          if (dialogOpenedLongEnough) {
            // Sau 1s: chỉ đóng dialog (không ẩn polygon)
            Future.delayed(const Duration(seconds: 1), () {
              if (!mounted) return;
              if (_wpDone == _wpTotal && _wpTotal > 0) {
                if (_isMissionDialogOpen) {
                  _hideMissionProgressDialog();
                }
              }
            });
          }
        }
        // Khi b > a: giữ nguyên dialog mở, chỉ cập nhật progress
        // Không cần làm gì, dialog sẽ tự động cập nhật qua setState
      }
    });

    _statusEventSubscription = _eventBus.onStatus.listen((event) {
      // Parse status: 0 = chưa sẵn sàng, 1 = sẵn sàng
      final statusStr = event.data.trim();
      final statusInt = int.tryParse(statusStr) ?? 0;
      setState(() {
        _status = statusInt.clamp(0, 1);
      });
    });
  }

  @override
  void dispose() {
    _bleConnectionSubscription?.cancel();
    _reconnectStatusSubscription?.cancel();
    _bleReconnectTimer?.cancel();
    _wpDialogTimer?.cancel(); // Hủy timer dialog
    _homeEventSubscription?.cancel();
    _wpEventSubscription?.cancel();
    _statusEventSubscription?.cancel();
    super.dispose();
  }

  void _toggleCompass() {
    setState(() {
      _showBearing = !_showBearing;
      // Do not change orientation on toggle; this screen stays landscape
    });
  }

  bool _isLandscape() {
    final orientation = MediaQuery.of(context).orientation;
    return orientation == Orientation.landscape;
  }

  // Normalize bearing angle to -180..180 range
  double _normalizeBearing(double angle) {
    // Normalize to 0..360 first (handle negative values)
    angle = ((angle % 360) + 360) % 360;
    // Convert to -180..180 range
    if (angle > 180) {
      angle -= 360;
    }
    return angle;
  }

  // Get normalized bearing for display and upload (-180..180)
  double get _normalizedBearingDeg => _normalizeBearing(_bearingDeg);

  // Removed _compassRotationDeg; we rotate directly with _bearingDeg

  // Geometry helpers removed; using ordering approach instead of intersection checks

  // _segmentsIntersect removed (no longer used).

  // Note: kept intersection helpers above for potential future validation

  // Order points to form a simple polygon (approximate) by sorting around centroid
  // Loại bỏ điểm cuối nếu trùng với điểm đầu trước khi sắp xếp
  List<LatLng> _orderSimplePolygon(List<LatLng> points) {
    if (points.length < 3) return List<LatLng>.from(points);
    
    // Tạo bản sao để không thay đổi list gốc
    List<LatLng> pointsToSort = List<LatLng>.from(points);
    
    // Nếu polygon đã đóng (điểm đầu = điểm cuối), loại bỏ điểm cuối trước khi sắp xếp
    if (pointsToSort.length > 3) {
      final first = pointsToSort.first;
      final last = pointsToSort.last;
      final isClosed = (first.latitude - last.latitude).abs() < 1e-7 && 
                       (first.longitude - last.longitude).abs() < 1e-7;
      if (isClosed) {
        pointsToSort = pointsToSort.sublist(0, pointsToSort.length - 1);
      }
    }
    
    // Tính centroid
    double cx = 0, cy = 0;
    for (final p in pointsToSort) {
      cy += p.latitude;
      cx += p.longitude;
    }
    cx /= pointsToSort.length;
    cy /= pointsToSort.length;
    
    // Sắp xếp theo góc từ centroid
    final sorted = List<LatLng>.from(pointsToSort);
    sorted.sort((a, b) {
      final aa = math.atan2(a.latitude - cy, a.longitude - cx);
      final bb = math.atan2(b.latitude - cy, b.longitude - cx);
      return aa.compareTo(bb);
    });
    
    return sorted;
  }

  // Đảm bảo polygon được đóng lại (điểm đầu = điểm cuối)
  List<LatLng> _ensurePolygonClosed(List<LatLng> points) {
    if (points.length < 3) return List<LatLng>.from(points);
    
    // Tạo bản sao để không thay đổi list gốc
    final closed = List<LatLng>.from(points);
    
    // Kiểm tra xem polygon có đóng lại chưa (điểm đầu = điểm cuối)
    final first = closed.first;
    final last = closed.last;
    final isClosed = (first.latitude - last.latitude).abs() < 1e-7 && 
                     (first.longitude - last.longitude).abs() < 1e-7;
    
    // Nếu chưa đóng, thêm điểm đầu vào cuối để đóng polygon
    if (!isClosed) {
      closed.add(LatLng(first.latitude, first.longitude));
    }
    
    return closed;
  }

  // Painters for arc striped slider & 0° indicator
  // Defined below, outside of the State class.

  // Lưu state hiện tại vào history để undo
  void _saveState() {
    _undoHistory.add(_UndoState(
      points: List<LatLng>.from(_points),
      acceptedPolygons: _acceptedPolygons.map((p) => List<LatLng>.from(p)).toList(),
      waypoints: List<LatLng>.from(_waypoints),
      waypointPath: List<LatLng>.from(_waypointPath),
      hasWaypoints: _hasWaypoints,
    ));
    // Giới hạn history tối đa 50 lần
    if (_undoHistory.length > 50) {
      _undoHistory.removeAt(0);
    }
  }

  // Hoàn tác thao tác cuối cùng
  void _undo() {
    if (_undoHistory.isEmpty) {
      _showInfoDialog('Thông báo', 'Không có thao tác nào để hoàn tác');
      return;
    }
    final lastState = _undoHistory.removeLast();
    setState(() {
      _points.clear();
      _points.addAll(lastState.points);
      _acceptedPolygons.clear();
      _acceptedPolygons.addAll(lastState.acceptedPolygons.map((p) => List<LatLng>.from(p)));
      _waypoints.clear();
      _waypoints.addAll(lastState.waypoints);
      _waypointPath.clear();
      _waypointPath.addAll(lastState.waypointPath);
      _hasWaypoints = lastState.hasWaypoints;
      // Reset WP progress khi undo để tránh hiển thị giá trị cũ khi upload mới
      _wpDone = 0;
      _wpTotal = 0;
    });
  }

  void _onMapTap(TapPosition tapPosition, LatLng latlng) {
    // Disable map interaction when showing bearing
    if (_showBearing) return;
    if (!_isDrawingMode) return;
    // Only allow drawing if no polygon has been accepted yet
    if (_acceptedPolygons.isNotEmpty) return;
    // Block editing when preview is active (must undo preview first)
    if (_hasWaypoints) return;
    // Block drawing when delete dialog is open
    if (_isDeleteDialogOpen) return;
    // Block drawing when in delete mode - show notification
    if (_isDeleteMode) {
      _showInfoDialog('Thông báo', 'Đang trong chế độ xóa điểm. Hãy tắt chế độ xóa để vẽ thêm điểm.');
      return;
    }
    _saveState(); // Lưu state trước khi thêm điểm
    setState(() {
      _points.add(latlng);
    });
  }

  void _onMapLongPress(TapPosition tapPosition, LatLng latlng) {
    // Disable map interaction when showing bearing or dragging marker
    // Vô hiệu hóa long press khi đang drag marker hoặc đang nhấn vào marker
    if (_showBearing || _isDraggingMarker) return;
    // Remove last point (similar to right-click in web)
    if (!_isDrawingMode || _points.isEmpty) return;
    // Only allow editing if no polygon has been accepted yet
    if (_acceptedPolygons.isNotEmpty) return;
    // Block editing when preview is active (must undo preview first)
    if (_hasWaypoints) return;
    _saveState(); // Lưu state trước khi xóa điểm
    setState(() {
      _points.removeLast();
    });
  }

  void _onPointDrag(int index, LatLng newPosition) {
    if (_showBearing) return;
    // Only allow dragging if no polygon has been accepted yet
    if (_acceptedPolygons.isNotEmpty) return;
    // Block editing when preview is active (must undo preview first)
    if (_hasWaypoints) return;
    // Block dragging when in delete mode
    if (_isDeleteMode) return;
    // Bỏ giới hạn 1km quanh HOME khi kéo điểm
    setState(() {
      _points[index] = newPosition;
    });
  }

  

  void _clearAll() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận'),
        content: const Text('Bạn có chắc muốn xóa tất cả?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _points.clear();
                _acceptedPolygons.clear();
                _waypoints.clear();
                _waypointPath.clear();
                _hasWaypoints = false;
                _selectedHomePoint = null;
                _undoHistory.clear(); // Xóa history khi clear all
                _wpDone = 0;
                _wpTotal = 0;
                _isDeleteMode = false; // Reset delete mode khi xóa tất cả
              });
            },
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
  }


  // Preview: tạo waypoints để xem trước
  void _onPreview() {
    // Lưu state trước khi tạo preview để có thể undo
    _saveState();
    
    // Lấy polygon nguồn: nếu đã accept thì dùng polygon đã accept; nếu chưa, dùng các điểm đang vẽ
    final List<List<LatLng>> sourcePolygons = _acceptedPolygons.isNotEmpty
        ? _acceptedPolygons
        : (_points.length >= 3
            ? [
                _ensurePolygonClosed(
                  _orderSimplePolygon(List<LatLng>.from(_points)),
                )
              ]
            : []);

    if (sourcePolygons.isEmpty) {
      _showInfoDialog('Thông báo', 'Cần vẽ ít nhất 3 điểm để tạo vùng bay');
      return;
    }

    // HOME: ưu tiên HOME từ BLE; nếu chưa có thì dùng điểm đầu của polygon đầu tiên
    if (_selectedHomePoint == null) {
      final start = sourcePolygons.first.first;
      _selectedHomePoint = LatLng(start.latitude, start.longitude);
      _mapController.move(_selectedHomePoint!, _zoom);
      _center = _selectedHomePoint!;
    }

    final homePoint = _selectedHomePoint!;
    final homeE7 = {
      'lat': (homePoint.latitude * 1e7).round(),
      'lon': (homePoint.longitude * 1e7).round(),
    };

    final altitude = _altitude;
    const fovDeg = 23.0; // Fixed FOV
    final headingDeg = _normalizedBearingDeg; // Use normalized bearing (-180..180)

    // Generate waypoints for all polygons starting from home point
    final allWaypoints = <Map<String, int>>[];
    
    for (final polygon in sourcePolygons) {
      if (polygon.length < 3) continue;
      
      // Sắp xếp lại polygon theo thứ tự đúng trước khi gửi lên endpoint
      // Đảm bảo thứ tự nối đúng cho đường bay
      final orderedPolygon = _orderSimplePolygon(polygon);
      final closedPolygon = _ensurePolygonClosed(orderedPolygon);
      
      final polygonE7 = closedPolygon.map((p) => {
        'lat': (p.latitude * 1e7).round(),
        'lon': (p.longitude * 1e7).round(),
      }).toList();

      final wps = _pathGenerator.generateOptimizedPath(
        polygonE7,
        homeE7,
        altitude,
        fovDeg,
        headingDeg,
      );

      allWaypoints.addAll(wps);
    }

    if (allWaypoints.isEmpty) {
      _showInfoDialog('Thông báo', 'Không thể tạo waypoints');
      return;
    }

    setState(() {
      _waypoints = allWaypoints.map((wp) => LatLng(wp['lat']! / 1e7, wp['lon']! / 1e7)).toList();
      // Bỏ điểm cuối trong waypointPath để không vẽ line đến điểm cuối cùng
      // (markers đã bỏ điểm cuối ở line 1278, path cũng cần bỏ để đồng bộ)
      _waypointPath = _waypoints.length > 1 
          ? _waypoints.sublist(0, _waypoints.length - 1) 
          : _waypoints;
      _hasWaypoints = true; // Mark that waypoints have been generated
      _isDeleteMode = false; // Reset delete mode khi preview (nút sẽ tự ẩn)
    });

    // Log waypoints (similar to web version)
    final outLines = allWaypoints.map((wp) => '${wp['lat']},${wp['lon']},${wp['alt']}');
    // ignore: avoid_print
    print(outLines.join('\n'));

    // _showInfoDialog('Thông báo', 'Đã tạo ${_waypoints.length} waypoints');
  }

  // Upload: gửi lệnh MISSION_SCAN qua BLE
  void _onUpload() async {
    // Lấy polygon nguồn: ưu tiên polygon đã accept; nếu chưa có thì dùng các điểm đang vẽ
    final List<LatLng> polygon = _acceptedPolygons.isNotEmpty
        ? _acceptedPolygons.first
        : (_points.length >= 3
            ? _ensurePolygonClosed(_orderSimplePolygon(List<LatLng>.from(_points)))
            : []);
    if (polygon.length < 3) {
      _showInfoDialog('Thông báo', 'Cần vẽ ít nhất 3 điểm để tạo vùng bay');
      return;
    }
    if (!_isBleConnected) {
      _showInfoDialog('Thông báo', 'Chưa kết nối BLE');
      return;
    }

    // Build mission string
    // Bỏ điểm cuối (điểm trùng điểm đầu khi polygon đóng) trước khi encode
    final polyToEncode = polygon.length >= 2 ? (List<LatLng>.from(polygon)..removeLast()) : polygon;
    final encoded = _encodePolyline(polyToEncode);
    final altInt = _altitude.round();
    final bearingInt = _normalizedBearingDeg.round();
    final missionCmd = 'MISSION_SCAN$altInt::$bearingInt::$encoded';
    
    // Reset WP progress trước khi upload mới để tránh hiển thị giá trị cũ
    setState(() {
      _wpDone = 0;
      _wpTotal = 0;
    });
    
    try {
      // Gửi lệnh MISSION_SCAN qua BLE
      await _bleService.writeString('$missionCmd\r\n');
      // ignore: avoid_print
      print('Đã gửi lệnh MISSION_SCAN qua BLE: $missionCmd');
      // Mở dialog ngay lập tức (kể cả a == b) để hiển thị trạng thái
      // _suppressMissionDialog = false; // cho phép hiển thị lại trong lượt upload này
      _forceLoading = (_wpDone == _wpTotal); // nếu a==b, ép loading
      if (!_isMissionDialogOpen) {
        _showMissionProgressDialog();
      }
      
      // Chờ 3 giây sau khi gửi lệnh
      await Future.delayed(const Duration(seconds: 3));
 
      // Sau 3s: không đóng dialog ở đây
      // Để WP event listener tự xử lý việc đóng dialog khi cần
      // Dialog sẽ tự động cập nhật progress qua WP event listener
      // Chỉ trigger rebuild để hiển thị nút Start nếu done == total
      if (_wpDone == _wpTotal && _wpTotal > 0) {
        // done == total: hiển thị nút Start (đã có logic hiển thị nút Start khi done == total)
        setState(() {}); // Trigger rebuild để hiển thị nút Start
        // Đóng dialog sẽ được xử lý trong WP event listener
      }
      // Các trường hợp khác (0/0, a==b) sẽ được xử lý trong WP event listener
    } catch (e) {
      // ignore: avoid_print
      print('Lỗi khi gửi lệnh MISSION_SCAN: $e');
      _showInfoDialog('Lỗi', 'Không thể gửi lệnh MISSION_SCAN: $e');
    }
  }

  /// Show dialog thông báo
  void _showInfoDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  /// Show dialog xác nhận xóa điểm
  void _showDeletePointDialog(int index) {
    setState(() {
      _isDeleteDialogOpen = true; // Đánh dấu dialog đang mở
    });
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Xóa điểm'),
          content: const Text('Bạn có chắc muốn xóa điểm này?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _isDeleteDialogOpen = false; // Đóng dialog
                });
              },
              child: const Text('Hủy'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _isDeleteDialogOpen = false; // Đóng dialog
                });
                _removePoint(index);
              },
              child: const Text('Xóa', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    ).then((_) {
      // Đảm bảo reset flag khi dialog đóng (kể cả khi tap outside)
      if (mounted) {
        setState(() {
          _isDeleteDialogOpen = false;
        });
      }
    });
  }

  /// Xóa điểm tại index
  void _removePoint(int index) {
    if (index < 0 || index >= _points.length) return;
    _saveState(); // Lưu state trước khi xóa
    setState(() {
      _points.removeAt(index);
    });
  }

  // Start: gửi lệnh START qua BLE
  void _onStart() async {
    // Lấy polygon từ các điểm hiện tại (không cần accept polygon)
    final List<LatLng> polygon = _points.length >= 3
        ? _ensurePolygonClosed(_orderSimplePolygon(List<LatLng>.from(_points)))
        : [];
    if (polygon.length < 3) {
      _showInfoDialog('Thông báo', 'Cần vẽ ít nhất 3 điểm để bay');
      return;
    }
    if (_selectedHomePoint == null) {
      _showInfoDialog('Thông báo', 'Chưa nhận HOME từ thiết bị');
      return;
    }
    if (!_isBleConnected) {
      _showInfoDialog('Thông báo', 'Chưa kết nối BLE');
      return;
    }

    try {
      // Gửi lệnh START qua BLE
      await _bleService.writeString('START\r\n');
      // ignore: avoid_print
      print('Đã gửi lệnh START qua BLE');
      _showInfoDialog('Thông báo', 'Đã gửi lệnh START');
    } catch (e) {
      // ignore: avoid_print
      print('Lỗi khi gửi lệnh START: $e');
      _showInfoDialog('Lỗi', 'Không thể gửi lệnh START: $e');
    }
  }

  /// Show mission progress dialog with circular progress indicator
  void _showMissionProgressDialog() {
    if (_isMissionDialogOpen) {
      // Dialog đã mở, không cần làm gì - chỉ reset thời gian khi mở dialog mới
      return;
    }
    _isMissionDialogOpen = true;
    _dialogOpenTime = DateTime.now(); // Lưu thời gian mở dialog (reset dialog mới)
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _MissionProgressDialog(
          wpDone: _wpDone,
          wpTotal: _wpTotal,
          dialogOpenTime: _dialogOpenTime,
          forceLoading: _forceLoading,
          eventBus: _eventBus,
          onClose: () => _hideMissionProgressDialog(),
        );
      },
    );
  }

  /// Hide mission progress dialog
  void _hideMissionProgressDialog() {
    if (!_isMissionDialogOpen) return;
    _isMissionDialogOpen = false;
    _dialogOpenTime = null; // Reset thời gian mở dialog
    // Chỉ pop nếu dialog vẫn còn trên stack (tránh pop 2 lần khi dialog tự đóng)
    // Nếu dialog đã tự đóng bằng Navigator.pop() thì canPop() sẽ trả về false
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (mounted) {
      setState(() {
        // Trigger rebuild để hiển thị nút Start nếu điều kiện đủ
      });
    }
  }

  // ---- Polyline encoder (Google) with 1e5 scaling ----
  String _encodePolyline(List<LatLng> coords) {
    int prevLat = 0;
    int prevLng = 0;
    final StringBuffer out = StringBuffer();
    for (final p in coords) {
      final lat = (p.latitude * 1e5).round();
      final lng = (p.longitude * 1e5).round();
      out.write(_encodeNumber(lat - prevLat));
      out.write(_encodeNumber(lng - prevLng));
      prevLat = lat;
      prevLng = lng;
    }
    return out.toString();
  }

  String _encodeNumber(int num) {
    num = num < 0 ? ~(num << 1) : (num << 1);
    final StringBuffer out = StringBuffer();
    while (num >= 0x20) {
      out.writeCharCode(((0x20 | (num & 0x1f)) + 63));
      num >>= 5;
    }
    out.writeCharCode(num + 63);
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    // Use LayoutBuilder to ensure map gets proper size on mobile
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              // Map with key to ensure proper rendering on mobile
              FlutterMap(
                key: _mapKey,
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _center,
                  initialZoom: _zoom,
                  onTap: _onMapTap,
                  onLongPress: _onMapLongPress,
                  onPositionChanged: (position, hasGesture) {
                  // Bỏ giới hạn pan trong bán kính 1km quanh HOME
                  final newCenter = position.center ?? _center;
                  final newZoom = position.zoom ?? _zoom;
                  setState(() {
                    _center = newCenter;
                    _zoom = newZoom;
                  });
                  },
                  // Lock map when showing bearing or dragging marker (disable all interactions)
                  interactionOptions: (_showBearing || _isDraggingMarker)
                      ? const InteractionOptions(
                          flags: InteractiveFlag.none,
                        )
                      : const InteractionOptions(
                          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                        ),
                  minZoom: 3,
                  maxZoom: 24, // Cho phép over-zoom vượt quá native tiles
                ),
            children: [
              // Satellite tiles - Google (HTTPS)
              TileLayer(
                urlTemplate: 'https://mt1.google.com/vt/lyrs=s&hl=vi&x={x}&y={y}&z={z}',
                maxZoom: 24, // Cho phép zoom lên 24
                maxNativeZoom: 21, // Native tối đa 21, trên mức này sẽ upscale
                retinaMode: true,
                userAgentPackageName: 'com.example.map_compass_mobile',
                keepBuffer: 2,
              ),
              // Accepted polygons (multiple polygons) - render first to avoid overlap
              if (_acceptedPolygons.isNotEmpty)
                PolygonLayer(
                  polygons: _acceptedPolygons.map((polygon) {
                    return Polygon(
                      points: polygon,
                      color: const Color(0xff2e7d32).withValues(alpha: 0.4),
                      borderColor: const Color(0xff2e7d32),
                      borderStrokeWidth: 2.5,
                    );
                  }).toList(),
                ),
              // Drawing polyline (ordered points) - render on top
              if (_points.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _orderSimplePolygon(_points),
                      color: Colors.blue,
                      strokeWidth: 3,
                    ),
                  ],
                ),
              // Drawing polygon (current points) - render on top with different color
              if (_points.length >= 3)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _orderSimplePolygon(_points),
                      color: Colors.blue.withValues(alpha: 0.2),
                      borderColor: Colors.blue,
                      borderStrokeWidth: 3,
                    ),
                  ],
                ),
              // Draggable point markers (current drawing points) - render on top
              // Cho phép kéo thả khi chưa accept polygon và chưa có preview
              if (_points.isNotEmpty && _isDrawingMode && _acceptedPolygons.isEmpty && !_hasWaypoints)
                MarkerLayer(
                  markers: _points.asMap().entries.map((entry) {
                    final index = entry.key;
                    final point = entry.value;
                    return _DraggableMarker(
                      point: point,
                      index: index,
                      onDragEnd: _onPointDrag,
                      mapController: _mapController,
                      disabled: _showBearing || !_isDrawingMode || _acceptedPolygons.isNotEmpty || _hasWaypoints,
                      isDeleteMode: _isDeleteMode,
                      onDragStart: () {
                        // Lưu state trước khi bắt đầu drag điểm (chỉ lưu 1 lần cho mỗi lần drag)
                        if (!_hasSavedDragState) {
                          _saveState();
                          _hasSavedDragState = true;
                        }
                        setState(() {
                          _isDraggingMarker = true;
                        });
                      },
                      onDragEndCallback: () {
                        setState(() {
                          _isDraggingMarker = false;
                          _hasSavedDragState = false; // Reset flag khi kết thúc drag
                        });
                      },
                      onTap: _isDeleteMode ? (index) {
                        // Chỉ hiện dialog xóa khi đang ở chế độ delete mode
                        _showDeletePointDialog(index);
                      } : null, // Khi OFF: không xóa khi tap, chỉ drag
                    );
                  }).toList(),
                ),
              // Waypoint path
              if (_waypointPath.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _waypointPath,
                      color: const Color(0xffff6f00),
                      strokeWidth: 3,
                    ),
                  ],
                ),
              // Waypoint markers with numbers (tiny circular badges) - bỏ điểm cuối
              if (_waypoints.isNotEmpty && _waypoints.length > 1)
                MarkerLayer(
                  markers: _waypoints.take(_waypoints.length - 1).toList().asMap().entries.map((entry) {
                    final idx = entry.key;
                    final point = entry.value;
                    return Marker(
                      point: point,
                      width: 16,
                      height: 16,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xffff6f00),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 2,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${idx + 2}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

              // Selected home (drone) marker
              if (_selectedHomePoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _selectedHomePoint!,
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Icon(Icons.flight, color: Color(0xff1976d2), size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),


          // Remove portrait overlay; this screen stays landscape

          // Full screen compass rose overlay (only visible in landscape)
          if (_showBearing && _isLandscape())
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (details) {
                  // Lưu vị trí ban đầu khi bắt đầu pan
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null) {
                    _compassPanStartPosition = details.localPosition;
                  }
                },
                onPanUpdate: (details) {
                  // Xoay la bàn theo hướng vuốt của 1 ngón tay (circular motion)
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null || _compassPanStartPosition == null) return;
                  
                  final size = box.size;
                  final center = Offset(size.width / 2, size.height / 2);
                  
                  // Tính góc từ center đến vị trí ban đầu
                  final startDx = _compassPanStartPosition!.dx - center.dx;
                  final startDy = _compassPanStartPosition!.dy - center.dy;
                  final startAngle = math.atan2(startDy, startDx);
                  
                  // Tính góc từ center đến vị trí hiện tại
                  final currentDx = details.localPosition.dx - center.dx;
                  final currentDy = details.localPosition.dy - center.dy;
                  final currentAngle = math.atan2(currentDy, currentDx);
                  
                  // Tính góc quay (delta angle)
                  var deltaAngle = currentAngle - startAngle;
                  
                  // Normalize delta angle về [-π, π]
                  if (deltaAngle > math.pi) deltaAngle -= 2 * math.pi;
                  if (deltaAngle < -math.pi) deltaAngle += 2 * math.pi;
                  
                  // Chuyển sang độ và cập nhật bearing
                  final rotationDeg = deltaAngle * 180.0 / math.pi;
                  
                  setState(() {
                    _bearingDeg = _bearingDeg + rotationDeg;
                    // Normalize về [-180, 180]
                    _bearingDeg = _normalizeBearing(_bearingDeg);
                    // Cập nhật vị trí ban đầu cho lần move tiếp theo
                    _compassPanStartPosition = details.localPosition;
                  });
                },
                onPanEnd: (details) {
                  _compassPanStartPosition = null;
                },
                onPanCancel: () {
                  _compassPanStartPosition = null;
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Restore previous size (~75% of screen)
                    final screenSize = math.min(constraints.maxWidth, constraints.maxHeight);
                    final compassSize = screenSize * 0.75;
                    
                    return Stack(
                      children: [
                        // Semi-transparent white background to keep map visible
                        Positioned.fill(
                          child: Container(
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                        // Full screen compass rose - outer fixed, inner rotating
                        Center(
                          child: SizedBox(
                            width: compassSize,
                            height: compassSize,
                            child: CompassArrow(bearingDeg: _bearingDeg),
                          ),
                        ),
                        // Bỏ viền trắng sọc sọc (_ArcStripedSliderPainter)
                        // 0° white marker at top
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _ZeroDegreeIndicatorPainter(),
                            ),
                          ),
                        ),
                        // Degree display in center (no background, fixed width to keep degree symbol aligned)
                        Center(
                          child: SizedBox(
                            width: 80, // wide enough for "-180°"
                            child: Text(
                              '${_normalizedBearingDeg.toStringAsFixed(0)}°',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFE50083), // match SVG label color
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),

          // Done button (top-right) - only show when compass is active
          if (_showBearing && _isLandscape())
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: FloatingActionButton.extended(
                  heroTag: 'compass_done_btn',
                  backgroundColor: const Color(0xff2e7d32),
                  onPressed: () {
                    setState(() {
                      _showBearing = false;
                    });
                  },
                  icon: const Icon(Icons.check, color: Colors.white),
                  label: const Text(
                    'Done',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),

          // BLE Connection Header (top center)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isBleConnected 
                        ? const Color(0xff2e7d32).withValues(alpha: 0.9)
                        : Colors.grey.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isBleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isBleConnected 
                            ? 'Đã kết nối: ${_bleService.deviceName ?? 'AgriBeacon BLE'}'
                            : (_reconnectStatus.isNotEmpty 
                                ? _reconnectStatus 
                                : 'Đang kết nối đến thiết bị bay'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Mission progress is now shown as dialog (removed overlay)

          // Back button (top left) - only show when compass is not active
          if (!_showBearing)
            Positioned(
              top: 12,
              left: 12,
              child: SafeArea(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                      onPressed: () => Navigator.pop(context),
                      child: const Icon(Icons.arrow_back, color: Colors.black87),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: _status == 1 ? const Color(0xff2e7d32) : const Color(0xffe53935),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Floating button bar (Accept, Upload, Start, Delete All) - only show when compass is not active
          if (!_showBearing)
            Positioned(
              right: 12,
              bottom: 56,
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Toggle button
                FloatingActionButton(
                  mini: true,
                  backgroundColor: Colors.grey.shade700,
                  onPressed: () {
                    setState(() {
                      _isFloatingBarExpanded = !_isFloatingBarExpanded;
                    });
                  },
                  child: Icon(
                    _isFloatingBarExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                    color: Colors.white,
                  ),
                ),
                if (_isFloatingBarExpanded) ...[
                  const SizedBox(height: 8),
                  // Bỏ nút Accept; cho phép Preview trực tiếp khi có >= 3 điểm
                  // Preview button (only show if waypoints not generated yet)
                  if (!_hasWaypoints)
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: _points.length < 3
                          ? Colors.grey.shade400
                          : Colors.orange,
                      onPressed: _points.length < 3 ? null : _onPreview,
                      child: const Icon(Icons.preview, color: Colors.white),
                      tooltip: 'Preview',
                    ),
                  if (!_hasWaypoints) const SizedBox(height: 8),
                  // Upload button (only show if waypoints exist)
                  if (_hasWaypoints)
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: const Color(0xff1976d2),
                      onPressed: _onUpload,
                      child: const Icon(Icons.cloud_upload, color: Colors.white),
                      tooltip: 'Upload',
                    ),
                  if (_hasWaypoints) const SizedBox(height: 8),
                  // Start button (only show if waypoints exist và WP done == total > 0)
                  // Màu xanh khi status = 1, màu xám khi status != 1
                  if (_hasWaypoints && _wpDone == _wpTotal && _wpTotal > 0)
                    FloatingActionButton(
                      mini: true,
                      backgroundColor: _status == 1 
                          ? const Color(0xff2e7d32) 
                          : Colors.grey.shade400,
                      onPressed: _status == 1 ? _onStart : null,
                      child: const Icon(Icons.play_arrow, color: Colors.white),
                      tooltip: _status == 1 ? 'Bắt đầu' : 'Chưa sẵn sàng',
                    ),
                  if (_hasWaypoints) const SizedBox(height: 8),
                  // Compass button (hidden after upload)
                  if (!_hasWaypoints)
                  FloatingActionButton(
                    mini: true,
                    backgroundColor: _showBearing 
                        ? const Color(0xff1976d2) 
                        : Colors.grey.shade700,
                    onPressed: _toggleCompass,
                    child: Icon(
                      Icons.explore,
                      color: Colors.white,
                    ),
                    tooltip: 'La bàn',
                  ),
                  const SizedBox(height: 8),
                  // Undo button
                  FloatingActionButton(
                    mini: true,
                    backgroundColor: _undoHistory.isEmpty 
                        ? Colors.grey.shade400 
                        : Colors.orange,
                    onPressed: _undoHistory.isEmpty ? null : _undo,
                    child: const Icon(Icons.undo, color: Colors.white),
                    tooltip: 'Hoàn tác',
                  ),
                  const SizedBox(height: 8),
                  // Delete Mode button (toggle ON/OFF để xóa từng điểm)
                  if (!_hasWaypoints)
                  FloatingActionButton(
                    mini: true,
                    backgroundColor: _isDeleteMode 
                        ? const Color(0xffff6f00)  // Màu cam khi ON
                        : Colors.grey.shade700,    // Màu xám khi OFF
                    onPressed: _showBearing ? null : () {
                      setState(() {
                        _isDeleteMode = !_isDeleteMode; // Toggle ON/OFF
                      });
                    },
                    child: Icon(
                      _isDeleteMode ? Icons.delete : Icons.delete_outline,
                      color: Colors.white,
                    ),
                    tooltip: _isDeleteMode ? 'Chế độ xóa: ON (nhấn để tắt)' : 'Chế độ xóa: OFF (nhấn để bật)',
                  ),
                  if (!_hasWaypoints) const SizedBox(height: 8),
                  // Delete All button (xóa tất cả - tách biệt với delete mode)
                  FloatingActionButton(
                    mini: true,
                    backgroundColor: const Color(0xffe53935),
                    onPressed: _showBearing ? null : _clearAll,
                    child: const Icon(Icons.delete_sweep, color: Colors.white),
                    tooltip: 'Xóa tất cả',
                  ),
                ],
              ],
            ),
          ),


          // Altitude control (vertical, left side) - only show when compass is not active
          if (!_showBearing)
            Positioned(
              left: 12,
              top: 60,
              bottom: 80,
              child: SafeArea(
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 240,
                          child: RotatedBox(
                            quarterTurns: 3, // Quay 270 độ để slider dọc
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                showValueIndicator: ShowValueIndicator.never, // Tắt label tooltip
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                              ),
                              child: Slider(
                                min: 5.5,
                                max: 300.0,
                                divisions: 189, // steps of 0.5 from 5.5 to 300.0
                                value: _altitude,
                                onChanged: _hasWaypoints ? null : (v) => setState(() => _altitude = v),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Hiển thị giá trị độ cao ở dưới slider với background (kích thước cố định)
                        Container(
                          width: 70, // Chiều rộng cố định để đủ cho "100.0 m" không xuống dòng
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xff2e7d32),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 3,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Text(
                            '${_altitude.toStringAsFixed(1)} m',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff2e7d32),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
            ],
          );
        },
      ),
    );
  }
}

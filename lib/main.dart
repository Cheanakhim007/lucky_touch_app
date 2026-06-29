import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const LuckyTouchApp());
}

// ─── Constants ────────────────────────────────────────────────────────────────

const List<Color> _fingerColors = [
  Color(0xFF00BFFF),
  Color(0xFFFF1493),
  Color(0xFFFF8C00),
  Color(0xFF9400D3),
  Color(0xFF00FF7F),
  Color(0xFFFFD700),
  Color(0xFFFF4500),
  Color(0xFF00CED1),
  Color(0xFFFF69B4),
  Color(0xFF7FFF00),
];

// ─── Enums ────────────────────────────────────────────────────────────────────

enum PickerState { waiting, holding, countdown, selecting, picked }
enum PickMode    { auto, manual }
enum FingerStyle { ring, fingerprint, circle }
enum HoldMode    { hold, touch }   // NEW

// ─── App ──────────────────────────────────────────────────────────────────────

class LuckyTouchApp extends StatelessWidget {
  const LuckyTouchApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LuckyTouch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: const LuckyTouchScreen(),
    );
  }
}

// ─── Finger model ─────────────────────────────────────────────────────────────

class FingerPoint {
  final int pointerId;
  Offset position;
  final Color color;
  final int colorIndex;
  bool isWinner;
  double opacity;
  double scale;
  final List<double> ringAngles;
  final List<double> ringSpeeds;

  FingerPoint({
    required this.pointerId,
    required this.position,
    required this.color,
    required this.colorIndex,
  })  : isWinner = false,
        opacity = 1.0,
        scale = 1.0,
        ringAngles = List.generate(5, (_) => 0.0),
        ringSpeeds = List.generate(
          5,
              (i) => (i.isEven ? 1 : -1) * (0.025 + i * 0.01),
        );

  void tick() {
    for (int i = 0; i < ringAngles.length; i++) {
      ringAngles[i] += ringSpeeds[i];
    }
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class LuckyTouchScreen extends StatefulWidget {

  const LuckyTouchScreen({Key? key}) : super(key: key);

  @override
  State<LuckyTouchScreen> createState() => _LuckyTouchScreenState();
}

class _LuckyTouchScreenState extends State<LuckyTouchScreen>
    with TickerProviderStateMixin {

  final Map<int, FingerPoint> _fingers = {};
  PickerState  _state       = PickerState.waiting;
  PickMode     _pickMode    = PickMode.auto;
  FingerStyle  _fingerStyle = FingerStyle.ring;
  HoldMode     _holdMode    = HoldMode.hold;   // NEW — default: must hold
  int          _countdown   = 3;
  int          _colorIndex  = 0;
  FingerPoint? _winner;

  // Ring spin ticker
  late Ticker _ticker;
  Timer? _countdownTimer;

  // Selecting animation: finger style bounces small→big→small in loop
  late AnimationController _selectingController;
  late Animation<double>   _selectingScale;

  // Winner reveal animation
  late AnimationController _winnerController;
  late Animation<double>   _winnerScale;
  late Animation<double>   _winnerFade;

  @override
  void initState() {
    super.initState();

    _ticker = createTicker((_) {
      if (_fingers.isNotEmpty) {
        setState(() { for (final f in _fingers.values) f.tick(); });
      }
    });
    _ticker.start();

    _selectingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _selectingScale = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.6, end: 1.5), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.5, end: 0.6), weight: 50),
    ]).animate(CurvedAnimation(
      parent: _selectingController,
      curve: Curves.easeInOut,
    ));

    _winnerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _winnerScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _winnerController, curve: Curves.elasticOut),
    );
    _winnerFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _winnerController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _countdownTimer?.cancel();
    _selectingController.dispose();
    _winnerController.dispose();
    super.dispose();
  }

  // ── Touch handling ────────────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e) {
    if (_state == PickerState.picked || _state == PickerState.selecting) {
      if (_state == PickerState.picked) _reset();
      return;
    }

    HapticFeedback.lightImpact();

    setState(() {
      final color = _fingerColors[_colorIndex % _fingerColors.length];
      _fingers[e.pointer] = FingerPoint(
        pointerId: e.pointer,
        position: e.localPosition,
        color: color,
        colorIndex: _colorIndex,
      );
      _colorIndex++;
      _state = _fingers.length >= 2 ? PickerState.holding : PickerState.waiting;
    });

    if (_fingers.length >= 2 && _pickMode == PickMode.auto) {
      _restartCountdown();
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_fingers.containsKey(e.pointer)) {
      setState(() => _fingers[e.pointer]!.position = e.localPosition);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_state == PickerState.picked || _state == PickerState.selecting) return;

    if (_holdMode == HoldMode.hold) {
      // HOLD mode: lifting a finger removes it and cancels the countdown
      setState(() {
        _fingers.remove(e.pointer);
        if (_fingers.length < 2) {
          _cancelCountdown();
          _state = _fingers.isEmpty ? PickerState.waiting : PickerState.waiting;
        }
      });
    }
    // TOUCH mode: lifting a finger does nothing — touches stay registered
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _onPointerUp(PointerUpEvent(pointer: e.pointer, position: e.position));
  }

  // ── Countdown ─────────────────────────────────────────────────────────────────

  void _restartCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _state     = PickerState.countdown;
      _countdown = 3;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_fingers.length < 2) { _cancelCountdown(); return; }
      setState(() => _countdown--);
      if (_countdown <= 0) { t.cancel(); _startSelecting(); }
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _state     = _fingers.length >= 2 ? PickerState.holding : PickerState.waiting;
      _countdown = 3;
    });
  }

  // ── Selecting ─────────────────────────────────────────────────────────────────

  void _startSelecting() {
    if (_fingers.isEmpty) return;
    final keys      = _fingers.keys.toList();
    final winnerKey = keys[Random().nextInt(keys.length)];

    setState(() => _state = PickerState.selecting);
    _selectingController.repeat();
    HapticFeedback.mediumImpact();

    Future.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      _selectingController.stop();
      _selectingController.reset();
      _revealWinner(winnerKey);
    });
  }

  void _revealWinner(int winnerKey) {
    setState(() {
      _winner = _fingers[winnerKey];
      _winner!.isWinner = true;
      for (final k in _fingers.keys) {
        if (k != winnerKey) {
          _fingers[k]!.opacity = 0.10;
          _fingers[k]!.scale   = 0.55;
        }
      }
      _state = PickerState.picked;
    });
    _winnerController.forward(from: 0);
    HapticFeedback.heavyImpact();

    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _state == PickerState.picked) _reset();
    });
  }

  void _reset() {
    _countdownTimer?.cancel();
    _selectingController.stop();
    _selectingController.reset();
    _winnerController.reset();
    setState(() {
      _fingers.clear();
      _state      = PickerState.waiting;
      _countdown  = 3;
      _winner     = null;
      _colorIndex = 0;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CustomPaint(
            painter: _GridPainter(),
            child: const SizedBox.expand(),
          ),
          Listener(
            onPointerDown:   _onPointerDown,
            onPointerMove:   _onPointerMove,
            onPointerUp:     _onPointerUp,
            onPointerCancel: _onPointerCancel,
            behavior: HitTestBehavior.opaque,
            child: SizedBox.expand(
              child: Stack(
                children: [
                  ..._fingers.values.map(_buildFingerWidget),
                ],
              ),
            ),
          ),
          _buildTopBar(),
          _buildCenterOverlay(),
          if (_pickMode == PickMode.manual &&
              _fingers.length >= 2 &&
              _state != PickerState.picked &&
              _state != PickerState.selecting)
            _buildManualPickButton(),
        ],
      ),
    );
  }

  // ── Finger widget ─────────────────────────────────────────────────────────────

  Widget _buildFingerWidget(FingerPoint f) {
    final isWinner    = f.isWinner && _state == PickerState.picked;
    final isSelecting = _state == PickerState.selecting;
    final size        = isWinner ? 200.0 : 160.0;

    Widget child;

    if (isSelecting) {
      child = AnimatedBuilder(
        animation: _selectingScale,
        builder: (_, __) => Transform.scale(
          scale: _selectingScale.value,
          child: _FingerStyleWidget(
            finger: f,
            size: size,
            style: _fingerStyle,
            isWinner: false,
          ),
        ),
      );
    } else if (isWinner) {
      child = AnimatedBuilder(
        animation: _winnerController,
        builder: (_, __) => Transform.scale(
          scale: _winnerScale.value,
          child: Opacity(
            opacity: _winnerFade.value,
            child: _FingerStyleWidget(
              finger: f,
              size: size,
              style: _fingerStyle,
              isWinner: true,
            ),
          ),
        ),
      );
    } else {
      child = _FingerStyleWidget(
        finger: f,
        size: size,
        style: _fingerStyle,
        isWinner: false,
      );
    }

    return Positioned(
      left: f.position.dx - size / 2,
      top:  f.position.dy - size / 2,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 350),
        opacity: f.opacity,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 350),
          scale: f.scale,
          child: child,
        ),
      ),
    );
  }

  // ── How to play ───────────────────────────────────────────────────────────────

  void _showHowToPlay(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _HowToPlaySheet(),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // [0] Hold / Touch toggle
            _TopBarButton(
              icon: _holdMode == HoldMode.hold
                  ? Icons.touch_app
                  : Icons.touch_app_outlined,
              label: _holdMode == HoldMode.hold ? 'Hold' : 'Touch',
              active: _holdMode == HoldMode.hold,
              onTap: () {
                if (_state == PickerState.picked || _state == PickerState.selecting) return;
                setState(() {
                  _holdMode = _holdMode == HoldMode.hold
                      ? HoldMode.touch
                      : HoldMode.hold;
                  _cancelCountdown();
                  _fingers.clear();
                  _state      = PickerState.waiting;
                  _colorIndex = 0;
                });
              },
            ),

            const SizedBox(width: 6),

            // [1] Auto / Manual toggle
            _TopBarButton(
              icon: _pickMode == PickMode.auto
                  ? Icons.timer_outlined
                  : Icons.ads_click_outlined,
              label: _pickMode == PickMode.auto ? 'Auto' : 'Manual',
              onTap: () {
                if (_state == PickerState.picked || _state == PickerState.selecting) return;
                setState(() {
                  _pickMode = _pickMode == PickMode.auto ? PickMode.manual : PickMode.auto;
                  _cancelCountdown();
                });
              },
            ),

            const SizedBox(width: 6),

            // [2] Finger style toggle: Ring → Print → Dot → Ring
            _TopBarButton(
              icon: _fingerStyle == FingerStyle.ring
                  ? Icons.adjust
                  : _fingerStyle == FingerStyle.fingerprint
                  ? Icons.fingerprint
                  : Icons.circle,
              label: _fingerStyle == FingerStyle.ring
                  ? 'Ring'
                  : _fingerStyle == FingerStyle.fingerprint
                  ? 'Print'
                  : 'Dot',
              onTap: () {
                if (_state == PickerState.picked || _state == PickerState.selecting) return;
                setState(() {
                  _fingerStyle = FingerStyle.values[
                  (_fingerStyle.index + 1) % FingerStyle.values.length];
                });
              },
            ),

            const Spacer(),

            // Finger count badge
            if (_fingers.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fingerprint, color: Colors.white54, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      '${_fingers.length}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

            if (_fingers.isNotEmpty) const SizedBox(width: 6),

            // ⓘ How to play button
            GestureDetector(
              onTap: () => _showHowToPlay(context),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.white70,
                  size: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Center overlay ────────────────────────────────────────────────────────────

  Widget _buildCenterOverlay() {
    if (_state == PickerState.waiting && _fingers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.touch_app, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'Place 2 or more fingers',
              style: TextStyle(color: Colors.white38, fontSize: 20,
                  fontWeight: FontWeight.w300),
            ),
            const SizedBox(height: 6),
            Text(
              _holdMode == HoldMode.hold
                  ? 'Keep fingers held down'
                  : 'Tap and release to register',
              style: const TextStyle(color: Colors.white24, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              _pickMode == PickMode.auto
                  ? 'Winner picks automatically'
                  : 'Press button to pick winner',
              style: const TextStyle(color: Colors.white24, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (_state == PickerState.countdown) {
      return Center(
        child: TweenAnimationBuilder<double>(
          key: ValueKey(_countdown),
          tween: Tween(begin: 1.5, end: 1.0),
          duration: const Duration(milliseconds: 500),
          curve: Curves.elasticOut,
          builder: (_, scale, __) => Transform.scale(
            scale: scale,
            child: Text(
              '$_countdown',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 130,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
          ),
        ),
      );
    }

    if (_state == PickerState.selecting) {
      return Center(
        child: AnimatedBuilder(
          animation: _selectingScale,
          builder: (_, __) => Opacity(
            opacity: (_selectingScale.value - 0.6) / 0.9,
            child: const Text('✨', style: TextStyle(fontSize: 60)),
          ),
        ),
      );
    }

    if (_state == PickerState.picked && _winner != null) {
      return Center(
        child: AnimatedBuilder(
          animation: _winnerController,
          builder: (_, __) => Opacity(
            opacity: _winnerFade.value,
            child: Transform.scale(
              scale: _winnerScale.value,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🎉', style: TextStyle(fontSize: 56)),
                  const SizedBox(height: 8),
                  const Text(
                    'LUCKY!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 8,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: _winner!.color, width: 1.5),
                      borderRadius: BorderRadius.circular(24),
                      color: _winner!.color.withOpacity(0.15),
                    ),
                    child: Text(
                      'Tap to play again',
                      style: TextStyle(
                          color: _winner!.color,
                          fontSize: 14,
                          letterSpacing: 1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  // ── Manual pick button ────────────────────────────────────────────────────────

  Widget _buildManualPickButton() {
    return Positioned(
      bottom: 48,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _startSelecting,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF00BFFF), Color(0xFF9400D3)],
              ),
              borderRadius: BorderRadius.circular(32),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00BFFF).withOpacity(0.4),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Text(
              'PICK WINNER',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Top bar button ───────────────────────────────────────────────────────────

class _TopBarButton extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  final bool         active;   // NEW — highlights the button when mode is on

  const _TopBarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active ? Colors.white24 : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Colors.white54 : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: active ? Colors.white : Colors.white70, size: 15),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Finger style widget (ring / fingerprint / circle) ───────────────────────

class _FingerStyleWidget extends StatelessWidget {
  final FingerPoint finger;
  final double      size;
  final FingerStyle style;
  final bool        isWinner;

  const _FingerStyleWidget({
    required this.finger,
    required this.size,
    required this.style,
    required this.isWinner,
  });

  @override
  Widget build(BuildContext context) {
    switch (style) {
      case FingerStyle.fingerprint:
        return _buildFingerprint();
      case FingerStyle.circle:
        return _buildCircle();
      case FingerStyle.ring:
        return CustomPaint(
          size: Size(size, size),
          painter: _FullRingPainter(
            color: finger.color,
            ringAngles: finger.ringAngles,
            isWinner: isWinner,
          ),
        );
    }
  }

  Widget _buildFingerprint() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: finger.color.withOpacity(0.12),
        border: Border.all(color: finger.color.withOpacity(0.5), width: 2),
        boxShadow: [
          BoxShadow(
            color: finger.color.withOpacity(isWinner ? 0.75 : 0.35),
            blurRadius: isWinner ? 36 : 16,
            spreadRadius: isWinner ? 10 : 2,
          ),
        ],
      ),
      child: Icon(Icons.fingerprint, color: finger.color, size: size * 0.65),
    );
  }

  Widget _buildCircle() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: finger.color.withOpacity(isWinner ? 0.9 : 0.78),
        boxShadow: [
          BoxShadow(
            color: finger.color.withOpacity(isWinner ? 0.85 : 0.45),
            blurRadius: isWinner ? 40 : 20,
            spreadRadius: isWinner ? 12 : 4,
          ),
        ],
      ),
      child: isWinner
          ? const Center(child: Text('👑', style: TextStyle(fontSize: 36)))
          : null,
    );
  }
}

// ─── Full ring painter ────────────────────────────────────────────────────────

class _FullRingPainter extends CustomPainter {
  final Color        color;
  final List<double> ringAngles;
  final bool         isWinner;

  _FullRingPainter({
    required this.color,
    required this.ringAngles,
    required this.isWinner,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR   = size.width / 2;
    const rings  = 5;

    for (int i = rings - 1; i >= 0; i--) {
      final t       = i / (rings - 1);
      final radius  = maxR * (0.18 + t * 0.82);
      final strokeW = isWinner ? 6.0 - t * 2.5 : 4.5 - t * 1.8;

      // Glow
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color       = color.withOpacity(isWinner ? 0.30 : 0.14)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = strokeW + 8
          ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 10),
      );

      // Full ring
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color       = color.withOpacity(0.85 - t * 0.20)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = strokeW,
      );

      // Spinning accent arc
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        ringAngles[i],
        0.8,
        false,
        Paint()
          ..color       = Colors.white.withOpacity(isWinner ? 0.55 : 0.30)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap   = StrokeCap.round,
      );
    }

    // Center dot
    if (isWinner) {
      canvas.drawCircle(
        center,
        16,
        Paint()
          ..color      = color.withOpacity(0.7)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
    }
    canvas.drawCircle(
      center,
      isWinner ? 11 : 7,
      Paint()
        ..color = isWinner ? Colors.white : color.withOpacity(0.95)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_FullRingPainter old) =>
      old.ringAngles != ringAngles || old.isWinner != isWinner;
}

// ─── How To Play bottom sheet ─────────────────────────────────────────────────

class _HowToPlaySheet extends StatelessWidget {
  const _HowToPlaySheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),

          // Title
          const Text(
            'HOW TO PLAY',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 28),

          // Illustration: phone mockup with finger dots
          _buildIllustration(),
          const SizedBox(height: 28),

          // Description
          const Text(
            'Place and hold 2 or more fingers of players on the screen, then press play button to start random for selecting a winner.\n\nTo enable Auto Play mode, Touch & Hold mode, or switch the finger style, tap the button at the top of the screen.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 32),

          // Close button
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text(
                'Close',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIllustration() {
    // Phone mockup with 4 coloured finger rings and hand icons
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12, width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // Grid dots background (reuse feel)
            CustomPaint(
              painter: _MiniGridPainter(),
              child: const SizedBox.expand(),
            ),

            // 4 finger ring dots at corners
            _fingerDot(left: 0.18, top: 0.22, color: const Color(0xFFFF1493)),
            _fingerDot(left: 0.58, top: 0.15, color: const Color(0xFFFF4500), big: true),
            _fingerDot(left: 0.22, top: 0.62, color: const Color(0xFFFF8C00)),
            _fingerDot(left: 0.62, top: 0.60, color: const Color(0xFF9400D3)),

            // Hand icons at each dot
            _handIcon(left: 0.05,  top: 0.00, flip: false),
            _handIcon(left: 0.50,  top: 0.00, flip: true),
            _handIcon(left: 0.08,  top: 0.52, flip: false),
            _handIcon(left: 0.52,  top: 0.52, flip: true),
          ],
        ),
      ),
    );
  }

  Widget _fingerDot({
    required double left,
    required double top,
    required Color color,
    bool big = false,
  }) {
    final size = big ? 70.0 : 52.0;
    return Positioned.fill(
      child: FractionallySizedBox(
        alignment: Alignment(left * 2 - 1, top * 2 - 1),
        widthFactor: big ? 0.22 : 0.17,
        heightFactor: big ? 0.38 : 0.28,
        child: CustomPaint(
          painter: _MiniRingPainter(color: color, big: big),
        ),
      ),
    );
  }

  Widget _handIcon({
    required double left,
    required double top,
    required bool flip,
  }) {
    return Positioned.fill(
      child: FractionallySizedBox(
        alignment: Alignment(left * 2 - 1 + (flip ? 0.3 : 0.1),
            top * 2 - 1 + 0.05),
        widthFactor: 0.20,
        heightFactor: 0.35,
        child: Transform(
          alignment: Alignment.center,
          transform: flip
              ? (Matrix4.identity()..scale(-1.0, 1.0))
              : Matrix4.identity(),
          child: const Icon(
            Icons.touch_app,
            color: Colors.white,
            size: 38,
          ),
        ),
      ),
    );
  }
}

// Mini ring painter for illustration
class _MiniRingPainter extends CustomPainter {
  final Color color;
  final bool  big;
  const _MiniRingPainter({required this.color, required this.big});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR   = size.width / 2;
    const rings  = 4;
    for (int i = rings - 1; i >= 0; i--) {
      final t      = i / (rings - 1);
      final radius = maxR * (0.20 + t * 0.78);
      final paint  = Paint()
        ..color       = color.withOpacity(big ? 0.9 - t * 0.3 : 0.75 - t * 0.25)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = big ? 3.0 : 2.2;

      // glow
      canvas.drawCircle(center, radius,
        Paint()
          ..color       = color.withOpacity(big ? 0.30 : 0.15)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = (big ? 3.0 : 2.2) + 6
          ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(center, radius, paint);
    }
    // center dot
    canvas.drawCircle(center, big ? 6 : 4,
        Paint()..color = big ? Colors.white : color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_MiniRingPainter old) => false;
}

// Mini grid for illustration background
class _MiniGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = Colors.white.withOpacity(0.04)
      ..strokeWidth = 1;
    const step = 24.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }
  @override
  bool shouldRepaint(_MiniGridPainter old) => false;
}

// ─── Grid background painter ──────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = Colors.white.withOpacity(0.03)
      ..strokeWidth = 1;

    const step = 40.0;

    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    final dotPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..style = PaintingStyle.fill;

    for (double x = 0; x <= size.width; x += step) {
      for (double y = 0; y <= size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}
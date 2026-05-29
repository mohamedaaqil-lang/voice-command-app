import 'dart:math' as math;
import 'package:flutter/material.dart';

class VoiceWaveVisualizer extends StatefulWidget {
  final bool isActive;
  final bool isSpeaking;

  const VoiceWaveVisualizer({
    super.key,
    required this.isActive,
    required this.isSpeaking,
  });

  @override
  State<VoiceWaveVisualizer> createState() => _VoiceWaveVisualizerState();
}

class _VoiceWaveVisualizerState extends State<VoiceWaveVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _GeminiWavePainter(
            animationValue: _controller.value,
            isActive: widget.isActive,
            isSpeaking: widget.isSpeaking,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class _GeminiWavePainter extends CustomPainter {
  final double animationValue;
  final bool isActive;
  final bool isSpeaking;

  _GeminiWavePainter({
    required this.animationValue,
    required this.isActive,
    required this.isSpeaking,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!isActive && !isSpeaking) {
      // Just a flat, gentle resting line
      final paint = Paint()
        ..shader = const LinearGradient(
          colors: [Colors.blue, Colors.purple],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      
      final path = Path()
        ..moveTo(0, size.height / 2)
        ..lineTo(size.width, size.height / 2);
      
      canvas.drawPath(path, paint);
      return;
    }

    final double midY = size.height / 2;
    final double width = size.width;

    // Draw 3 overlapping waves with Google Assistant / Gemini color tones
    // 1. Cyan/Blue Wave
    _drawSingleWave(
      canvas: canvas,
      size: size,
      midY: midY,
      width: width,
      phaseShift: animationValue * 2 * math.pi,
      frequency: 2.0,
      amplitude: isSpeaking ? 22.0 : 12.0,
      colors: [const Color(0xFF4FACFE), const Color(0xFF00F2FE)],
      opacity: 0.7,
    );

    // 2. Violet/Magenta Wave
    _drawSingleWave(
      canvas: canvas,
      size: size,
      midY: midY,
      width: width,
      phaseShift: -animationValue * 2 * math.pi + (math.pi / 3),
      frequency: 1.5,
      amplitude: isSpeaking ? 18.0 : 10.0,
      colors: [const Color(0xFFB92B27), const Color(0xFF1565C0)],
      opacity: 0.6,
    );

    // 3. Purple/Yellow Gold Wave (Gemini flare)
    _drawSingleWave(
      canvas: canvas,
      size: size,
      midY: midY,
      width: width,
      phaseShift: animationValue * 1.5 * math.pi + (2 * math.pi / 3),
      frequency: 2.5,
      amplitude: isSpeaking ? 15.0 : 8.0,
      colors: [const Color(0xFF7028FF), const Color(0xFFFFB300)],
      opacity: 0.5,
    );
  }

  void _drawSingleWave({
    required Canvas canvas,
    required Size size,
    required double midY,
    required double width,
    required double phaseShift,
    required double frequency,
    required double amplitude,
    required List<Color> colors,
    required double opacity,
  }) {
    final path = Path();
    path.moveTo(0, midY);

    for (double x = 0; x <= width; x++) {
      // Apply a sine function that tapers off at the edges
      final double progress = x / width;
      final double envelope = math.sin(progress * math.pi); // 0 at edges, 1 at center
      
      final double y = midY +
          math.sin(progress * frequency * 2 * math.pi + phaseShift) *
              amplitude *
              envelope;
      
      path.lineTo(x, y);
    }

    final paint = Paint()
      ..shader = LinearGradient(
        colors: colors.map((c) => c.withOpacity(opacity)).toList(),
      ).createShader(Rect.fromLTWH(0, 0, width, size.height))
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GeminiWavePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.isActive != isActive ||
        oldDelegate.isSpeaking != isSpeaking;
  }
}

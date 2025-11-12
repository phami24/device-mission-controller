import 'dart:math' as math;
import 'package:flutter/material.dart';

class CompassArrow extends StatelessWidget {
  final double bearingDeg; // rotation in degrees for inner ring (vòng nhỏ bên trong)
  final bool highlightNorth;
  const CompassArrow({super.key, required this.bearingDeg, this.highlightNorth = true});

  @override
  Widget build(BuildContext context) {
    // Compass rose size - using SVG files
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
              // Inner ring (rotating) - mag_north (vòng nhỏ bên trong, xoay)
              Transform.rotate(
                angle: bearingDeg * math.pi / 180.0,
                alignment: Alignment.center,
                child: Stack(
                  children: [
                    // SvgPicture.asset(
                    //   'lib/assets/nautical_compass_rose_mag_north.svg',
                    //   width: size,
                    //   height: size,
                    //   fit: BoxFit.contain,
                    // ),
                    Image.asset(
                      'lib/assets/nautical_compass_rose_mag_north.png',
                      width: size,
                      height: size,
                      fit: BoxFit.contain,
                    ),
                    // if (highlightNorth)
                    //   Positioned.fill(
                    //     child: CustomPaint(
                    //       painter: _NorthArrowHighlightPainter(),
                    //     ),
                    //   ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

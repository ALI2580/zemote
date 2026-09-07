// OFFICIALLY EXTRACTED lucide icon path data (zcode.z.ai remote v4 bundle,
// 2026-09-07). Rendered via LucideIcon (stroke 2, round caps, 24x24 grid).
// Regenerate with the bundle dig script when the official build changes.
// IGNORE_SIZE lint is fine — no widgets here.
import 'package:flutter/material.dart';

/// One drawable shape from a lucide icon definition.
/// kind: p=path(d) c=circle(cx,cy,r,fill) l=line(x1,y1,x2,y2)
///       r=rect(x,y,w,h,rx) pl=polyline(points)
class LucideShape {
  final String kind;
  final List<String> args;
  const LucideShape(this.kind, this.args);
}

class LucideIconData {
  final String name;
  final List<LucideShape> shapes;
  const LucideIconData(this.name, this.shapes);
}

const Map<String, LucideIconData> kOfficialIcons = {
  "arrow-up": LucideIconData("arrow-up", [
    LucideShape('p', ['m5 12 7-7 7 7']),
    LucideShape('p', ['M12 19V5']),
  ]),
  "brain": LucideIconData("brain", [
    LucideShape('p', ['M12 18V5']),
    LucideShape('p', ['M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4']),
    LucideShape('p', ['M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5']),
    LucideShape('p', ['M17.997 5.125a4 4 0 0 1 2.526 5.77']),
    LucideShape('p', ['M18 18a4 4 0 0 0 2-7.464']),
    LucideShape('p', ['M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517']),
    LucideShape('p', ['M6 18a4 4 0 0 1-2-7.464']),
    LucideShape('p', ['M6.003 5.125a4 4 0 0 0-2.526 5.77']),
  ]),
  "circle-stop": LucideIconData("circle-stop", [
    LucideShape('c', ['12','12','10','false']),
    LucideShape('r', ['9','9','6','6','1']),
  ]),
  "ellipsis": LucideIconData("ellipsis", [
    LucideShape('c', ['12','12','1','false']),
    LucideShape('c', ['19','12','1','false']),
    LucideShape('c', ['5','12','1','false']),
  ]),
  "file-diff": LucideIconData("file-diff", [
    LucideShape('p', ['M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z']),
    LucideShape('p', ['M9 10h6']),
    LucideShape('p', ['M12 13V7']),
    LucideShape('p', ['M9 17h6']),
  ]),
  "list-todo": LucideIconData("list-todo", [
    LucideShape('p', ['M13 5h8']),
    LucideShape('p', ['M13 12h8']),
    LucideShape('p', ['M13 19h8']),
    LucideShape('p', ['m3 17 2 2 4-4']),
    LucideShape('r', ['3','4','6','6','1']),
  ]),
  "package": LucideIconData("package", [
    LucideShape('p', ['M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z']),
    LucideShape('p', ['M12 22V12']),
    LucideShape('pl', ['3.29 7 12 12 20.71 7']),
    LucideShape('p', ['m7.5 4.27 9 5.15']),
  ]),
  "paperclip": LucideIconData("paperclip", [
    LucideShape('p', ['m16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551']),
  ]),
  "sliders-horizontal": LucideIconData("sliders-horizontal", [
    LucideShape('p', ['M10 5H3']),
    LucideShape('p', ['M12 19H3']),
    LucideShape('p', ['M14 3v4']),
    LucideShape('p', ['M16 17v4']),
    LucideShape('p', ['M21 12h-9']),
    LucideShape('p', ['M21 19h-5']),
    LucideShape('p', ['M21 5h-7']),
    LucideShape('p', ['M8 10v4']),
    LucideShape('p', ['M8 12H3']),
  ]),
  "chevron-down": LucideIconData("chevron-down", [
    LucideShape('p', ['m6 9 6 6 6-6']),
  ]),
  "chevron-right": LucideIconData("chevron-right", [
    LucideShape('p', ['m9 18 6-6-6-6']),
  ]),
  "plus": LucideIconData("plus", [
    LucideShape('p', ['M5 12h14']),
    LucideShape('p', ['M12 5v14']),
  ]),
  "check": LucideIconData("check", [
    LucideShape('p', ['M20 6 9 17l-5-5']),
  ]),
  "x": LucideIconData("x", [
    LucideShape('p', ['M18 6 6 18']),
    LucideShape('p', ['m6 6 12 12']),
  ]),
  "sparkles": LucideIconData("sparkles", [
    LucideShape('p', ['M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z']),
    LucideShape('p', ['M20 2v4']),
    LucideShape('p', ['M22 4h-4']),
    LucideShape('c', ['4','20','2','false']),
  ]),
  "copy": LucideIconData("copy", [
    LucideShape('r', ['8','8','14','14','2']),
    LucideShape('p', ['M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2']),
  ]),
  "thumbs-up": LucideIconData("thumbs-up", [
    LucideShape('p', ['M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z']),
    LucideShape('p', ['M7 10v12']),
  ]),
  "thumbs-down": LucideIconData("thumbs-down", [
    LucideShape('p', ['M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z']),
    LucideShape('p', ['M17 14V2']),
  ]),
};

/// Renders an official lucide icon: 24x24 grid, stroke 2, round caps/joins,
/// fill none except shapes explicitly marked filled (small accent dots).
class LucideIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const LucideIcon(this.name, {super.key, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final data = kOfficialIcons[name];
    if (data == null) return SizedBox(width: size, height: size);
    final effectiveColor = color ??
        DefaultTextStyle.of(context).style.color ??
        IconTheme.of(context).color ??
        Colors.white;
    return CustomPaint(
      size: Size.square(size),
      painter: _LucidePainter(data, effectiveColor),
    );
  }
}

class _LucidePainter extends CustomPainter {
  final LucideIconData data;
  final Color color;

  _LucidePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    for (final shape in data.shapes) {
      switch (shape.kind) {
        case 'p':
          canvas.drawPath(_parsePath(shape.args[0]), stroke);
        case 'c':
          final filled = shape.args.length > 3 && shape.args[3] == 'true';
          canvas.drawCircle(
              Offset(double.parse(shape.args[0]), double.parse(shape.args[1])),
              double.parse(shape.args[2]),
              filled ? fill : stroke);
        case 'l':
          canvas.drawLine(
              Offset(double.parse(shape.args[0]), double.parse(shape.args[1])),
              Offset(double.parse(shape.args[2]), double.parse(shape.args[3])),
              stroke);
        case 'pl':
          final pts = _parsePoints(shape.args[0]);
          if (pts.length >= 2) canvas.drawPath(_poly(pts), stroke);
        case 'r':
          final x = double.parse(shape.args[0]);
          final y = double.parse(shape.args[1]);
          final rect =
              Rect.fromLTRB(x, y, x + double.parse(shape.args[2]), y + double.parse(shape.args[3]));
          canvas.drawRRect(
              RRect.fromRectAndRadius(
                  rect, Radius.circular(double.parse(shape.args[4]))),
              stroke);
      }
    }
  }

  Path _poly(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_LucidePainter oldDelegate) =>
      oldDelegate.data != data || oldDelegate.color != color;
}

List<Offset> _parsePoints(String s) {
  final v = s
      .split(RegExp(r'[ ,]+'))
      .where((e) => e.isNotEmpty)
      .map(double.parse)
      .toList();
  return [
    for (var i = 0; i + 1 < v.length; i += 2) Offset(v[i], v[i + 1]),
  ];
}

// --- Minimal SVG path parser (M L H V C S Q T A Z, absolute + relative). ---

Path _parsePath(String d) {
  final path = Path();
  var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0;
  var lastCx = 0.0, lastCy = 0.0, lastQx = 0.0, lastQy = 0.0;
  var i = 0;
  String? cmd;

  bool sep(int c) => c <= 0x20 || c == 0x2C;

  double num() {
    while (i < d.length && sep(d.codeUnitAt(i))) {
      i++;
    }
    final start = i;
    if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
    while (i < d.length) {
      final c = d.codeUnitAt(i);
      if ((c >= 0x30 && c <= 0x39) || d[i] == '.') {
        i++;
      } else if (d[i] == 'e' || d[i] == 'E') {
        i++;
        if (i < d.length && (d[i] == '-' || d[i] == '+')) i++;
      } else {
        break;
      }
    }
    return double.parse(d.substring(start, i));
  }

  bool nextIsNumber() {
    var j = i;
    while (j < d.length && sep(d.codeUnitAt(j))) {
      j++;
    }
    if (j >= d.length) return false;
    final c = d[j];
    return c == '-' || c == '+' || c == '.' || (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39);
  }

  while (i < d.length) {
    while (i < d.length && sep(d.codeUnitAt(i))) {
      i++;
    }
    if (i >= d.length) break;
    final ch = d[i];
    if ('MmLlHhVvCcSsQqTtAaZz'.contains(ch)) {
      cmd = ch;
      i++;
    } else if (cmd == null) {
      break;
    }
    switch (cmd) {
      case 'M' || 'm':
        if (cmd == 'M') {
          cx = num();
          cy = num();
        } else {
          cx += num();
          cy += num();
        }
        sx = cx;
        sy = cy;
        path.moveTo(cx, cy);
        // 小写 m 之后的隐式线段是相对的（官方 arrow-up/chevron 均以此
        // 起笔，误当绝对坐标会画出飞出画布的"竖线"）。
        cmd = cmd == 'm' ? 'l' : 'L';
      case 'L' || 'l':
        while (nextIsNumber()) {
          if (cmd == 'L') {
            cx = num();
            cy = num();
          } else {
            cx += num();
            cy += num();
          }
          path.lineTo(cx, cy);
        }
      case 'H' || 'h':
        while (nextIsNumber()) {
          cx = cmd == 'H' ? num() : cx + num();
          path.lineTo(cx, cy);
        }
      case 'V' || 'v':
        while (nextIsNumber()) {
          cy = cmd == 'V' ? num() : cy + num();
          path.lineTo(cx, cy);
        }
      case 'C' || 'c':
        while (nextIsNumber()) {
          final x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num();
          if (cmd == 'C') {
            path.cubicTo(x1, y1, x2, y2, x, y);
            lastCx = x2;
            lastCy = y2;
            cx = x;
            cy = y;
          } else {
            path.cubicTo(cx + x1, cy + y1, cx + x2, cy + y2, cx + x, cy + y);
            lastCx = cx + x2;
            lastCy = cy + y2;
            cx += x;
            cy += y;
          }
        }
      case 'S' || 's':
        while (nextIsNumber()) {
          final x2 = num(), y2 = num(), x = num(), y = num();
          final x1 = 2 * cx - lastCx, y1 = 2 * cy - lastCy;
          if (cmd == 'S') {
            path.cubicTo(x1, y1, x2, y2, x, y);
            lastCx = x2;
            lastCy = y2;
            cx = x;
            cy = y;
          } else {
            path.cubicTo(cx + x1, cy + y1, cx + x2, cy + y2, cx + x, cy + y);
            lastCx = cx + x2;
            lastCy = cy + y2;
            cx += x;
            cy += y;
          }
        }
      case 'Q' || 'q':
        while (nextIsNumber()) {
          final qx = num(), qy = num(), x = num(), y = num();
          if (cmd == 'Q') {
            path.quadraticBezierTo(qx, qy, x, y);
          } else {
            path.quadraticBezierTo(cx + qx, cy + qy, cx + x, cy + y);
          }
          lastQx = cmd == 'Q' ? qx : cx + qx;
          lastQy = cmd == 'Q' ? qy : cy + qy;
          cx = cmd == 'Q' ? x : cx + x;
          cy = cmd == 'Q' ? y : cy + y;
        }
      case 'T' || 't':
        while (nextIsNumber()) {
          final x = num(), y = num();
          final qx = 2 * cx - lastQx, qy = 2 * cy - lastQy;
          if (cmd == 'T') {
            path.quadraticBezierTo(qx, qy, x, y);
            cx = x;
            cy = y;
          } else {
            path.quadraticBezierTo(cx + qx, cy + qy, cx + x, cy + y);
            cx += x;
            cy += y;
          }
          lastQx = qx;
          lastQy = qy;
        }
      case 'A' || 'a':
        while (nextIsNumber()) {
          final rx = num(), ry = num(), rot = num();
          final large = num(), sweep = num(), x = num(), y = num();
          final nx = cmd == 'A' ? x : cx + x;
          final ny = cmd == 'A' ? y : cy + y;
          path.arcToPoint(
            Offset(nx, ny),
            radius: Radius.elliptical(rx, ry),
            rotation: rot,
            largeArc: large != 0,
            clockwise: sweep != 0,
          );
          cx = nx;
          cy = ny;
        }
      case 'Z' || 'z':
        path.close();
        cx = sx;
        cy = sy;
    }
  }
  return path;
}

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../sketch/assembly.dart';
import '../sketch/part.dart';
import '../sketch/solid.dart';
import 'camera.dart';
import 'sketch_canvas.dart';

/// Shared 3D scene: every part's extrude rendered in world space (per-part
/// color), assembled by mates. Tap two connectors (on different parts) to
/// fasten them; the assembly re-solves and snaps together.
class AssemblyView extends StatefulWidget {
  const AssemblyView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<AssemblyView> createState() => _AssemblyViewState();
}

class _AssemblyViewState extends State<AssemblyView> {
  double _yaw = 0.6;
  double _pitch = -0.5;
  double _zoom = 1; // scroll-wheel / pinch zoom (shrinks the fit radius)
  Offset _pan = Offset.zero; // screen-space camera pan (two-finger drag)
  double _scaleStartZoom = 1;
  bool _shaded = false; // wireframe (default) vs flat-shaded solid
  Camera? _camera;
  ({int part, int connector})? _selected;

  static const _palette = [
    Color(0xFF4DD0E1),
    Color(0xFFFFB74D),
    Color(0xFF81C784),
    Color(0xFFE57373),
    Color(0xFFBA68C8),
  ];

  void _orbit(Offset d) {
    setState(() {
      _yaw += d.dx * 0.01;
      _pitch = (_pitch + d.dy * 0.01).clamp(-math.pi / 2, math.pi / 2);
    });
  }

  // One finger orbits; two fingers pinch-zoom AND pan.
  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      setState(() {
        _zoom = (_scaleStartZoom * d.scale).clamp(0.1, 40.0);
        _pan += d.focalPointDelta;
      });
    } else {
      _orbit(d.focalPointDelta);
    }
  }

  // Scroll up (negative delta) zooms in. Clamped so the model can't be lost.
  void _zoomBy(double dy) => setState(() {
        _zoom = (_zoom * (dy > 0 ? 1 / 1.12 : 1.12)).clamp(0.1, 40.0);
      });

  void _tap(Offset p, List<_PartScene> scenes) {
    final cam = _camera;
    if (cam == null) return;
    ({int part, int connector})? hit;
    var bestDist = 16.0;
    for (final s in scenes) {
      for (var j = 0; j < s.connectors.length; j++) {
        final d = (cam.project(s.connectors[j]) - p).distance;
        if (d < bestDist) {
          bestDist = d;
          hit = (part: s.partIndex, connector: j);
        }
      }
    }
    if (hit == null) return;
    // Tapping an already-mated point unmates it.
    final existing = widget.controller.mateIndexFor(hit.part, hit.connector);
    if (existing != null) {
      widget.controller.removeMate(existing);
      setState(() => _selected = null);
      return;
    }
    final sel = _selected;
    if (sel == null) {
      setState(() => _selected = hit);
    } else if (sel.part != hit.part) {
      widget.controller.addMate(sel.part, sel.connector, hit.part, hit.connector);
      setState(() => _selected = null);
    } else {
      setState(() => _selected = hit); // re-pick on same part
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final scenes = _buildScenes();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Assembly'),
            actions: [
              IconButton(
                tooltip: _shaded ? 'Show wireframe' : 'Show shaded',
                icon: Icon(_shaded ? Icons.grid_on : Icons.view_in_ar),
                onPressed: () => setState(() => _shaded = !_shaded),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('${widget.controller.mates.length} mates',
                      style: const TextStyle(fontSize: 12, color: Color(0xFFFFC857))),
                ),
              ),
              if (widget.controller.mates.isNotEmpty)
                IconButton(
                  tooltip: 'Clear all mates',
                  icon: const Icon(Icons.link_off),
                  onPressed: () => widget.controller.clearMates(),
                ),
            ],
          ),
          body: scenes.isEmpty
              ? const Center(
                  child: Text('Draw at least one closed part to assemble.'))
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(builder: (context, c) {
                        final cam = _fitCamera(Size(c.maxWidth, c.maxHeight), scenes);
                        _camera = cam;
                        return Listener(
                          onPointerSignal: (e) {
                            if (e is PointerScrollEvent) {
                              _zoomBy(e.scrollDelta.dy);
                            }
                          },
                          child: GestureDetector(
                            onScaleStart: (_) => _scaleStartZoom = _zoom,
                            onScaleUpdate: _onScaleUpdate,
                            onTapUp: (e) => _tap(e.localPosition, scenes),
                            child: Container(
                              color: const Color(0xFF101418),
                              child: CustomPaint(
                                painter:
                                    _ScenePainter(scenes, cam, _selected, _shaded),
                                size: Size.infinite,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text('Tap two mate points on different parts to fasten; '
                          'tap a mated point to unmate.',
                          style: TextStyle(fontSize: 12, color: Colors.white54)),
                    ),
                  ],
                ),
        );
      },
    );
  }

  List<_PartScene> _buildScenes() {
    final bodies =
        assemblyBodies(widget.controller.parts, widget.controller.mates);
    return [
      for (var k = 0; k < bodies.length; k++)
        _PartScene(
          partIndex: bodies[k].partIndex,
          color: _palette[k % _palette.length],
          verts: bodies[k].verts,
          edges: bodies[k].edges,
          faces: bodies[k].faces,
          connectors: bodies[k].connectors,
        ),
    ];
  }

  Camera _fitCamera(Size size, List<_PartScene> scenes) {
    final all = [for (final s in scenes) ...s.verts];
    var c = const Vec3(0, 0, 0);
    for (final v in all) {
      c = c + v;
    }
    c = c * (1.0 / all.length);
    var r = 0.0;
    for (final v in all) {
      r = math.max(r, (v - c).length);
    }
    return Camera(
        size: size,
        center: c,
        radius: r / _zoom,
        yaw: _yaw,
        pitch: _pitch,
        pan: _pan);
  }
}

/// One renderable assembly body: world-space geometry + mate-point positions,
/// tagged with the base [partIndex] it belongs to (for mate selection).
typedef AssemblyBody = ({
  int partIndex,
  List<Vec3> verts,
  List<List<int>> edges,
  List<List<int>> faces,
  List<Vec3> connectors,
});

/// Builds the assembly's bodies: one per BASE part (a root, no parent), with its
/// face features merged in-context — each feature extruded on its own plane so
/// it sits on the parent face, not as a separate parked body. The whole family
/// is placed by the root's assembly transform; mates connect base bodies.
List<AssemblyBody> assemblyBodies(List<Part> parts, List<Mate> mates) {
  final transforms = solveAssembly(parts, mates);
  final bodies = <AssemblyBody>[];
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (p.parent != null) continue; // features are merged into their root
    final rootSolid = p.buildSolid();

    final verts = <Vec3>[];
    final edges = <List<int>>[];
    final faces = <List<int>>[];
    void add(Solid s) {
      final base = verts.length;
      verts.addAll(s.vertices);
      for (final e in s.edges) {
        edges.add([e[0] + base, e[1] + base]);
      }
      for (final fc in s.faces) {
        faces.add([for (final vi in fc) vi + base]);
      }
    }

    if (rootSolid != null) add(rootSolid);
    for (final f in parts) {
      if (f.parent == null || !identical(f.root, p)) continue;
      final fs = f.solidOnPlane();
      if (fs != null) add(fs);
    }
    if (verts.isEmpty) continue;

    final xf = transforms[i]!;
    bodies.add((
      partIndex: i,
      verts: [for (final v in verts) xf.apply(v)],
      edges: edges,
      faces: faces,
      connectors: rootSolid == null
          ? const <Vec3>[]
          : [for (final con in p.connectors) xf.apply(con.origin(rootSolid))],
    ));
  }
  return bodies;
}

/// Newell's-method normal of a (possibly non-planar) polygon ring — robust to
/// winding, used for flat shading in the assembly view.
Vec3 _newell(List<Vec3> verts, List<int> ring) {
  var nx = 0.0, ny = 0.0, nz = 0.0;
  for (var i = 0; i < ring.length; i++) {
    final a = verts[ring[i]], b = verts[ring[(i + 1) % ring.length]];
    nx += (a.y - b.y) * (a.z + b.z);
    ny += (a.z - b.z) * (a.x + b.x);
    nz += (a.x - b.x) * (a.y + b.y);
  }
  return Vec3(nx, ny, nz);
}

class _PartScene {
  _PartScene({
    required this.partIndex,
    required this.color,
    required this.verts,
    required this.edges,
    required this.faces,
    required this.connectors,
  });
  final int partIndex;
  final Color color;
  final List<Vec3> verts;
  final List<List<int>> edges;
  final List<List<int>> faces;
  final List<Vec3> connectors;
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.scenes, this.cam, this.selected, this.shaded);

  final List<_PartScene> scenes;
  final Camera cam;
  final ({int part, int connector})? selected;
  final bool shaded;

  @override
  void paint(Canvas canvas, Size size) {
    if (shaded) _paintShaded(canvas);
    for (final s in scenes) {
      final edge = Paint()
        ..color = shaded ? Colors.black.withValues(alpha: 0.35) : s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = shaded ? 1.0 : 1.6;
      for (final e in s.edges) {
        canvas.drawLine(cam.project(s.verts[e[0]]), cam.project(s.verts[e[1]]), edge);
      }
      for (var j = 0; j < s.connectors.length; j++) {
        final isSel = selected?.part == s.partIndex && selected?.connector == j;
        final p = cam.project(s.connectors[j]);
        canvas.drawCircle(p, isSel ? 7 : 4,
            Paint()..color = isSel ? Colors.white : const Color(0xFFFFC857));
      }
    }
  }

  /// Flat-shaded fill of every face across all bodies, sorted back-to-front.
  void _paintShaded(Canvas canvas) {
    final faces = <({_PartScene s, List<int> ring, double depth})>[];
    for (final s in scenes) {
      for (final ring in s.faces) {
        var c = const Vec3(0, 0, 0);
        for (final vi in ring) {
          c = c + s.verts[vi];
        }
        c = c * (1.0 / ring.length);
        faces.add((s: s, ring: ring, depth: cam.depthOf(c)));
      }
    }
    faces.sort((a, b) => a.depth.compareTo(b.depth)); // far first
    const bg = Color(0xFF101418);
    for (final f in faces) {
      final rn = cam.rotate(_newell(f.s.verts, f.ring));
      final len = rn.length;
      final facing = len < 1e-9 ? 0.0 : (rn.z / len).abs();
      final shade = 0.28 + 0.72 * facing;
      final fill = Color.lerp(bg, f.s.color, shade)!;
      final path = Path();
      for (var k = 0; k < f.ring.length; k++) {
        final p = cam.project(f.s.verts[f.ring[k]]);
        k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = fill);
    }
  }

  @override
  bool shouldRepaint(_ScenePainter old) => true;
}

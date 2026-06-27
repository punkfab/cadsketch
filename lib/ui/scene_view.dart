import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../sketch/decomposition.dart';
import '../sketch/entities.dart';
import '../sketch/part.dart';
import '../sketch/plane.dart';
import '../sketch/ribbon.dart';
import '../sketch/solid.dart';
import 'camera.dart';
import 'sketch_canvas.dart';

// The unified workspace: split view, 3D assembly (orbit) + 2D sketch on the
// active plane — no orbit/sketch mode toggle. Every part is a sketch on a plane
// (base XY/XZ/YZ or a body face); each is region-partition-decomposed and the
// whole lot composes into one scene, recomputed from the live sketches every
// build (associative). Tap a body to select it (its sketch opens in the 2D
// pane); with a face selected, "sketch on face" starts a new plane-sketch in
// that face's frame — multi-plane / "rough 3D by construction".
class SceneView extends StatefulWidget {
  const SceneView({super.key, required this.controller});

  final SketchController controller;

  @override
  State<SceneView> createState() => _SceneViewState();
}

class _SceneViewState extends State<SceneView> {
  double _yaw = 0.6;
  double _pitch = -0.5;
  double _explode = 0;
  double _zoom = 1; // scroll-wheel zoom (shrinks the camera radius)
  int? _selItem; // selected scene item (flattened index)
  int? _selFace; // selected face on that item (for "sketch on face")
  int? _hovItem; // face under the cursor (hover preview of what a tap selects)
  int? _hovFace;

  static const _palette = [
    Color(0xFF4DD0E1),
    Color(0xFFFFC857),
    Color(0xFFE57373),
    Color(0xFF81C784),
    Color(0xFFBA68C8),
    Color(0xFF64B5F6),
    Color(0xFFFFB74D),
    Color(0xFF4DB6AC),
  ];

  void _orbit(Offset d) => setState(() {
        _yaw += d.dx * 0.01;
        _pitch = (_pitch + d.dy * 0.01).clamp(-1.5, 1.5);
      });

  Camera _camera(Size size, _Scene scene) => Camera(
        size: size,
        center: scene.center,
        radius: (scene.radius * (1 + _explode * 1.4) + 1) / _zoom,
        yaw: _yaw,
        pitch: _pitch,
      );

  // Scroll up (negative delta) zooms in. Clamped so you can't lose the model.
  void _zoomBy(double dy) => setState(() {
        _zoom = (_zoom * (dy > 0 ? 1 / 1.12 : 1.12)).clamp(0.2, 12.0);
      });

  ({int item, int face})? _hit(Offset p, _Scene scene, Camera cam) {
    int? bi, bf;
    var bestDepth = -double.infinity;
    for (var i = 0; i < scene.items.length; i++) {
      final solid = scene.items[i].solid;
      final shift = scene.explode(i, _explode);
      for (var f = 0; f < solid.faces.length; f++) {
        final ring = solid.faces[f];
        final poly = [for (final vi in ring) cam.project(solid.vertices[vi] + shift)];
        if (!_pointInPoly(p, poly)) continue;
        // Depth of THIS face's surface directly under the cursor (ray-plane
        // hit), so the face actually in front wins. Averaging vertex depths
        // made the big end caps beat the side faces, so picking felt random.
        final hit =
            cam.rayPlaneHit(p, solid.faceCentroid(f) + shift, solid.faceNormal(f));
        final d = hit == null ? -double.infinity : cam.depthOf(hit);
        if (d > bestDepth) {
          bestDepth = d;
          bi = i;
          bf = f;
        }
      }
    }
    return bi == null ? null : (item: bi, face: bf!);
  }

  static bool _pointInPoly(Offset p, List<Offset> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  void _tap(Offset p, _Scene scene, Camera cam) {
    final h = _hit(p, scene, cam);
    setState(() {
      _selItem = h?.item;
      _selFace = h?.face;
    });
    if (h != null) widget.controller.setActive(scene.items[h.item].authored);
  }

  /// Hover preview: highlight the face a tap would select, so picking is
  /// legible (no more guessing whether you'll get a cap or a side face).
  void _hover(Offset p, _Scene scene, Camera cam) {
    final h = _hit(p, scene, cam);
    if (h?.item == _hovItem && h?.face == _hovFace) return;
    setState(() {
      _hovItem = h?.item;
      _hovFace = h?.face;
    });
  }

  void _clearHover() {
    if (_hovItem == null && _hovFace == null) return;
    setState(() {
      _hovItem = null;
      _hovFace = null;
    });
  }

  void _sketchOnSelectedFace(_Scene scene) {
    final i = _selItem, f = _selFace;
    if (i == null || f == null) return;
    final solid = scene.items[i].solid;
    final plane = SketchPlane.fromFace(solid, f);
    // Project the picked face's outline into the new plane's 2D coords so the
    // canvas can show it as a guide and anchor the sketch onto the face.
    final reference = [for (final vi in solid.faces[f]) plane.to2d(solid.vertices[vi])];
    widget.controller
        .addPlaneSketch(plane, name: 'Face sketch', reference: reference);
    setState(() {
      _selItem = null;
      _selFace = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final scene = _buildScene(widget.controller.parts);
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final pane3d = _pane3d(scene);
            final pane2d = _pane2d();
            return Column(
              children: [
                Expanded(
                  child: wide
                      ? Row(children: [
                          Expanded(flex: 11, child: pane3d),
                          const VerticalDivider(width: 1),
                          Expanded(flex: 9, child: pane2d),
                        ])
                      : Column(children: [
                          Expanded(child: pane3d),
                          const Divider(height: 1),
                          Expanded(child: pane2d),
                        ]),
                ),
                _controls(scene),
              ],
            );
          },
        );
      },
    );
  }

  Widget _pane3d(_Scene scene) {
    return Container(
      color: const Color(0xFF0E1216),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final cam = _camera(size, scene);
          return Stack(
            children: [
              Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) _zoomBy(e.scrollDelta.dy);
                },
                child: MouseRegion(
                  onHover: (e) => _hover(e.localPosition, scene, cam),
                  onExit: (_) => _clearHover(),
                  child: GestureDetector(
                    onPanUpdate: (e) => _orbit(e.delta),
                    onTapUp: (e) => _tap(e.localPosition, scene, cam),
                    child: CustomPaint(
                      painter: _ScenePainter(scene, widget.controller.parts, cam,
                          _explode, _selItem, _selFace, _hovItem, _hovFace, _palette),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              if (_selFace != null)
                Positioned(
                  right: 8,
                  top: 8,
                  child: FilledButton.icon(
                    onPressed: () => _sketchOnSelectedFace(scene),
                    icon: const Icon(Icons.draw, size: 18),
                    label: const Text('Sketch on face'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _pane2d() {
    return Container(
      color: const Color(0xFF101418),
      child: Stack(
        children: [
          SketchCanvas(controller: widget.controller),
          Positioned(
            left: 8,
            top: 6,
            child: Text('Sketch · ${widget.controller.active.name}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _controls(_Scene scene) {
    final sel = _selItem;
    final c = widget.controller;
    final Widget body;
    if (sel != null && sel < scene.items.length) {
      final region = scene.items[sel].region;
      body = Row(children: [
        IconButton(
          tooltip: 'Deselect',
          icon: const Icon(Icons.arrow_back, size: 18),
          onPressed: () => setState(() {
            _selItem = null;
            _selFace = null;
          }),
        ),
        Flexible(
          child: Text(scene.items[sel].name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
        const SizedBox(width: 12),
        const Text('Depth', style: TextStyle(color: Colors.white54, fontSize: 12)),
        Expanded(
          child: Slider(
            value: (c.active.regionDepths[region] ?? c.active.depth).clamp(5, 400),
            min: 5,
            max: 400,
            onChanged: (v) => c.setRegionDepth(region, v),
          ),
        ),
        if (c.active.regionDepths.containsKey(region))
          IconButton(
            tooltip: 'Reset to base depth',
            icon: const Icon(Icons.restart_alt, size: 18),
            onPressed: () => c.clearRegionDepth(region),
          ),
        IconButton(
          tooltip: 'Delete part',
          icon: const Icon(Icons.delete_outline, size: 18),
          color: Colors.redAccent,
          onPressed: () {
            c.removePart(scene.items[sel].authored);
            setState(() {
              _selItem = null;
              _selFace = null;
            });
          },
        ),
      ]);
    } else {
      body = Row(children: [
        Flexible(
          child: Text(
            '${scene.items.length} part${scene.items.length == 1 ? '' : 's'}'
            ' · ${scene.mates.length} mate${scene.mates.length == 1 ? '' : 's'}'
            '${scene.isEmpty ? '' : ' · tap a part'}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        const SizedBox(width: 12),
        const Icon(Icons.open_in_full, size: 16, color: Colors.white54),
        Expanded(
          child: Slider(
            value: _explode,
            onChanged: (v) => setState(() => _explode = v),
          ),
        ),
        const Text('Depth', style: TextStyle(color: Colors.white54, fontSize: 12)),
        Expanded(
          child: Slider(
            value: c.active.depth.clamp(5, 400),
            min: 5,
            max: 400,
            onChanged: (v) => c.setDepth(v),
          ),
        ),
      ]);
    }
    return Container(
      color: const Color(0xFF161C22),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: body,
    );
  }
}

// --- Flattened multi-plane scene (derived; recomputed every build) ---

/// Ribbon width (model units) for embossed strokes, and a region-index base for
/// emboss items so they never collide with real decomposition region indices.
const double _embossWidth = 2.2;
const int _embossRegionBase = 1 << 20;

class _Item {
  _Item(this.authored, this.region, this.solid, this.name, this.center);
  final int authored; // index into controller.parts
  final int region; // region index within that part's decomposition
  final Solid solid; // in-place world solid
  final String name;
  final Vec3 center;
}

class _Mate {
  _Mate(this.itemA, this.faceA, this.itemB, this.faceB);
  final int itemA, faceA, itemB, faceB;
}

class _Scene {
  _Scene(this.items, this.mates, this.center, this.radius);
  final List<_Item> items;
  final List<_Mate> mates;
  final Vec3 center;
  final double radius;

  bool get isEmpty => items.isEmpty;

  Vec3 explode(int i, double t) {
    if (t <= 0) return const Vec3(0, 0, 0);
    final dir = items[i].center - center;
    final d = dir.length;
    final unit = d < 1e-6 ? const Vec3(0, 0, 1) : dir * (1 / d);
    return unit * (t * radius * 1.4);
  }
}

/// Decomposes every part on its own plane and flattens into one scene.
_Scene _buildScene(List<Part> parts) {
  final items = <_Item>[];
  final mates = <_Mate>[];
  final index = <String, int>{}; // "authored:region" -> item index
  for (var ai = 0; ai < parts.length; ai++) {
    final p = parts[ai];
    // Emboss: raise this part's surface marks (text / freehand) into 3D by
    // thickening each stroke into a ribbon and extruding it on the plane — the
    // same extrude primitive, so "extruded text" is just an extruded sketch.
    if (p.embossDepth > 0) {
      var ti = 0;
      for (final e in p.decorations) {
        if (e is RawStroke) {
          final ribbon = strokeRibbon(e.points, _embossWidth);
          if (ribbon.length >= 3) {
            final solid = extrudeOnPlane(ribbon, p.plane, p.embossDepth);
            items.add(_Item(
                ai, _embossRegionBase + ti, solid, '${p.name} · text', solid.centroid));
            ti++;
          }
        }
      }
    }
    final d = decompose(p.sketch,
        depth: p.depth, plane: p.plane, depthOverrides: p.regionDepths);
    // No regions (imported mesh, or a circle-only sketch -> cylinder): show the
    // part's own solid as a single body so nothing silently disappears.
    if (d.parts.isEmpty) {
      final s = p.buildSolid();
      if (s != null) {
        index['$ai:0'] = items.length;
        items.add(_Item(ai, 0, s, p.name, s.centroid));
      }
      continue;
    }
    for (var ri = 0; ri < d.parts.length; ri++) {
      final dp = d.parts[ri];
      index['$ai:$ri'] = items.length;
      final name = parts.length > 1 ? '${p.name} · ${dp.name}' : dp.name;
      items.add(_Item(ai, ri, dp.solid, name, dp.center));
    }
    for (final m in d.mates) {
      final a = index['$ai:${m.partA}'], b = index['$ai:${m.partB}'];
      if (a != null && b != null) mates.add(_Mate(a, m.faceA, b, m.faceB));
    }
  }
  if (items.isEmpty) return _Scene(const [], const [], const Vec3(0, 0, 0), 150);
  var c = const Vec3(0, 0, 0);
  for (final it in items) {
    c = c + it.center;
  }
  c = c * (1.0 / items.length);
  var r = 1.0;
  for (final it in items) {
    for (final v in it.solid.vertices) {
      final dd = (v - c).length;
      if (dd > r) r = dd;
    }
  }
  return _Scene(items, mates, c, r);
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.scene, this.parts, this.cam, this.explode, this.selItem,
      this.selFace, this.hovItem, this.hovFace, this.palette);

  final _Scene scene;
  final List<Part> parts;
  final Camera cam;
  final double explode;
  final int? selItem;
  final int? selFace;
  final int? hovItem;
  final int? hovFace;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    // Live sketches on their planes (the active part brighter).
    for (var ai = 0; ai < parts.length; ai++) {
      final p = parts[ai];
      final paint = Paint()
        ..color = Colors.cyanAccent.shade700.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      for (final seg in p.sketch.segments) {
        canvas.drawLine(cam.project(p.plane.to3d(p.sketch.points[seg.a])),
            cam.project(p.plane.to3d(p.sketch.points[seg.b])), paint);
      }
      // Surface marks (freehand / text) live on the part's datum too — same
      // primitive, so they ride the same plane mapping into the 3D scene. When
      // embossed they're drawn as raised ribbons (scene items) instead.
      if (p.embossDepth <= 0) {
        for (final e in p.decorations) {
          if (e is RawStroke) {
            for (var k = 0; k + 1 < e.points.length; k++) {
              canvas.drawLine(cam.project(p.plane.to3d(e.points[k])),
                  cam.project(p.plane.to3d(e.points[k + 1])), paint);
            }
          }
        }
      }
    }

    // Parts (wireframe), shifted by explode.
    for (var i = 0; i < scene.items.length; i++) {
      final solid = scene.items[i].solid;
      final shift = scene.explode(i, explode);
      final isSel = i == selItem;
      final paint = Paint()
        ..color = isSel ? Colors.white : palette[i % palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSel ? 2.6 : 1.6
        ..strokeCap = StrokeCap.round;
      for (final e in solid.edges) {
        canvas.drawLine(cam.project(solid.vertices[e[0]] + shift),
            cam.project(solid.vertices[e[1]] + shift), paint);
      }
      // Hover preview: faint fill on the face a tap would select (unless it's
      // already the selected face, drawn brighter below).
      if (i == hovItem &&
          hovFace != null &&
          !(isSel && hovFace == selFace)) {
        canvas.drawPath(_facePath(solid, solid.faces[hovFace!], shift),
            Paint()..color = Colors.cyanAccent.withValues(alpha: 0.14));
      }
      // Highlight the selected face (the candidate sketch plane).
      if (isSel && selFace != null) {
        canvas.drawPath(_facePath(solid, solid.faces[selFace!], shift),
            Paint()..color = Colors.white.withValues(alpha: 0.18));
      }
    }

    // Auto-captured mating surfaces.
    final mateDot = Paint()..color = Colors.white;
    final mateLine = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in scene.mates) {
      _connector(canvas, m.itemA, m.faceA, mateDot, mateLine);
      _connector(canvas, m.itemB, m.faceB, mateDot, mateLine);
    }
  }

  /// Projected outline of a solid's face ring (shifted by explode).
  Path _facePath(Solid solid, List<int> ring, Vec3 shift) {
    final path = Path();
    for (var k = 0; k < ring.length; k++) {
      final pt = cam.project(solid.vertices[ring[k]] + shift);
      k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    return path..close();
  }

  void _connector(Canvas canvas, int item, int face, Paint dot, Paint line) {
    final solid = scene.items[item].solid;
    final shift = scene.explode(item, explode);
    final origin = solid.faceCentroid(face) + shift;
    final tip = origin + solid.faceNormal(face) * (scene.radius * 0.12);
    final o = cam.project(origin);
    canvas.drawCircle(o, 3, dot);
    canvas.drawLine(o, cam.project(tip), line);
  }

  @override
  bool shouldRepaint(_ScenePainter old) => true;
}

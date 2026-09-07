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
  final double _explode = 0; // explode retired from the UI; kept at 0
  double _zoom = 1; // scroll-wheel zoom (shrinks the camera radius)
  int? _selItem; // selected scene item (flattened index)
  int? _selFace; // selected face on that item (for "sketch on face")
  int? _hovItem; // face under the cursor (hover preview of what a tap selects)
  int? _hovFace;
  Offset? _lastTapPt; // last tap location, to detect same-spot re-clicks
  int _cycleIdx = 0; // which stacked candidate a re-click at the same spot picks

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

  double _scaleStartZoom = 1; // _zoom captured at pinch start

  void _orbit(Offset d) => setState(() {
        _yaw += d.dx * 0.01;
        _pitch = (_pitch + d.dy * 0.01).clamp(-1.5, 1.5);
      });

  // Scale gesture: one finger orbits (focalPointDelta), two fingers pinch-dolly.
  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      setState(() => _zoom = (_scaleStartZoom * d.scale).clamp(0.2, 12.0));
    } else {
      _orbit(d.focalPointDelta);
    }
  }

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

  /// All faces under the cursor, front-most first. Back-faces (normals pointing
  /// away from the camera) are culled so a far cap can't win over the face you
  /// can actually see. Depth is the ray-plane hit of THIS face's surface under
  /// the cursor (averaging vertices let big end caps beat side faces, so picking
  /// felt random). The returned order is what click-to-cycle steps through.
  List<({int item, int face})> _hitAll(Offset p, _Scene scene, Camera cam) {
    final cands = <({int item, int face, double depth})>[];
    for (var i = 0; i < scene.items.length; i++) {
      final solid = scene.items[i].solid;
      final shift = scene.explode(i, _explode);
      for (var f = 0; f < solid.faces.length; f++) {
        final ring = solid.faces[f];
        final poly = [for (final vi in ring) cam.project(solid.vertices[vi] + shift)];
        if (!_pointInPoly(p, poly)) continue;
        final c = solid.faceCentroid(f) + shift;
        final n = solid.faceNormal(f);
        // Depth of THIS face's surface under the cursor (ray vs the face's
        // plane). We do NOT cull by normal direction: extruded caps share the
        // profile winding, so one cap's normal points inward, and a normal-based
        // front-face test would wrongly drop whichever faces are wound "inward"
        // for some orientations. The plane is the same regardless of normal sign,
        // so the front-most depth already selects the visible face; occluded
        // faces just sort behind and are reachable by click-to-cycle.
        final hit = cam.rayPlaneHit(p, c, n);
        final d = hit == null ? -double.infinity : cam.depthOf(hit);
        cands.add((item: i, face: f, depth: d));
      }
    }
    cands.sort((a, b) => b.depth.compareTo(a.depth)); // front-most first
    return [for (final c in cands) (item: c.item, face: c.face)];
  }

  ({int item, int face})? _hit(Offset p, _Scene scene, Camera cam) {
    final all = _hitAll(p, scene, cam);
    return all.isEmpty ? null : all.first;
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

  // A mate point of the active part under the cursor, or null.
  int? _hitConnector(Offset p, Camera cam) {
    final part = widget.controller.active;
    final solid = part.buildSolid();
    if (solid == null) return null;
    int? best;
    var bestD = 14.0;
    for (var j = 0; j < part.connectors.length; j++) {
      final con = part.connectors[j];
      if (con.faceIndex < 0 || con.faceIndex >= solid.faces.length) continue;
      final d = (cam.project(con.origin(solid)) - p).distance;
      if (d < bestD) {
        bestD = d;
        best = j;
      }
    }
    return best;
  }

  void _tap(Offset p, _Scene scene, Camera cam) {
    // Tapping a mate-point pin removes just that point.
    final con = _hitConnector(p, cam);
    if (con != null) {
      widget.controller.removeConnector(widget.controller.activeIndex, con);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Mate point removed'),
            duration: Duration(seconds: 2)));
      }
      return;
    }
    final all = _hitAll(p, scene, cam);
    // Re-clicking the same spot steps to the next face behind the current one;
    // a click at a new spot resets to the front-most (closest) face.
    final same = _lastTapPt != null && (p - _lastTapPt!).distance < 6;
    _cycleIdx = (same && all.isNotEmpty) ? (_cycleIdx + 1) % all.length : 0;
    _lastTapPt = p;
    final h = all.isEmpty ? null : all[_cycleIdx];
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

  // Adds a mate point (connector) on the selected face of the active part: its
  // origin is the face centroid and its normal the face normal. Fasten two mate
  // points on different parts in the Assembly view to bring the faces flush.
  void _addMatePoint(_Scene scene) {
    final i = _selItem, f = _selFace;
    if (i == null || f == null) return;
    // The face was picked on the scene ITEM's solid (a decomposition region for
    // a multi-region part), but a connector is interpreted against the part's
    // OWN solid. Map the picked face to the nearest face on that solid so the
    // mate point lands on the right face regardless of decomposition.
    final partSolid = widget.controller.active.buildSolid();
    if (partSolid == null) return;
    final pickedCentroid = scene.items[i].solid.faceCentroid(f);
    widget.controller.addConnector(partSolid.faceNearest(pickedCentroid));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Mate point added — open Assembly and tap two mate points '
            'on different parts to fasten them.'),
        duration: Duration(seconds: 3),
      ));
    }
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
        // One part per tab: the 3D view shows only the active part (the full
        // assembly lives in the Assembly view).
        final scene = _buildScene(widget.controller.parts,
            onlyIndex: widget.controller.activeIndex);
        return LayoutBuilder(
          builder: (context, constraints) {
            // Side-by-side only in landscape with room; in portrait (e.g. an
            // iPad held upright, ~1024pt wide) stack 3D on top, 2D below.
            final wide = constraints.maxWidth >= 720 &&
                constraints.maxWidth > constraints.maxHeight;
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
    // Clip to the pane: zoomed-in geometry must not paint past the pane edge
    // (it was spilling up into the parts tabs above).
    return ClipRect(
      child: Container(
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
                    onScaleStart: (_) => _scaleStartZoom = _zoom,
                    onScaleUpdate: _onScaleUpdate,
                    onTapUp: (e) => _tap(e.localPosition, scene, cam),
                    child: CustomPaint(
                      painter: _ScenePainter(
                          scene,
                          widget.controller.parts,
                          cam,
                          _explode,
                          _selItem,
                          _selFace,
                          _hovItem,
                          _hovFace,
                          _palette,
                          widget.controller.activeIndex),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              if (_selFace != null)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _sketchOnSelectedFace(scene),
                        icon: const Icon(Icons.draw, size: 18),
                        label: const Text('Sketch on face'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _addMatePoint(scene),
                        icon: const Icon(Icons.push_pin_outlined, size: 18),
                        label: const Text('Add mate point'),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
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
    // A face sketch is a feature ON a body: expose whether it adds or cuts, its
    // direction, and its length right here so the outcome is never implicit.
    final faceRow = c.active.referenceLoop != null ? _faceFeatureRow(c) : null;
    return Container(
      color: const Color(0xFF161C22),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: faceRow == null
          ? body
          : Column(mainAxisSize: MainAxisSize.min, children: [faceRow, body]),
    );
  }

  Widget _faceFeatureRow(SketchController c) {
    final part = c.active;
    final subtractive = part.isSubtractive;
    final accent = subtractive ? const Color(0xFFE57373) : const Color(0xFF81C784);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        const Icon(Icons.account_tree_outlined, size: 16, color: Colors.white54),
        const SizedBox(width: 8),
        SegmentedButton<FeatureOp>(
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: const [
            ButtonSegment(
                value: FeatureOp.union,
                icon: Icon(Icons.add, size: 15),
                label: Text('Union')),
            ButtonSegment(
                value: FeatureOp.difference,
                icon: Icon(Icons.remove, size: 15),
                label: Text('Cut')),
          ],
          selected: {part.operation},
          onSelectionChanged: (s) => c.setOperation(s.first),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: part.flipDirection ? 'Un-flip direction' : 'Flip direction',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.swap_vert,
              size: 18, color: part.flipDirection ? accent : Colors.white54),
          onPressed: c.toggleFlipDirection,
        ),
        // Live read-out: which way the extrude goes and how it reads.
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(subtractive ? Icons.south : Icons.north, size: 15, color: accent),
          const SizedBox(width: 2),
          Text(subtractive ? 'cuts in' : 'adds out',
              style: TextStyle(color: accent, fontSize: 12)),
        ]),
        const SizedBox(width: 12),
        const Text('Length', style: TextStyle(color: Colors.white54, fontSize: 12)),
        Expanded(
          child: Slider(
            value: part.depth.clamp(5, 400),
            min: 5,
            max: 400,
            onChanged: c.setDepth,
          ),
        ),
      ]),
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
// [onlyIndex] restricts the scene to a single authored part (the active tab) so
// the 3D view shows one part at a time; null builds the whole assembly. The real
// part index is preserved as `authored` either way, so tap/select still map back.
_Scene _buildScene(List<Part> parts, {int? onlyIndex}) {
  final items = <_Item>[];
  final mates = <_Mate>[];
  final index = <String, int>{}; // "authored:region" -> item index
  for (var ai = 0; ai < parts.length; ai++) {
    if (onlyIndex != null && ai != onlyIndex) continue;
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
        depth: p.depth,
        plane: p.plane,
        depthOverrides: p.regionDepths,
        dirSign: p.dirSign);
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
      this.selFace, this.hovItem, this.hovFace, this.palette, this.activeIndex);

  final _Scene scene;
  final List<Part> parts;
  final int activeIndex; // only this part's live sketch overlay is drawn
  final Camera cam;
  final double explode;
  final int? selItem;
  final int? selFace;
  final int? hovItem;
  final int? hovFace;
  final List<Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    // Live sketch of the active part on its plane — only once it forms a solid
    // (a closed profile / circle). An open, non-closed path renders nothing in
    // 3D until it can actually be built.
    for (var ai = 0; ai < parts.length; ai++) {
      if (ai != activeIndex) continue;
      final p = parts[ai];
      if (p.buildSolid() == null) continue;
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
      // A face feature reads by colour: green adds material (union), red cuts
      // (difference) — so "is this a union or a difference?" is answered on
      // sight. Base bodies keep the neutral palette.
      final part = parts[scene.items[i].authored];
      final feature = part.referenceLoop != null;
      final baseColor = feature
          ? (part.isSubtractive
              ? const Color(0xFFE57373)
              : const Color(0xFF81C784))
          : palette[i % palette.length];
      final paint = Paint()
        ..color = isSel ? Colors.white : baseColor
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

    // User-added mate points on the active part: a pin at the face centroid with
    // a stub along the face normal (the frame that fastens flush to another).
    final activePart = parts[activeIndex];
    final aSolid = activePart.buildSolid();
    if (aSolid != null) {
      final pinFill = Paint()..color = const Color(0xFFFFC857);
      final pinLine = Paint()
        ..color = const Color(0xFFFFC857)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final con in activePart.connectors) {
        if (con.faceIndex < 0 || con.faceIndex >= aSolid.faces.length) continue;
        final o = con.origin(aSolid);
        final tip = o + con.normal(aSolid).normalized * (scene.radius * 0.18);
        final so = cam.project(o);
        canvas.drawCircle(so, 5, pinFill);
        canvas.drawLine(so, cam.project(tip), pinLine);
      }
    }

    // Origin datum of the active part: an XYZ axis triad at the sketch's
    // bounding-box centre — only once the part forms a solid (nothing floats in
    // 3D before then).
    final o2 = activePart.originLocal();
    if (o2 != null && aSolid != null) {
      final plane = activePart.plane;
      final o3 = plane.to3d(o2);
      final so = cam.project(o3);
      final len = scene.radius * 0.3;
      void axis(Vec3 dir, Color color) {
        canvas.drawLine(
            so,
            cam.project(o3 + dir.normalized * len),
            Paint()
              ..color = color
              ..strokeWidth = 2
              ..strokeCap = StrokeCap.round);
      }

      axis(plane.u, const Color(0xFFFF5252)); // X — red
      axis(plane.v, const Color(0xFF69F0AE)); // Y — green
      axis(plane.normal, const Color(0xFF448AFF)); // Z — blue
      canvas.drawCircle(so, 3.5, Paint()..color = Colors.white);
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

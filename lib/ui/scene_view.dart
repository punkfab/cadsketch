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
  bool _shaded = false; // wireframe (default) vs flat-shaded solid rendering
  int? _selItem; // selected scene item (flattened index, for highlight only)
  int? _selFace; // selected face on that item (for "sketch on face")
  // Captured at tap time so the action survives the scene rebuild that setActive
  // triggers (an item INDEX can go stale; the solid + authored part don't).
  Solid? _selSolid;
  int? _selAuthored;
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
  Offset _pan = Offset.zero; // screen-space camera pan (two-finger / right-drag)

  // Right- or middle-button drag pans (like the 2D canvas); one-finger/left-drag
  // still orbits. A pan pointer suppresses orbit for the duration of the drag.
  int? _panPointer;
  Offset _panLast = Offset.zero;

  void _orbit(Offset d) => setState(() {
        _yaw += d.dx * 0.01;
        _pitch = (_pitch + d.dy * 0.01).clamp(-1.5, 1.5);
      });

  // Scale gesture: one finger orbits; two fingers pinch-zoom AND pan (a two-finger
  // drag translates, the pinch scale zooms — both at once feel natural).
  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_panPointer != null) return; // a right-drag pan owns this gesture
    if (d.pointerCount >= 2) {
      setState(() {
        _zoom = (_scaleStartZoom * d.scale).clamp(0.1, 40.0);
        _pan += d.focalPointDelta;
      });
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
        pan: _pan,
      );

  // Scroll up (negative delta) zooms in. Clamped so you can't lose the model.
  /// Scroll-wheel zoom about the cursor: what is under [focal] stays under it.
  /// The view draws at viewCentre + _pan + projected * scale, with scale
  /// proportional to _zoom, so the pan scales about the cursor with it.
  void _zoomBy(double dy, Offset focal, Size view) =>
      _zoomTimes(dy > 0 ? 1 / 1.12 : 1.12, focal, view);

  /// Also what a trackpad pinch arrives as on the web (a scale signal).
  void _zoomTimes(double factor, Offset focal, Size view) => setState(() {
        final before = _zoom;
        _zoom = (_zoom * factor).clamp(0.2, 12.0);
        final fromCentre = focal - view.center(Offset.zero);
        _pan = fromCentre - (fromCentre - _pan) * (_zoom / before);
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
    final solid = part.displaySolid();
    if (solid == null) return null;
    int? best;
    var bestD = 14.0;
    for (var j = 0; j < part.connectors.length; j++) {
      final con = part.connectors[j];
      if (solid.faces.isEmpty) continue;
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
      // Capture the actual solid + authored part NOW (the scene is valid here);
      // setActive below rebuilds it, which would invalidate a stored index.
      _selSolid = h == null ? null : scene.items[h.item].solid;
      _selAuthored = h == null ? null : scene.items[h.item].authored;
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
    final solid = _selSolid, f = _selFace, authored = _selAuthored;
    if (solid == null || f == null || authored == null) return;
    if (f < 0 || f >= solid.faces.length) return;
    final plane = SketchPlane.fromFace(solid, f);
    // Project the picked face's outline into the new plane's 2D coords so the
    // canvas can show it as a guide and anchor the sketch onto the face.
    final reference = [for (final vi in solid.faces[f]) plane.to2d(solid.vertices[vi])];
    // Remember the body this feature sits on, so the 3D view keeps showing it.
    final parent = authored < widget.controller.parts.length
        ? widget.controller.parts[authored]
        : null;
    widget.controller.addPlaneSketch(plane,
        name: 'Face sketch', reference: reference, parent: parent);
    setState(() {
      _selItem = null;
      _selFace = null;
      _selSolid = null;
      _selAuthored = null;
    });
  }

  // Adds a mate point (connector) on the selected face of the active part: its
  // origin is the face centroid and its normal the face normal. Fasten two mate
  // points on different parts in the Assembly view to bring the faces flush.
  void _addMatePoint(_Scene scene) {
    final solid = _selSolid, f = _selFace;
    if (solid == null || f == null || f < 0 || f >= solid.faces.length) return;
    // The face was picked on the scene ITEM's solid (a decomposition region for
    // a multi-region part), but a connector is interpreted against the part's
    // OWN solid. Map the picked face to the nearest face on that solid so the
    // mate point lands on the right face regardless of decomposition. (Uses the
    // solid captured at tap time, so it's valid after the scene rebuilt.)
    final partSolid = widget.controller.active.displaySolid();
    if (partSolid == null) return;
    final pickedCentroid = solid.faceCentroid(f);
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
        // One body per tab: the 3D view shows the active part's feature family
        // (the active part plus anything sketched on its faces), so a face
        // feature renders in context on its parent instead of alone. The full
        // assembly lives in the Assembly view.
        final scene = _buildScene(widget.controller.parts,
            only: widget.controller.visiblePartIndices().toSet());
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
                  if (e is PointerScrollEvent) {
                    _zoomBy(e.scrollDelta.dy, e.localPosition, size);
                  } else if (e is PointerScaleEvent) {
                    _zoomTimes(e.scale, e.localPosition, size);
                  }
                },
                onPointerDown: (e) {
                  if ((e.buttons & kSecondaryButton) != 0 ||
                      (e.buttons & kMiddleMouseButton) != 0) {
                    _panPointer = e.pointer;
                    _panLast = e.localPosition;
                  }
                },
                onPointerMove: (e) {
                  if (_panPointer == e.pointer) {
                    setState(() {
                      _pan += e.localPosition - _panLast;
                      _panLast = e.localPosition;
                    });
                  }
                },
                onPointerUp: (e) {
                  if (_panPointer == e.pointer) _panPointer = null;
                },
                onPointerCancel: (e) {
                  if (_panPointer == e.pointer) _panPointer = null;
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
                          widget.controller.activeIndex,
                          _shaded),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              // Wireframe / shaded toggle.
              Positioned(
                left: 8,
                top: 8,
                child: Material(
                  color: const Color(0xE6161C22),
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: _shaded ? 'Show wireframe' : 'Show shaded',
                    icon: Icon(
                        _shaded ? Icons.grid_on : Icons.view_in_ar,
                        size: 20),
                    color: Colors.white70,
                    onPressed: () => setState(() => _shaded = !_shaded),
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
    // A face feature exposes its extrude length in _faceFeatureRow ("Length"),
    // so the generic part-depth slider below would be a duplicate — suppress it
    // for a face sketch.
    final isFeature = c.active.referenceLoop != null;
    // In a narrow pane (portrait) the depth slider gets its own full-width
    // line — squeezed onto one row with the labels and buttons it was a few px
    // wide and useless (#12). Landscape keeps the single row.
    final Widget body = LayoutBuilder(builder: (context, cons) {
      final narrow = cons.maxWidth < 560;
      const depthLabel =
          Text('Depth', style: TextStyle(color: Colors.white54, fontSize: 12));
      final List<Widget> leading;
      final List<Widget> trailing;
      final Widget? slider;
      if (sel != null && sel < scene.items.length) {
        // With an item selected the slider edits the extrude depth of THAT
        // item's part — always, so selecting a face never makes depth
        // uneditable. (It used to set a per-region override on the ACTIVE part
        // keyed by the selected item's region, which with a feature active
        // wrote into the wrong part and did nothing visible. #9)
        final authored = scene.items[sel].authored;
        leading = [
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
        ];
        slider = Slider(
          value: c.parts[authored].depth.clamp(5, 400),
          min: 5,
          max: 400,
          onChanged: (v) => c.setPartDepth(authored, v),
        );
        trailing = [
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
        ];
      } else {
        leading = [
          Flexible(
            child: Text(
              '${scene.items.length} part${scene.items.length == 1 ? '' : 's'}'
              ' · ${scene.mates.length} mate${scene.mates.length == 1 ? '' : 's'}'
              '${scene.isEmpty ? '' : ' · tap a part'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ];
        // The face-feature row already carries the length slider; only the
        // base-plane part needs the generic depth slider here.
        slider = isFeature
            ? null
            : Slider(
                value: c.active.depth.clamp(5, 400),
                min: 5,
                max: 400,
                onChanged: (v) => c.setDepth(v),
              );
        trailing = const [];
      }
      if (narrow && slider != null) {
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [...leading, const Spacer(), ...trailing]),
          Row(children: [depthLabel, Expanded(child: slider)]),
        ]);
      }
      return Row(children: [
        ...leading,
        if (slider != null) ...[
          const SizedBox(width: 12),
          depthLabel,
          Expanded(child: slider),
        ],
        ...trailing,
      ]);
    });
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
      // Narrow (phone) widths drop the text labels — the segmented button colour
      // and the direction arrow already convey add/cut — so the row never
      // overflows.
      child: LayoutBuilder(builder: (context, cons) {
        final narrow = cons.maxWidth < 520;
        return Row(children: [
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
          // Direction read-out: the arrow always shows; the words only when wide.
          Icon(subtractive ? Icons.south : Icons.north, size: 15, color: accent),
          if (!narrow) ...[
            const SizedBox(width: 2),
            Text(subtractive ? 'cuts in' : 'adds out',
                style: TextStyle(color: accent, fontSize: 12)),
            const SizedBox(width: 12),
            const Text('Length',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
          Expanded(
            child: Slider(
              value: part.depth.clamp(5, 400),
              min: 5,
              max: 400,
              onChanged: c.setDepth,
            ),
          ),
        ]);
      }),
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
_Scene _buildScene(List<Part> parts, {Set<int>? only}) {
  final items = <_Item>[];
  final mates = <_Mate>[];
  final index = <String, int>{}; // "authored:region" -> item index
  for (var ai = 0; ai < parts.length; ai++) {
    if (only != null && !only.contains(ai)) continue;
    final p = parts[ai];
    // A face feature (sketch on a face) MUST extrude on its own plane. buildSolid
    // ignores the plane and would place it on XY — off the face (e.g. a circle
    // drawn on a cylinder side ended up floating beside it). This handles a circle
    // (a decoration, so decompose sees no loop) and sketched-loop bosses/pockets.
    if (p.referenceLoop != null) {
      final s = p.solidOnPlane();
      if (s != null) {
        index['$ai:0'] = items.length;
        items.add(_Item(ai, 0, s, p.name, s.centroid));
      }
      continue;
    }
    // A part with drilled holes can't be region-decomposed into simple polygon
    // solids (region loops don't carry holes), so render its holed solid
    // directly — the wireframe then shows the holes, matching STL export.
    if (p.hasHoles) {
      final s = p.buildSolid();
      if (s != null) {
        index['$ai:0'] = items.length;
        items.add(_Item(ai, 0, s, p.name, s.centroid));
      }
      continue;
    }
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
      this.selFace, this.hovItem, this.hovFace, this.palette, this.activeIndex,
      this.shaded);

  final bool shaded; // shaded (filled) vs wireframe rendering
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

    // Shaded mode: fill every face flat-shaded, all items sorted back-to-front
    // (painter's algorithm) so nearer faces cover farther ones.
    if (shaded) _paintShaded(canvas);

    // Parts (wireframe), shifted by explode. In shaded mode the edges are drawn
    // faint over the fill for definition (a "shaded with edges" look).
    for (var i = 0; i < scene.items.length; i++) {
      final solid = scene.items[i].solid;
      final shift = scene.explode(i, explode);
      final isSel = i == selItem;
      final baseColor = _itemColor(i);
      final paint = Paint()
        ..color = shaded
            ? (isSel ? Colors.white : Colors.black.withValues(alpha: 0.35))
            : (isSel ? Colors.white : baseColor)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSel ? 2.6 : (shaded ? 1.0 : 1.6)
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
    final aSolid = activePart.displaySolid();
    if (aSolid != null) {
      final pinFill = Paint()..color = const Color(0xFFFFC857);
      final pinLine = Paint()
        ..color = const Color(0xFFFFC857)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final con in activePart.connectors) {
        if (aSolid.faces.isEmpty) continue;
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

  /// A body's base colour: a face feature reads green (union) / red (cut); base
  /// bodies use the neutral palette.
  Color _itemColor(int i) {
    final part = parts[scene.items[i].authored];
    final feature = part.referenceLoop != null;
    return feature
        ? (part.isSubtractive
            ? const Color(0xFFE57373)
            : const Color(0xFF81C784))
        : palette[i % palette.length];
  }

  /// Flat-shaded fill of every face across all items, sorted back-to-front
  /// (painter's algorithm). Shade = ambient + diffuse by |normal·view| — the
  /// abs makes it independent of winding (our caps can wind either way). A
  /// near-black backdrop lerps toward each body's colour.
  void _paintShaded(Canvas canvas) {
    final faces = <({int item, int face, double depth})>[];
    for (var i = 0; i < scene.items.length; i++) {
      final solid = scene.items[i].solid;
      final shift = scene.explode(i, explode);
      for (var f = 0; f < solid.faces.length; f++) {
        faces.add((
          item: i,
          face: f,
          depth: cam.depthOf(solid.faceCentroid(f) + shift),
        ));
      }
    }
    faces.sort((a, b) => a.depth.compareTo(b.depth)); // far first
    const bg = Color(0xFF0E1216);
    for (final e in faces) {
      final solid = scene.items[e.item].solid;
      final shift = scene.explode(e.item, explode);
      final rn = cam.rotate(solid.faceNormal(e.face));
      final len = rn.length;
      final facing = len < 1e-9 ? 0.0 : (rn.z / len).abs();
      final shade = 0.28 + 0.72 * facing;
      final fill = Color.lerp(bg, _itemColor(e.item), shade)!;
      canvas.drawPath(
          _facePath(solid, solid.faces[e.face], shift), Paint()..color = fill);
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

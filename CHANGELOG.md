# Changelog

All notable changes to CADSketch. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project is pre-1.0-release
(the App Store 1.0 is in preparation).

## [Unreleased]

### Sketching (2D)
- Fixed (#1): the main body no longer disappears leaving only its face-feature
  extrusions. Undo/redo was per part, so one Undo with the body selected
  reverted its whole sketch while the features kept theirs. Undo is now
  document-wide: it reverts the most recent edit wherever it happened and
  switches to that part.
- New project (#7): app bar + ⌘K. Resets every part, mate point, shared
  parameter, and history to one empty part, with a confirm when there's work.
  "Clear" still only wipes the active sketch.
- Fixed (#6): deleting a body now deletes its face features too (recursively)
  and drops their mates — an orphaned feature was an extrusion floating with no
  body.
- Fixed (#12): in portrait / narrow panes the 3D pane's Depth slider gets its
  own full-width line instead of being squeezed to a few px beside the labels
  and buttons. Landscape keeps the single row.
- Fixed (#9): with a face selected in 3D, the Depth slider now always edits
  the extrude depth of the selected item's part. It used to set a per-region
  override on the *active* part keyed by the selected item's region — with a
  feature active it wrote into the wrong part and depth looked uneditable.
- Fixed (#5): phantom mate points and inward-pointing normals. A pin on a face
  feature was anchored/drawn against the feature's XY-plane extrusion instead
  of the geometry on screen; pins now use the displayed solid. And "outward"
  is now decided by a true inside/outside probe instead of "away from the
  centroid", which pointed a boss side or hole wall inward. Sketch-on-face uses
  the same rule.
- Fixed: dragging a vertex now moves ONLY that vertex ("moving points collapsed
  the shape instead of just moving the point"). Stroke recognition auto-adds
  H/V/equal-length constraints to a clean shape; dragging a corner against one
  of them (e.g. pulling the end of a horizontal edge upward) made that
  constraint unsatisfiable and the solver distorted or collapsed the rest of
  the shape trying to cope. Grabbing a vertex now releases the inferable
  constraints on its edges so it moves freely; drag-inference re-adds an
  alignment on release if you land on one. Tangency and dimensions are kept.
  Also: H and V can no longer be stacked on the same edge (only a zero-length
  edge satisfies both — the collapse).
- Fixed: dimension labels and constraint glyphs stay a fixed on-screen distance
  (16px) from their line at any zoom. The offset was 16 MODEL units, so zoomed
  in 50× a label sat 800px from the line it dimensioned.
- Regression registry: `test/ui_rules_test.dart` states each user-facing rule
  (one test per bug that broke it) so the suite reads as a spec and a failure
  names the behaviour that regressed.
- Fixed: a small circle now recognizes as a circle (this is why "sketch a circle
  on the thin rectangular side face of a cylinder" failed while the round cap
  worked). On a cap you draw a big circle; on a thin side face you draw a small
  one, and the corner-vs-curve step used an absolute RDP epsilon floor (~1.5
  model units) that, on a small circle, was a large fraction of the radius —
  RDP collapsed the circle to a coarse polygon whose turns read as corners, so
  it became a polyline and no circle persisted. The corner epsilon is now
  size-relative, so a clean circle reads as a circle at any size.
- Fixed: drawing while zoomed in now works (this is why sketching on a small face
  "sometimes did nothing"). Stroke recognition and vertex-merge thresholds are now
  screen-relative — before, a normal on-screen stroke drawn zoomed in was only a
  few model units long, so it was dropped as noise and its vertices were merged
  together, and nothing persisted.
- Zoom in much further on the 2D canvas (raised the max-zoom cap).
- Fixed: an inner loop that isn't a clean closed loop (e.g. a hole drawn freehand
  that didn't close) no longer makes the whole outer profile disappear — loop
  extraction now keeps the closed loops it can find and ignores open chains.
- Undo / redo (buttons in the app bar). Per-part sketch history covering strokes,
  vertex drags, deletes, dimensions, constraints, circles, and mate points. A
  drag is a single undo step (not one per pixel).
- Constraint inference while dragging: as you drag a vertex, edges that come
  close to horizontal, vertical, or parallel/perpendicular to a nearby edge snap
  into alignment (previewed in green), and the constraint is applied on release —
  so it persists and drives the geometry. Tap a constraint glyph (H, V, ∥, ⊥, =)
  to select it and Delete to remove it; drag again to re-infer.
- Line tool: tap to place a connected chain of segments. Tapping on (or near) an
  existing vertex snaps and welds to it, so you can **continue a line from an
  existing point**; tap the first vertex to close the loop, and Done/Esc ends the
  chain. Freehand drawing still works with the tool off. See `GUIDE.md`.
- Fixed: selecting a vertex and deleting it now works reliably on touch and web.
  The on-canvas buttons (delete, reset view, line tool) previously lived inside
  the drawing gesture layer, so tapping one could fire a canvas gesture mid-tap
  and swallow the press; pointer handling is now isolated to the canvas itself.
- Right-button (or middle-button) drag pans the sketch canvas on desktop/web —
  a grab-and-drag pan for the mouse, matching two-finger pan on touch. The
  browser's right-click context menu is suppressed over the canvas so the drag
  is clean.
- Pinch-to-zoom and two-finger pan in the sketch canvas, with a reset-view
  button (scroll-wheel zoom on desktop). Stroke widths, vertex dots, constraint
  glyphs, and dimension labels stay a constant on-screen size at any zoom.
- Dimension numbers highlight on hover and are hit-tested in screen space, so
  clicking the number to edit it lands reliably regardless of zoom.
- The canvas is clipped to its pane, so a panned sketch no longer spills into the
  3D view.

### 3D view
- Pinch-to-zoom (one finger orbits, two dolly); scroll-wheel zoom on desktop.
- Shows one part per tab (the active part); the full assembly lives in the
  Assembly view. In portrait the panes stack 3D-over-2D.
- Face picking is consistent at every orientation (removed a normal-based cull
  that misbehaved on extruded caps); click again to cycle to an occluded face.
- Only renders once a part forms a solid — an open, non-closed sketch draws
  nothing in 3D.
- Renders holed solids: a drilled circle or a sketched inner loop shows as a real
  through-hole in the wireframe, matching STL export.
- Fixed: a hole whose outer boundary is a circle now renders and exports
  correctly (e.g. a sketched triangle inside a circle, or a smaller circle inside
  a bigger one). The largest closed region — sketched loop OR circle — is taken as
  the outer boundary; anything inside it becomes a hole.
- Fixed: a boss whose sketch overhangs the face it was drawn on no longer floats
  where it hangs past the edge ("if the sketch goes off the edge of the face we
  don't close the gap"). A circle on a thin cylinder facet (~10 units wide)
  almost always overhangs, and the prism was extruded flat from the face plane
  with nothing beneath the overhang. The base now lofts down to the next face
  ("up to next"): each base vertex is dropped along -normal onto the parent
  body, so an overhang meets the adjacent face with no gap. Vertices inside the
  face stay put; pockets are unchanged.
- Fixed: a circle (or any feature) sketched on a face now renders ON that face
  instead of floating off to the side. The 3D part view was falling back to
  buildSolid for a circle-on-face (a decoration, not a sketched loop), which
  extrudes on the XY plane and ignores the face; it now extrudes on the face
  plane (Part.solidOnPlane, shared with the Assembly view).
- Fixed: a face feature (a sketch on a face) now renders in context on its parent
  body. Previously the containing part disappeared and only the new extrusion
  showed, because the view shows one body at a time; a face feature and its parent
  are now treated as one family and shown together.
- Fixed: a face feature's controls show a single extrude-length slider (there was
  a duplicate — the feature row's "Length" and a generic "Depth" both drove the
  same value).
- Fixed: a face sketch's plane normal is oriented outward on every face, so a
  boss/pocket extrudes the intended way even on a cylinder's back faces (the raw
  winding-dependent normal could point inward and reverse the extrude).
- Two-finger pan in both 3D views (the part view and the Assembly view): one
  finger orbits, two fingers pinch-zoom and pan together. On desktop/web,
  right-button (or middle-button) drag pans while left-drag orbits — the same
  pan gesture as the 2D canvas, so panning is consistent across every view.
- Fixed: "Sketch on face" (and "Add mate point") no longer intermittently act on
  the wrong face after tapping — the picked face is captured at tap time, so it
  survives the view rebuild that selecting a part triggers.
- Wireframe / shaded toggle: switch either 3D view (the part view and the
  Assembly view) between the wireframe and a simple flat-shaded solid. Shading is
  per-face (ambient + diffuse by facing angle), with faces drawn back-to-front so
  nearer ones cover farther ones. Toggle is top-left of the 3D pane (part view)
  and in the Assembly app bar.
- Clipped to its pane so zoomed geometry can't paint over the parts tabs.
- Removed the explode/"scale" slider.

### Parts & navigation
- The parts tree starts collapsed to a thin rail on narrow (phone) screens so the
  3D/2D panes aren't crowded; it stays expanded on tablets. The face-feature
  control row also compacts on narrow screens (drops text labels) so it never
  overflows.
- Parts tree: a collapsible left panel replaces the flat tab strip. Base bodies
  are roots and face features nest under the body they were sketched on; each
  part expands to its Sketch (line/circle counts) and mate points. Tap a row to
  make its part active; a per-part menu duplicates or deletes it; the panel
  collapses to a thin rail. (The tabs stopped making sense once parts nested.)

### Modeling
- Face features declare an explicit operation — Union (adds material, green) or
  Difference (cuts, red) — with auto direction and a Flip; default is union/out.
- Part origin datum: the sketch bounding-box centre, shown as an XYZ axis triad
  in 3D and a crosshair in 2D.

### Assembly & mates
- Add mate points on faces; fasten two on different parts (coincident origins,
  opposed normals) in the Assembly view; unmate by tapping a mated point; clear
  all mates. Mate normals always point outward. A mate point maps to the correct
  face on decomposed parts.
- Duplicate a part (deep copy) to reuse it in an assembly; remove individual mate
  points (tap the pin) or clear a part's mate points.
- Fixed: the Assembly view merges a face feature into its parent body. Each base
  body is one assembly component, rendered with its bosses/pockets extruded
  in-context on their faces — a feature is no longer shown as a separate,
  mispositioned body parked off to the side. Mates connect base bodies.
- Fixed: duplicating a part no longer carries the original's mate points — a
  duplicate starts clean (they read as phantom pins the user didn't place).
- Fixed: deleting a base body no longer makes its face features vanish from the
  assembly. The features are promoted to base bodies (re-parented) instead of
  being orphaned to a part that's no longer there.
- Fixed: mate points stay on their face after a hole is drilled. A connector now
  anchors to its face centroid and re-resolves the face each frame, instead of
  storing a face index that shifts when the solid gains hole faces (which made
  existing pins jump to the wrong place).
- Assembly view: scroll-wheel zoom.

### Import
- Import a DXF drawing as a new sketch part (⌘K → "Import DXF…"). LINE,
  LWPOLYLINE, POLYLINE and ARC become the parametric profile; CIRCLE becomes a
  circle (a hole or cylinder via the usual profile rule). Geometry is imported
  faithfully (no constraint inference or solve, so a precise drawing isn't
  distorted); DXF's Y-up is flipped so it reads upright. On the web this opens a
  file picker; on desktop it reads a file path. (Splines, ellipses and blocks are
  ignored for now.)

### Export
- STL export of the active part (binary STL), generated directly in-app (no
  external tooling). Web downloads the file; desktop writes it. Interior holes —
  a circle decoration OR a sketched inner loop inside the profile — are cut
  through the exported solid via a polygon-with-holes triangulation, so a plate
  exports as a watertight, printable mesh with its holes. (iPad share is
  pending; boolean face features still need native OCCT.)
- featuretree bridge: export a sketch to an editable FreeCAD/build123d feature
  tree.

### Platform & release
- App Store 1.0 groundwork: real app icon, listing metadata, live privacy/support
  pages, privacy manifest, screenshots, and an automated release pipeline
  (an `ios-v*` tag builds, uploads to TestFlight, and stages the listing, stopping
  before Submit).
- Repo/site moved to `punkfab/cadsketch`; the web app auto-deploys to
  `cadsketch.ai/app`.

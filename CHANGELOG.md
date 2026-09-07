# Changelog

All notable changes to CADSketch. Format follows
[Keep a Changelog](https://keepachangelog.com/); this project is pre-1.0-release
(the App Store 1.0 is in preparation).

## [Unreleased]

### Sketching (2D)
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
- Clipped to its pane so zoomed geometry can't paint over the parts tabs.
- Removed the explode/"scale" slider.

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
- Assembly view: scroll-wheel zoom.

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

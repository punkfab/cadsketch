# CADSketch — sketching guide

A short guide to drawing, editing, and turning sketches into 3D parts. The app is
a 2D-first CAD sketcher: you draw a profile, dimension and constrain it, and it
extrudes into a solid you can hole, mate, and export.

## Drawing lines

There are two ways to lay down geometry:

- **Freehand** (default): drag a stroke. A roughly-straight stroke snaps to a
  clean line and feeds the parametric model; a closed shape becomes a profile.
  Corners that land on each other are merged into one shared vertex.
- **Line tool** (the ⟋ button, top-left of the canvas): tap to place a connected
  chain of segments, one vertex per tap.

### Continuing a line from an existing point

Turn on the **Line tool**, then **tap an existing vertex** to start there — the
tap snaps to it (a green ring shows the target) and the new segment welds onto
that point instead of creating a duplicate. Keep tapping to extend the chain.

- **Close a loop:** tap the chain's first vertex again.
- **Finish an open chain:** press **Done** (appears while a chain is in progress)
  or **Esc**.

While a chain is in progress a rubber-band line previews the next segment, and any
tap that lands near an existing vertex snaps to it — so you can also *join* two
chains by ending one on the other's endpoint.

## Editing geometry

- **Move a vertex:** press and drag it. The sketch re-solves live, holding the
  dragged point while constraints relax around the rest.
- **Weld / close by dragging:** drag a vertex onto another (a green ring marks the
  weld target) to merge them — this is how you close a path by hand.
- **Select:** tap a vertex, a line, or a circle. A small bar appears with a
  **Delete** action (and **Dimension…/Radius…** for a line or circle). On a
  keyboard, **Delete/Backspace** also removes the selection.
- **Dimension a line:** tap its dimension number to set a length, bind it to a
  shared parameter, or make it a driven (reference) dimension.

## From sketch to solid

A **closed** profile extrudes into a solid by the part's depth. An open path
draws nothing in 3D until it can actually form a solid.

### Holes

Draw a closed inner loop, or a circle, **inside** the outer profile and it's
drilled straight through the extrude — the 3D view shows the through-hole and STL
export cuts it, so the wireframe and the exported mesh always agree.

The rule for what's boundary vs. hole is simple: **the largest closed region wins
the outer boundary; anything inside it becomes a hole.** A sketched loop and a
circle are treated the same way, so a triangle inside a circle, or a small circle
inside a big one, both give you a ring with the small shape as the hole.

## Sketch on a face

Pick a face in the 3D view and choose **Sketch on face** to start a new sketch on
that face's plane. What you draw becomes a **feature** on that body:

- **Union** (green) adds material — a boss extruded outward.
- **Difference** (red) removes material — a pocket extruded into the body.
- Direction is chosen automatically; **Flip** reverses it for the rare
  inward-union / outward-difference case.

The face feature is shown **in context on its parent body** — the containing part
stays visible with the new feature on it, not on its own. (The full multi-part
assembly lives in the **Assembly view**.)

## Organizing parts — the tree

The collapsible left panel lists every part as a tree: base bodies at the root,
with **face features nested under the body they were sketched on**. Each part
expands to its **Sketch** (line/circle counts) and any **mate points**.

- **Switch parts:** tap a row to make it active (it's highlighted, and it's what
  the 2D canvas edits and the 3D view shows in context).
- **Add a body:** **+ Add part** at the bottom.
- **Duplicate / delete:** the ⋮ menu on a part row.
- **Collapse:** the ‹ chevron shrinks the panel to a thin rail; tap the tree icon
  to bring it back.

## Mates & assembly

- **Add a mate point:** select a face and press **Add mate point**. Its pin marks
  the face centroid with a stub along the outward normal. Mate points stay put
  across edits — including after you drill a hole.
- **Fasten:** in the **Assembly view**, tap two mate points on different parts to
  bring their faces flush (coincident points, opposed normals). Tap a mated point
  to unmate; use **Clear all mates** to reset.
- **Reuse a part:** **Duplicate** a part (deep copy) to place it more than once.

## Export

**Export STL (active part)** writes a binary STL, generated in-app with no
external tooling — holes and all. On the web the file downloads; on desktop it's
written to disk. (iPad file delivery is pending; boolean face features between
bodies need the native OCCT kernel.)

## View controls

- **2D canvas:** pinch to zoom / two-finger pan (scroll-wheel on desktop); the
  reset-view button returns to 100%. Stroke widths, dimension labels, and
  constraint glyphs stay a constant on-screen size at any zoom.
- **3D view:** one finger orbits, two dolly (scroll-wheel on desktop). Shows one
  body per tab; portrait stacks 3D over 2D.

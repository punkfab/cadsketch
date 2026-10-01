---
name: cadsketch
description: Design flat, extruded mechanical parts (plates, brackets, gaskets, spacers, panels) with the user in the CADSketch editor. Draw parts with draw_parts, write and edit .cadsketch files, open .dxf files, and review what the user has sketched. Use for any request to design, draw, sketch, model, dimension or review a part that is a 2D outline with holes, extruded to a thickness.
---

# CADSketch

CADSketch is a sketch-first CAD editor. A part is a closed 2D profile with
circular through-holes, extruded to a thickness. The user sees and edits parts in
an interactive editor (drag points, set dimensions, extrude, export STL); you
read and write the same parts as plain data.

## The part format

Millimetres. X right, Y up. Every tool and file uses this shape:

```json
{ "name": "bracket", "depth": 5,
  "profile": [[0,0],[60,0],[60,30],[45,30],[45,15],[0,15]],
  "holes":   [[10,7.5,2.25],[35,7.5,2.25],[52.5,22,2.25]] }
```

- `profile`: outline vertices in order. Closed automatically, so do not repeat
  the first vertex. At least 3.
- A vertex may be `[x, y, bulge]`: the edge from it to the next vertex is an arc
  with bulge = tan(theta/4). Positive bulges counter-clockwise; 1 is a semicircle.
- `circle`: `[cx, cy, r]`, for a round part (disc, washer, spacer) instead of
  `profile`.
- `holes`: `[cx, cy, r]` each. They must lie inside the outline.
- `depth`: extrusion thickness.

Use real hardware sizes. Clearance hole radii: M3 1.7, M4 2.25, M5 2.75, M6 3.3.
Keep at least one hole diameter of material between a hole and any edge.

## Two ways to work

**In the conversation: `draw_parts`.** Call it with the full list of parts. The
editor opens inline with them, and the result reports each part's size, volume
and geometry warnings (a hole outside the outline, a wall under 1 mm, a profile
that crosses itself). Fix every warning before telling the user the part is
done. To change the design, call `draw_parts` again with the complete updated
list; the canvas is replaced.

**In the workspace: `.cadsketch` files.** Prefer this when the user is working
in a project folder, wants the design kept, or wants to iterate. Write a file:

```json
{
  "cadsketch": 1,
  "units": "mm",
  "parts": [
    { "name": "bracket", "depth": 5,
      "profile": [[0,0],[60,0],[60,30],[45,30],[45,15],[0,15]],
      "holes": [[10,7.5,2.25],[35,7.5,2.25],[52.5,22,2.25]] }
  ]
}
```

The user opens it in the CADSketch file viewer. While it is open:

- When you edit the file, the editor reloads it.
- When the user edits in the editor, the file is saved in this same format.
  Re-read the file before changing it, so you build on their edits rather than
  overwriting them.
- A sketch that is not a closed shape yet is not written to the file.

`.dxf` files also open in the viewer, read-only.

## Reading what the user drew

The editor reports the canvas to you as context: each part's name, size, depth,
holes, and whether its profile is closed. An open profile cannot be extruded;
say which part is open and offer to redraw it closed. When the user asks for a
review, check for: an open or self-crossing profile, holes too close to an edge
or to each other, walls thinner than the process allows (about 1 mm for FDM
printing, material thickness for laser cutting), and sharp internal corners that
a cutter cannot reach.

## Limits to be honest about

- Parts are flat profiles extruded straight up. No fillets on the extruded
  edges, no lofts, no revolves.
- You can draw base bodies. Features the user sketches on a face of a body are
  visible to you but you cannot create them.
- Arcs you send are stored as short straight edges, so a rounded profile comes
  back with many vertices.
- STL export is done by the user in the editor (the command menu, Export STL).

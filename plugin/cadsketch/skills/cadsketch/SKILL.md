---
name: cadsketch
description: Design flat, extruded mechanical parts (plates, brackets, gaskets, spacers, panels) with the user in the CADSketch editor. Draw parts, edit the open sketch in place (move vertices, add and move holes, set driving dimensions, add constraints, undo), look at it with a screenshot, export STL, write and edit .cadsketch files, open .dxf and featuretree .ir.json files, and review what the user has sketched. Use for any request to design, draw, sketch, model, dimension, change or review a part that is a 2D outline with holes, extruded to a thickness.
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

## Editing the sketch that is open

When the CADSketch editor is open (the sidebar tab, the panel beside this
conversation, or a file), it publishes tools that act on that live sketch. Each
call is one step on the editor's undo stack, exactly like a hand edit, and the
user sees it happen.

1. Call `get_sketch` first. It returns every part with its `profile` vertices,
   `holes`, `edges` (each with its `length`, and `driving` when dimensioned) and
   `constraintList`. Those lists give you the indices the other tools take.
   Call it again whenever the user may have edited by hand.
2. Make the smallest change that does the job:

| To | Use |
| --- | --- |
| add, move, resize or remove a hole | `add_hole`, `move_hole`, `remove_hole` |
| move a corner | `move_vertex` |
| make an edge an exact length | `set_dimension` (`length: null` removes it) |
| lock in design intent | `add_constraint` (horizontal, vertical, parallel, perpendicular, equal), `remove_constraint` |
| change thickness | `set_depth` |
| add, select or delete a part | `add_part`, `select_part`, `delete_part` |
| start over | `replace_parts` |
| step back | `undo`, `redo` |
| see it | `screenshot` |
| make a printable file | `export_stl` |

3. Read the result. Every edit returns the updated part; `add_hole` warns when a
   hole landed outside the profile.

Things worth knowing:

- Edge `i` runs from vertex `i` to vertex `i + 1`. Indices can change after an
  edit that adds or removes geometry, so re-read rather than reuse stale ones.
- Parts you draw start with horizontal and vertical constraints on their
  axis-aligned edges. That is why `set_dimension` on one side of a rectangle
  widens the whole plate instead of skewing it. `move_vertex` respects
  constraints too, so neighbouring corners follow; pass `release_constraints`
  to move one corner alone.
- Prefer `set_dimension` over `move_vertex` when the user states a size ("make
  it 95 wide"). A driving dimension keeps holding through later edits.
- `replace_parts` discards the user's constraints and dimensions. Use it for a
  new design, not for a tweak.
- Use `screenshot` to check your work when geometry matters, or when the user
  says "this corner" or "that hole" and you need to see what they mean.
- `export_stl` gives the user a binary STL. When the plugin runs on their own
  machine and a `.cadsketch` file is open, it is saved next to that file and
  you get the path. Otherwise the app offers it as a download.

These tools exist only while the editor is open. If they are not available,
open it (`open_sketcher`, or have the user open the `.cadsketch` file) or work
through the file as described below.

## Other ways to work

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

`.ir.json` files (a featuretree feature tree: `{"name", "features": [...]}`,
punkfab/featuretree) open read-only too. The first pad becomes the body, through
cuts become holes, and pads and blind pockets on the top or bottom face become
features on the body. Fillets, revolves, draft and sideways cuts are not shown;
the canvas context lists them by name, so tell the user what is missing rather
than describing the canvas as the whole part.

## Reading what the user drew

The editor reports the canvas to you as context: each part's name, size, depth,
holes, and whether its profile is closed. An open profile cannot be extruded;
say which part is open and offer to redraw it closed. When the user asks for a
review, check for: an open or self-crossing profile, holes too close to an edge
or to each other, walls thinner than the process allows (about 1 mm for FDM
printing, material thickness for laser cutting), and sharp internal corners that
a cutter cannot reach.

`check_parts` validates parts without opening the editor: use it on a
`.cadsketch` file you just wrote, before telling the user it is ready.

## Limits to be honest about

- Parts are flat profiles extruded straight up. No fillets on the extruded
  edges, no lofts, no revolves.
- You can draw base bodies. Features the user sketches on a face of a body are
  visible to you but you cannot create them.
- Arcs you send are stored as short straight edges, so a rounded profile comes
  back with many vertices.
- Constraints and driving dimensions live in the editor session. A `.cadsketch`
  file stores geometry only, so they are re-inferred (horizontal and vertical)
  when a file is reloaded.

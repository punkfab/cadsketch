// Geometry checks on a part the model wants to draw. The numbers go back to the
// model in the tool result so it can catch its own mistakes (a hole outside the
// outline, a profile that folds over itself, a 400 mm part when 40 was meant)
// before the user has to point them out.
//
// The part format is documented in lib/mcp/part_spec.dart, which is the Dart
// twin of this file: same vertex notation, same bulge convention.

export type Vertex = number[]; // [x, y] or [x, y, bulge]
export type Circle = number[]; // [cx, cy, r]

export interface PartInput {
  name: string;
  depth: number;
  profile?: Vertex[];
  circle?: Circle;
  holes?: Circle[];
}

export interface PartReport {
  name: string;
  width_mm: number;
  height_mm: number;
  depth_mm: number;
  area_mm2: number;
  volume_mm3: number;
  holes: number;
  warnings: string[];
}

const round = (v: number, d = 2) => {
  const f = 10 ** d;
  return Math.round(v * f) / f;
};

/** Profile with every bulged edge expanded into chords (10 degree steps). */
export function tessellate(profile: Vertex[]): [number, number][] {
  const pts: [number, number][] = [];
  for (let i = 0; i < profile.length; i++) {
    const [x0, y0, bulge = 0] = profile[i];
    const [x1, y1] = profile[(i + 1) % profile.length];
    pts.push([x0, y0]);
    if (Math.abs(bulge) < 1e-9) continue;
    const dx = x1 - x0;
    const dy = y1 - y0;
    const c = Math.hypot(dx, dy);
    if (c < 1e-9) continue;
    const theta = 4 * Math.atan(bulge); // signed sweep, CCW positive
    const k = c / 2 / Math.tan(theta / 2);
    const cx = (x0 + x1) / 2 + (-dy / c) * k;
    const cy = (y0 + y1) / 2 + (dx / c) * k;
    const r = Math.hypot(x0 - cx, y0 - cy);
    const a0 = Math.atan2(y0 - cy, x0 - cx);
    const n = Math.max(2, Math.ceil(Math.abs(theta) / (Math.PI / 18)));
    for (let s = 1; s < n; s++) {
      const a = a0 + (theta * s) / n;
      pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
  }
  return pts;
}

function signedArea(pts: [number, number][]): number {
  let a = 0;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    a += pts[j][0] * pts[i][1] - pts[i][0] * pts[j][1];
  }
  return a / 2;
}

function inside(pts: [number, number][], x: number, y: number): boolean {
  let hit = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
  }
  return hit;
}

function distToSegment(px: number, py: number, a: [number, number], b: [number, number]): number {
  const vx = b[0] - a[0];
  const vy = b[1] - a[1];
  const len2 = vx * vx + vy * vy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((px - a[0]) * vx + (py - a[1]) * vy) / len2));
  return Math.hypot(px - (a[0] + t * vx), py - (a[1] + t * vy));
}

function distToOutline(pts: [number, number][], x: number, y: number): number {
  let best = Infinity;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    best = Math.min(best, distToSegment(x, y, pts[j], pts[i]));
  }
  return best;
}

function segmentsCross(a: [number, number], b: [number, number], c: [number, number], d: [number, number]): boolean {
  const o = (p: [number, number], q: [number, number], r: [number, number]) =>
    Math.sign((q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]));
  return o(a, b, c) * o(a, b, d) < 0 && o(c, d, a) * o(c, d, b) < 0;
}

function selfIntersects(pts: [number, number][]): boolean {
  const n = pts.length;
  if (n > 600) return false; // not worth the quadratic check on a huge outline
  for (let i = 0; i < n; i++) {
    for (let j = i + 2; j < n; j++) {
      if (i === 0 && j === n - 1) continue; // neighbours across the seam
      if (segmentsCross(pts[i], pts[(i + 1) % n], pts[j], pts[(j + 1) % n])) return true;
    }
  }
  return false;
}

/** Returns an error message when the part cannot be drawn at all, else null. */
export function structuralError(p: PartInput): string | null {
  const hasProfile = !!p.profile && p.profile.length > 0;
  if (!hasProfile && !p.circle) return `"${p.name}" needs either a profile or a circle.`;
  if (hasProfile && p.circle) return `"${p.name}" has both a profile and a circle; give one.`;
  if (hasProfile && p.profile!.length < 3) return `"${p.name}" profile needs at least 3 vertices.`;
  return null;
}

export function report(p: PartInput): PartReport {
  const warnings: string[] = [];
  const holes = p.holes ?? [];
  let width = 0;
  let height = 0;
  let area = 0;

  let outline: [number, number][] | null = null;
  if (p.profile && p.profile.length >= 3) {
    outline = tessellate(p.profile);
    const xs = outline.map((v) => v[0]);
    const ys = outline.map((v) => v[1]);
    width = Math.max(...xs) - Math.min(...xs);
    height = Math.max(...ys) - Math.min(...ys);
    area = Math.abs(signedArea(outline));
    if (area < 1e-6) warnings.push("The profile has no area (all vertices are in a line).");
    if (selfIntersects(outline)) warnings.push("The profile crosses itself; it will not extrude cleanly.");
  } else if (p.circle) {
    const r = p.circle[2];
    width = height = 2 * r;
    area = Math.PI * r * r;
  }

  let holeArea = 0;
  holes.forEach(([cx, cy, r], i) => {
    holeArea += Math.PI * r * r;
    const label = `Hole ${i + 1} at (${round(cx)}, ${round(cy)})`;
    if (outline) {
      if (!inside(outline, cx, cy)) {
        warnings.push(`${label} is outside the profile and will be ignored.`);
        return;
      }
      const wall = distToOutline(outline, cx, cy) - r;
      if (wall < 0) warnings.push(`${label} breaks through the edge of the part.`);
      else if (wall < 1) warnings.push(`${label} leaves only ${round(wall)} mm of wall to the edge.`);
    } else if (p.circle) {
      const wall = p.circle[2] - (Math.hypot(cx - p.circle[0], cy - p.circle[1]) + r);
      if (wall < 0) warnings.push(`${label} breaks through the edge of the part.`);
      else if (wall < 1) warnings.push(`${label} leaves only ${round(wall)} mm of wall to the edge.`);
    }
    for (let j = 0; j < i; j++) {
      const [ox, oy, or] = holes[j];
      if (Math.hypot(cx - ox, cy - oy) < r + or) warnings.push(`Holes ${j + 1} and ${i + 1} overlap.`);
    }
  });

  const net = Math.max(0, area - holeArea);
  return {
    name: p.name,
    width_mm: round(width),
    height_mm: round(height),
    depth_mm: round(p.depth),
    area_mm2: round(net),
    volume_mm3: round(net * p.depth),
    holes: holes.length,
    warnings,
  };
}

export function describe(r: PartReport): string {
  const head =
    `${r.name}: ${r.width_mm} x ${r.height_mm} mm, extruded ${r.depth_mm} mm, ` +
    `${r.holes} hole${r.holes === 1 ? "" : "s"}, volume ${r.volume_mm3} mm3.`;
  return r.warnings.length ? `${head}\n  Check: ${r.warnings.join(" ")}` : head;
}

#include "sketch_kernel.h"

#include <cmath>
#include <vector>

#define SK_ABI_VERSION 4

int sk_version(void) { return SK_ABI_VERSION; }

int sk_fit_circle(const double* xy, int n, double* out4) {
  if (!xy || !out4 || n < 3) return 0;

  // Kåsa fit: minimize sum( (x^2+y^2) + D*x + E*y + F )^2, linear in D,E,F.
  // Work in centroid-relative coords for conditioning.
  double mx = 0.0, my = 0.0;
  for (int i = 0; i < n; ++i) {
    mx += xy[2 * i];
    my += xy[2 * i + 1];
  }
  mx /= n;
  my /= n;

  double Suu = 0, Suv = 0, Svv = 0, Suuu = 0, Svvv = 0, Suvv = 0, Svuu = 0;
  for (int i = 0; i < n; ++i) {
    const double u = xy[2 * i] - mx;
    const double v = xy[2 * i + 1] - my;
    Suu += u * u;
    Svv += v * v;
    Suv += u * v;
    Suuu += u * u * u;
    Svvv += v * v * v;
    Suvv += u * v * v;
    Svuu += v * u * u;
  }

  // Solve [Suu Suv; Suv Svv] [uc; vc] = 0.5 * [Suuu+Suvv; Svvv+Svuu].
  const double det = Suu * Svv - Suv * Suv;
  if (std::fabs(det) < 1e-12) return 0;  // collinear / degenerate

  const double b1 = 0.5 * (Suuu + Suvv);
  const double b2 = 0.5 * (Svvv + Svuu);
  const double uc = (b1 * Svv - b2 * Suv) / det;
  const double vc = (b2 * Suu - b1 * Suv) / det;

  const double cx = uc + mx;
  const double cy = vc + my;
  const double r = std::sqrt(uc * uc + vc * vc + (Suu + Svv) / n);

  // RMS radial residual.
  double s = 0.0;
  for (int i = 0; i < n; ++i) {
    const double dx = xy[2 * i] - cx;
    const double dy = xy[2 * i + 1] - cy;
    const double e = std::sqrt(dx * dx + dy * dy) - r;
    s += e * e;
  }
  out4[0] = cx;
  out4[1] = cy;
  out4[2] = r;
  out4[3] = std::sqrt(s / n);
  return 1;
}

// ===========================================================================
// Constraint solver
// ===========================================================================

namespace {

struct Constraint {
  int type;
  int a, b, c, d;
  int rad;  // radius id, or -1
  double value;
};

struct Sketch {
  std::vector<double> px;     // point x
  std::vector<double> py;     // point y
  std::vector<char> fixed;    // per-point: coords are constants
  std::vector<double> radii;  // radius unknowns
  std::vector<Constraint> cons;
};

inline bool valid_pt(const Sketch* s, int id) {
  return id >= 0 && id < static_cast<int>(s->px.size());
}

inline bool valid_rad(const Sketch* s, int id) {
  return id >= 0 && id < static_cast<int>(s->radii.size());
}

// Number of scalar residuals a constraint contributes.
int residual_count(int type) {
  return type == SK_COINCIDENT ? 2 : 1;
}

// Appends this constraint's residuals (evaluated at coords x,y, radii) to out.
void eval_constraint(const Constraint& k, const std::vector<double>& x,
                     const std::vector<double>& y,
                     const std::vector<double>& radii,
                     std::vector<double>& out) {
  const double eps = 1e-9;
  switch (k.type) {
    case SK_COINCIDENT:
      out.push_back(x[k.a] - x[k.b]);
      out.push_back(y[k.a] - y[k.b]);
      break;
    case SK_HORIZONTAL:
      out.push_back(y[k.a] - y[k.b]);
      break;
    case SK_VERTICAL:
      out.push_back(x[k.a] - x[k.b]);
      break;
    case SK_DISTANCE: {
      const double dx = x[k.b] - x[k.a];
      const double dy = y[k.b] - y[k.a];
      out.push_back(std::sqrt(dx * dx + dy * dy) - k.value);
      break;
    }
    case SK_EQUAL_LENGTH: {
      const double l1 = std::hypot(x[k.b] - x[k.a], y[k.b] - y[k.a]);
      const double l2 = std::hypot(x[k.d] - x[k.c], y[k.d] - y[k.c]);
      out.push_back(l1 - l2);
      break;
    }
    case SK_PARALLEL: {
      const double abx = x[k.b] - x[k.a], aby = y[k.b] - y[k.a];
      const double cdx = x[k.d] - x[k.c], cdy = y[k.d] - y[k.c];
      const double la = std::hypot(abx, aby), lc = std::hypot(cdx, cdy);
      // sin of angle between, normalized → dimensionless, well-conditioned.
      out.push_back((la < eps || lc < eps) ? 0.0
                                           : (abx * cdy - aby * cdx) / (la * lc));
      break;
    }
    case SK_PERPENDICULAR: {
      const double abx = x[k.b] - x[k.a], aby = y[k.b] - y[k.a];
      const double cdx = x[k.d] - x[k.c], cdy = y[k.d] - y[k.c];
      const double la = std::hypot(abx, aby), lc = std::hypot(cdx, cdy);
      out.push_back((la < eps || lc < eps) ? 0.0
                                           : (abx * cdx + aby * cdy) / (la * lc));
      break;
    }
    case SK_RADIUS:
      out.push_back(radii[k.rad] - k.value);
      break;
    case SK_POINT_ON_CIRCLE: {
      // a = point, b = center, rad = radius
      const double d = std::hypot(x[k.a] - x[k.b], y[k.a] - y[k.b]);
      out.push_back(d - radii[k.rad]);
      break;
    }
    case SK_TANGENT_LINE: {
      // a,b = line points, c = center, rad : perpendicular dist == radius
      const double abx = x[k.b] - x[k.a], aby = y[k.b] - y[k.a];
      const double len = std::hypot(abx, aby);
      if (len < eps) {
        out.push_back(0.0);
      } else {
        const double dist =
            std::fabs((x[k.c] - x[k.a]) * aby - (y[k.c] - y[k.a]) * abx) / len;
        out.push_back(dist - radii[k.rad]);
      }
      break;
    }
    default:
      break;
  }
}

std::vector<double> residuals(const Sketch* s, const std::vector<double>& x,
                              const std::vector<double>& y,
                              const std::vector<double>& radii) {
  std::vector<double> r;
  for (const auto& k : s->cons) eval_constraint(k, x, y, radii, r);
  return r;
}

double norm2(const std::vector<double>& v) {
  double s = 0;
  for (double e : v) s += e * e;
  return s;
}

// Solves SPD system A x = b in place (A is n×n row-major) via Cholesky.
// Returns false if A is not positive-definite.
bool cholesky_solve(std::vector<double>& A, std::vector<double>& b, int n) {
  std::vector<double> L(n * n, 0.0);
  for (int i = 0; i < n; ++i) {
    for (int j = 0; j <= i; ++j) {
      double sum = A[i * n + j];
      for (int k = 0; k < j; ++k) sum -= L[i * n + k] * L[j * n + k];
      if (i == j) {
        if (sum <= 0.0) return false;
        L[i * n + j] = std::sqrt(sum);
      } else {
        L[i * n + j] = sum / L[j * n + j];
      }
    }
  }
  // Forward solve L y = b.
  std::vector<double> yv(n);
  for (int i = 0; i < n; ++i) {
    double sum = b[i];
    for (int k = 0; k < i; ++k) sum -= L[i * n + k] * yv[k];
    yv[i] = sum / L[i * n + i];
  }
  // Back solve Lᵀ x = y.
  for (int i = n - 1; i >= 0; --i) {
    double sum = yv[i];
    for (int k = i + 1; k < n; ++k) sum -= L[k * n + i] * b[k];
    b[i] = sum / L[i * n + i];
  }
  return true;
}

}  // namespace

SkSketch sk_create(void) { return new Sketch(); }

void sk_destroy(SkSketch s) { delete static_cast<Sketch*>(s); }

int sk_add_point(SkSketch s, double x, double y) {
  auto* sk = static_cast<Sketch*>(s);
  sk->px.push_back(x);
  sk->py.push_back(y);
  sk->fixed.push_back(0);
  return static_cast<int>(sk->px.size()) - 1;
}

void sk_fix_point(SkSketch s, int id, int fixed) {
  auto* sk = static_cast<Sketch*>(s);
  if (valid_pt(sk, id)) sk->fixed[id] = fixed ? 1 : 0;
}

int sk_add_radius(SkSketch s, double value) {
  auto* sk = static_cast<Sketch*>(s);
  sk->radii.push_back(value);
  return static_cast<int>(sk->radii.size()) - 1;
}

double sk_radius(SkSketch s, int rad) {
  auto* sk = static_cast<Sketch*>(s);
  return valid_rad(sk, rad) ? sk->radii[rad] : 0.0;
}

int sk_radius_count(SkSketch s) {
  return static_cast<int>(static_cast<Sketch*>(s)->radii.size());
}

int sk_constrain_radius(SkSketch s, int rad, double value) {
  auto* sk = static_cast<Sketch*>(s);
  if (!valid_rad(sk, rad)) return -1;
  sk->cons.push_back({SK_RADIUS, -1, -1, -1, -1, rad, value});
  return static_cast<int>(sk->cons.size()) - 1;
}

int sk_constrain_point_on_circle(SkSketch s, int point, int center, int rad) {
  auto* sk = static_cast<Sketch*>(s);
  if (!valid_pt(sk, point) || !valid_pt(sk, center) || !valid_rad(sk, rad))
    return -1;
  sk->cons.push_back({SK_POINT_ON_CIRCLE, point, center, -1, -1, rad, 0});
  return static_cast<int>(sk->cons.size()) - 1;
}

int sk_constrain_tangent_line(SkSketch s, int p1, int p2, int center, int rad) {
  auto* sk = static_cast<Sketch*>(s);
  if (!valid_pt(sk, p1) || !valid_pt(sk, p2) || !valid_pt(sk, center) ||
      !valid_rad(sk, rad))
    return -1;
  sk->cons.push_back({SK_TANGENT_LINE, p1, p2, center, -1, rad, 0});
  return static_cast<int>(sk->cons.size()) - 1;
}

int sk_add_constraint(SkSketch s, int type, int a, int b, int c, int d,
                      double value) {
  auto* sk = static_cast<Sketch*>(s);
  if (!valid_pt(sk, a) || !valid_pt(sk, b)) return -1;
  if ((type == SK_PARALLEL || type == SK_PERPENDICULAR ||
       type == SK_EQUAL_LENGTH) &&
      (!valid_pt(sk, c) || !valid_pt(sk, d)))
    return -1;
  sk->cons.push_back({type, a, b, c, d, -1, value});
  return static_cast<int>(sk->cons.size()) - 1;
}

void sk_point(SkSketch s, int id, double* x, double* y) {
  auto* sk = static_cast<Sketch*>(s);
  if (valid_pt(sk, id)) {
    if (x) *x = sk->px[id];
    if (y) *y = sk->py[id];
  }
}

int sk_point_count(SkSketch s) {
  return static_cast<int>(static_cast<Sketch*>(s)->px.size());
}

int sk_solve(SkSketch s) {
  auto* sk = static_cast<Sketch*>(s);
  const int np = static_cast<int>(sk->px.size());
  const int nr = static_cast<int>(sk->radii.size());
  if (sk->cons.empty()) return 0;

  // Free-column mapping: free point coordinates first, then all radii (radii
  // are always solve unknowns so tangency / radius dims can drive geometry).
  std::vector<int> col(2 * np, -1);
  int nfree = 0;
  for (int i = 0; i < np; ++i) {
    if (!sk->fixed[i]) {
      col[2 * i] = nfree++;
      col[2 * i + 1] = nfree++;
    }
  }
  std::vector<int> radCol(nr, -1);
  for (int k = 0; k < nr; ++k) radCol[k] = nfree++;
  if (nfree == 0) return 0;

  std::vector<double> x = sk->px, y = sk->py, rad = sk->radii;
  const std::vector<double> x0 = sk->px, y0 = sk->py, rad0 = sk->radii;
  const double kTol = 1e-6;
  // Weak pull toward the drawn values. Resolves under-constrained degrees of
  // freedom toward minimal movement and prevents runaway. Small enough not to
  // fight real constraints/dims.
  const double kReg = 0.005;
  const int kMaxIter = 200;
  double lambda = 1e-3;

  // Full residual = constraint residuals + regularization on free unknowns.
  auto fullResiduals = [&](const std::vector<double>& X,
                           const std::vector<double>& Y,
                           const std::vector<double>& R) {
    std::vector<double> r = residuals(sk, X, Y, R);
    for (int i = 0; i < np; ++i) {
      if (sk->fixed[i]) continue;
      r.push_back(kReg * (X[i] - x0[i]));
      r.push_back(kReg * (Y[i] - y0[i]));
    }
    for (int k = 0; k < nr; ++k) r.push_back(kReg * (R[k] - rad0[k]));
    return r;
  };
  // RMS of the constraint residuals (excludes regularization). The early-out
  // uses a tight tolerance for cleanly-solvable (often linear) systems; when
  // the LM settles, kAccept decides "satisfied" vs "conflicting" — the weak
  // regularization biases hard constraints by ~kReg^2, far below kAccept.
  auto crms = [&](const std::vector<double>& X, const std::vector<double>& Y,
                  const std::vector<double>& R) {
    const std::vector<double> cr = residuals(sk, X, Y, R);
    const int mc = static_cast<int>(cr.size());
    return std::sqrt(norm2(cr) / (mc ? mc : 1));
  };
  const double kAccept = 0.5;  // px RMS: settled-and-satisfied vs conflicting

  std::vector<double> r = fullResiduals(x, y, rad);
  const int m = static_cast<int>(r.size());

  for (int iter = 0; iter < kMaxIter; ++iter) {
    if (crms(x, y, rad) < kTol) {
      sk->px = x;
      sk->py = y;
      sk->radii = rad;
      return 0;
    }

    // Numerical Jacobian J (m × nfree), forward differences.
    std::vector<double> J(static_cast<size_t>(m) * nfree, 0.0);
    for (int i = 0; i < np; ++i) {
      if (sk->fixed[i]) continue;
      for (int axis = 0; axis < 2; ++axis) {
        std::vector<double>& coord = (axis == 0) ? x : y;
        const int cidx = col[2 * i + axis];
        const double orig = coord[i];
        const double h = 1e-6 * (1.0 + std::fabs(orig));
        coord[i] = orig + h;
        std::vector<double> rp = fullResiduals(x, y, rad);
        coord[i] = orig - h;
        std::vector<double> rm = fullResiduals(x, y, rad);
        coord[i] = orig;
        for (int j = 0; j < m; ++j)
          J[static_cast<size_t>(j) * nfree + cidx] = (rp[j] - rm[j]) / (2 * h);
      }
    }
    for (int k = 0; k < nr; ++k) {
      const int cidx = radCol[k];
      const double orig = rad[k];
      const double h = 1e-6 * (1.0 + std::fabs(orig));
      rad[k] = orig + h;
      std::vector<double> rp = fullResiduals(x, y, rad);
      rad[k] = orig - h;
      std::vector<double> rm = fullResiduals(x, y, rad);
      rad[k] = orig;
      for (int j = 0; j < m; ++j)
        J[static_cast<size_t>(j) * nfree + cidx] = (rp[j] - rm[j]) / (2 * h);
    }

    // Normal equations: A = JᵀJ + λ·diag(JᵀJ), g = Jᵀr.
    std::vector<double> A(static_cast<size_t>(nfree) * nfree, 0.0);
    std::vector<double> g(nfree, 0.0);
    for (int a = 0; a < nfree; ++a) {
      for (int b = a; b < nfree; ++b) {
        double sum = 0;
        for (int j = 0; j < m; ++j)
          sum += J[static_cast<size_t>(j) * nfree + a] *
                 J[static_cast<size_t>(j) * nfree + b];
        A[a * nfree + b] = sum;
        A[b * nfree + a] = sum;
      }
      double gs = 0;
      for (int j = 0; j < m; ++j) gs += J[static_cast<size_t>(j) * nfree + a] * r[j];
      g[a] = gs;
    }

    // LM damping + solve A·Δ = -g, retrying with more damping if needed.
    bool stepped = false;
    for (int tries = 0; tries < 12 && !stepped; ++tries) {
      std::vector<double> Ad = A;
      for (int a = 0; a < nfree; ++a) Ad[a * nfree + a] += lambda * A[a * nfree + a] + 1e-12;
      std::vector<double> delta(nfree);
      for (int a = 0; a < nfree; ++a) delta[a] = -g[a];
      if (!cholesky_solve(Ad, delta, nfree)) {
        lambda *= 4;
        continue;
      }
      std::vector<double> xn = x, yn = y, radn = rad;
      for (int i = 0; i < np; ++i) {
        if (sk->fixed[i]) continue;
        xn[i] += delta[col[2 * i]];
        yn[i] += delta[col[2 * i + 1]];
      }
      for (int k = 0; k < nr; ++k) radn[k] += delta[radCol[k]];
      std::vector<double> rn = fullResiduals(xn, yn, radn);
      if (norm2(rn) < norm2(r)) {
        x.swap(xn);
        y.swap(yn);
        rad.swap(radn);
        r.swap(rn);
        lambda = std::fmax(lambda * 0.5, 1e-9);
        stepped = true;
      } else {
        lambda *= 4;
      }
    }
    if (!stepped) break;  // damping couldn't find a downhill step
  }

  sk->px = x;
  sk->py = y;
  sk->radii = rad;
  // Settled: success if constraints are essentially satisfied, else report the
  // system as unsatisfiable (e.g. conflicting/over-constrained).
  return crms(x, y, rad) < kAccept ? 0 : 1;
}

int sk_fit_line(const double* xy, int n, double* out4) {
  if (!xy || !out4 || n < 2) return 0;

  // Centroid.
  double mx = 0.0, my = 0.0;
  for (int i = 0; i < n; ++i) {
    mx += xy[2 * i];
    my += xy[2 * i + 1];
  }
  mx /= n;
  my /= n;

  // Covariance terms (orthogonal / total least squares).
  double sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (int i = 0; i < n; ++i) {
    const double dx = xy[2 * i] - mx;
    const double dy = xy[2 * i + 1] - my;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }

  // Principal direction = eigenvector of the covariance matrix for the larger
  // eigenvalue. theta is the line's angle through the centroid.
  const double theta = 0.5 * std::atan2(2.0 * sxy, sxx - syy);
  const double dirx = std::cos(theta);
  const double diry = std::sin(theta);

  if (sxx + syy <= 0.0) return 0;  // all points coincident

  // Project the first and last input point onto the fitted line to get clean
  // endpoints (preserves the stroke's intended extent and orientation).
  const double t0 = (xy[0] - mx) * dirx + (xy[1] - my) * diry;
  const double t1 = (xy[2 * (n - 1)] - mx) * dirx + (xy[2 * (n - 1) + 1] - my) * diry;

  out4[0] = mx + t0 * dirx;
  out4[1] = my + t0 * diry;
  out4[2] = mx + t1 * dirx;
  out4[3] = my + t1 * diry;
  return 1;
}

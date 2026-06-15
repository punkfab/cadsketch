#include "sketch_kernel.h"

#include <cmath>

#define SK_ABI_VERSION 2

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

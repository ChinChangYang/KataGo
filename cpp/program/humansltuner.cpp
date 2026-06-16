#include "../program/humansltuner.h"

#include <algorithm>
#include <cmath>
#include <limits>

static double clipd(double v, double lo, double hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

static double lerp(double a, double b, double t) { return a + (b - a) * t; }

LogisticRS::LogisticRS(double l2_)
  : l2(l2_), xs(), ws(), ns(), b0(0.0), b1(0.0), fitted(false) {
  cov[0][0] = 0.0; cov[0][1] = 0.0; cov[1][0] = 0.0; cov[1][1] = 0.0;
}

void LogisticRS::addSample(double x, double wins, double games) {
  xs.push_back(x);
  ws.push_back(wins);
  ns.push_back(games);
}

LogisticRS& LogisticRS::fit(int iters) {
  for(int iter = 0; iter < iters; iter++) {
    double g0 = l2 * b0;
    double g1 = l2 * b1;
    double S0 = l2, S1 = 0.0, S2 = l2;
    for(size_t i = 0; i < xs.size(); i++) {
      double z = clipd(b0 + b1 * xs[i], -30.0, 30.0);
      double p = 1.0 / (1.0 + std::exp(-z));
      double resid = ns[i] * p - ws[i];
      g0 += resid;
      g1 += xs[i] * resid;
      double w = clipd(ns[i] * p * (1.0 - p), 1e-9, std::numeric_limits<double>::infinity());
      S0 += w;
      S1 += w * xs[i];
      S2 += w * xs[i] * xs[i];
    }
    double H00 = S0, H01 = S1, H10 = S1, H11 = S2;
    double det = H00 * H11 - H01 * H10;
    if(std::fabs(det) < 1e-12)
      continue;
    double step0 = clipd((H11 * g0 - H01 * g1) / det, -10.0, 10.0);
    double step1 = clipd((-H10 * g0 + H00 * g1) / det, -10.0, 10.0);
    b0 -= step0;
    b1 -= step1;
  }

  // Recompute covariance = (X^T W X + l2 I)^-1 at the final coefficients.
  double S0 = l2, S1 = 0.0, S2 = l2;
  for(size_t i = 0; i < xs.size(); i++) {
    double z = clipd(b0 + b1 * xs[i], -30.0, 30.0);
    double p = 1.0 / (1.0 + std::exp(-z));
    double w = clipd(ns[i] * p * (1.0 - p), 1e-9, std::numeric_limits<double>::infinity());
    S0 += w;
    S1 += w * xs[i];
    S2 += w * xs[i] * xs[i];
  }
  double det = S0 * S2 - S1 * S1;
  if(std::fabs(det) < 1e-12) {
    cov[0][0] = cov[0][1] = cov[1][0] = cov[1][1] = 0.0;
  } else {
    cov[0][0] = S2 / det;
    cov[0][1] = -S1 / det;
    cov[1][0] = -S1 / det;
    cov[1][1] = S0 / det;
  }
  fitted = true;
  return *this;
}

double LogisticRS::predict(double x) const {
  double z = clipd(b0 + b1 * x, -30.0, 30.0);
  return 1.0 / (1.0 + std::exp(-z));
}

double LogisticRS::root(double targetWinrate) const {
  if(std::fabs(b1) < 1e-9)
    return std::nan("");
  double logitT = std::log(targetWinrate / (1.0 - targetWinrate));
  return (logitT - b0) / b1;
}

double LogisticRS::rootSeElo(double targetWinrate) const {
  if(!fitted || std::fabs(b1) < 1e-9)
    return std::numeric_limits<double>::infinity();
  double logitT = std::log(targetWinrate / (1.0 - targetWinrate));
  double dx_db0 = -1.0 / b1;
  double dx_db1 = -(logitT - b0) / (b1 * b1);
  double varX = dx_db0 * dx_db0 * cov[0][0]
              + 2.0 * dx_db0 * dx_db1 * cov[0][1]
              + dx_db1 * dx_db1 * cov[1][1];
  double eloPerX = std::fabs(b1) * LogisticRS::ELO_PER_LOGIT;
  return eloPerX * std::sqrt(std::max(varX, 0.0));
}

int LogisticRS::distinctXCount(double eps) const {
  std::vector<double> sorted = xs;
  std::sort(sorted.begin(), sorted.end());
  int count = 0;
  for(size_t i = 0; i < sorted.size(); i++) {
    if(i == 0 || sorted[i] - sorted[i - 1] > eps)
      count++;
  }
  return count;
}

StrengthDialParams strengthDialToParams(double x, const StrengthDialConfig& c) {
  x = clipd(x, 0.0, 3.0);
  StrengthDialParams out;
  if(x < 1.0) {
    // Segment A (weak): temperature lever at 1 visit (piklLambda is inert at 1 visit).
    out.maxVisits = 1;
    out.piklLambda = StrengthDialConfig::PIKL_INERT;
    out.deltaTau = c.dtauMax * (1.0 - x);
  } else if(x < 2.0) {
    // Segment B (mid): piklLambda lever with search on.
    out.maxVisits = c.searchVisits;
    double lg = lerp(std::log10(c.piklMax), std::log10(c.piklFloor), x - 1.0);
    out.piklLambda = std::pow(10.0, lg);
    out.deltaTau = 0.0;
  } else {
    // Segment C (strong): visits lever, piklLambda fully trusted.
    double lg = lerp(std::log2((double)c.searchVisits), std::log2((double)c.maxVisitsCap), x - 2.0);
    out.maxVisits = (int)std::lround(std::pow(2.0, lg));
    out.piklLambda = c.piklFloor;
    out.deltaTau = 0.0;
  }
  return out;
}

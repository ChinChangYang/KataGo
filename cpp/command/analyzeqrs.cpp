// command/analyzeqrs.cpp
//
// Benchmark harness comparing QRS-Tune against grid + Bradley-Terry MLE
// and random + Bradley-Terry MLE on synthetic 1-D PUCT-like win-rate
// landscapes.
//
// Per (landscape, trial-budget, method) the harness reports:
//   - mean and median regret |x_recommended - x_true| in [-1,+1] coords
//   - mean true win-rate at the recommended x (vs reference)
//   - QRS only: fraction of seeds where the 95% CI covers x_true,
//               fraction of seeds where the fitted quadratic was
//               non-concave (uniform-fallback fired), fraction of
//               seeds where the recommended x was clamped to {-1,+1}.
//
// Usage: katago analyze-qrs

#include "../core/global.h"
#include "../core/elo.h"
#include "../qrstune/QRSOptimizer.h"
#include "../main.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <map>
#include <random>
#include <string>
#include <utility>
#include <vector>

using namespace std;

namespace {

struct Landscape {
  string name;
  double intercept;
  double curvature;
  double trueOptimum;  // normalized [-1,+1]
};

double trueProbExperimentWins(const Landscape& L, double x) {
  double dx = x - L.trueOptimum;
  return QRSTune::sigmoid(L.intercept - L.curvature * dx * dx);
}

double mean(const vector<double>& v) {
  if(v.empty()) return 0.0;
  double s = 0.0;
  for(double x : v) s += x;
  return s / (double)v.size();
}

double median(vector<double> v) {
  if(v.empty()) return 0.0;
  sort(v.begin(), v.end());
  size_t n = v.size();
  if(n % 2 == 1) return v[n / 2];
  return 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

// --------------------------------------------------------------------
// QRS-Tune run: returns regret and fills diagnostic outputs.
// --------------------------------------------------------------------
double runQRSSeed(const Landscape& L, int trials, uint64_t seed,
                  bool& outConvex, bool& outClamped, bool& outCICovers,
                  double& outRecommendedProb) {
  mt19937_64 outcomeRng(seed * 9176ULL + 31ULL);
  uniform_real_distribution<double> uni01(0.0, 1.0);

  QRSTune::QRSTuner tuner(/*D=*/1, /*seed=*/seed, /*total_trials=*/trials,
                          /*l2_reg=*/0.1, /*refit_every=*/10, /*prune_every=*/5,
                          /*sigma_init=*/0.50, /*sigma_fin=*/0.15);

  for(int t = 0; t < trials; t++) {
    vector<double> x = tuner.nextSample();
    double p = trueProbExperimentWins(L, x[0]);
    double y = (uni01(outcomeRng) < p) ? 1.0 : 0.0;
    tuner.addResult(x, y);
  }

  vector<double> best = tuner.bestCoords();
  outRecommendedProb = trueProbExperimentWins(L, best[0]);
  outConvex = tuner.model().hasConvexDim();

  double se[1] = {-1.0};
  bool clamped[1] = {false};
  bool seOk = tuner.model().computeOptimumSE(tuner.buffer().xs(), se, clamped);
  outClamped = seOk ? clamped[0] : false;
  if(seOk) {
    double lo = best[0] - 1.96 * se[0];
    double hi = best[0] + 1.96 * se[0];
    outCICovers = (L.trueOptimum >= lo && L.trueOptimum <= hi);
  } else {
    outCICovers = false;
  }
  return fabs(best[0] - L.trueOptimum);
}

// --------------------------------------------------------------------
// Grid + Bradley-Terry baseline: cycle through gridN equally-spaced
// candidate x values; aggregate W/L vs the reference into pairStats;
// pick the grid point with highest BT-fitted Elo.
//
// All grid bot names sort lexicographically before "ref" (g0, g1, ...
// < ref), so map keys use {gName, "ref"} with index [0]=gName-wins,
// [1]=ref-wins.
// --------------------------------------------------------------------
double runGridSeed(const Landscape& L, int trials, int gridN, uint64_t seed,
                   double& outRecommendedProb) {
  mt19937_64 rng(seed * 8123ULL + 7ULL);
  uniform_real_distribution<double> uni01(0.0, 1.0);

  vector<double> grid(gridN);
  for(int i = 0; i < gridN; i++)
    grid[i] = -1.0 + 2.0 * (double)i / (double)(gridN - 1);

  vector<string> botNames;
  botNames.reserve(gridN + 1);
  botNames.push_back("ref");
  for(int i = 0; i < gridN; i++)
    botNames.push_back("g" + to_string(i));

  map<pair<string,string>, array<int64_t,3>> pairStats;
  for(int i = 0; i < gridN; i++)
    pairStats[{botNames[1 + i], "ref"}] = {0, 0, 0};

  for(int t = 0; t < trials; t++) {
    int idx = t % gridN;
    double p = trueProbExperimentWins(L, grid[idx]);
    bool experimentWon = (uni01(rng) < p);
    auto& s = pairStats[{botNames[1 + idx], "ref"}];
    if(experimentWon) s[0] += 1; else s[1] += 1;
  }

  vector<double> elo, eloStderr;
  ComputeElos::computeBradleyTerryElo(botNames, pairStats, elo, eloStderr);

  int bestIdx = 0;
  double bestElo = elo[1];
  for(int i = 1; i < gridN; i++) {
    if(elo[1 + i] > bestElo) {
      bestElo = elo[1 + i];
      bestIdx = i;
    }
  }
  outRecommendedProb = trueProbExperimentWins(L, grid[bestIdx]);
  return fabs(grid[bestIdx] - L.trueOptimum);
}

// --------------------------------------------------------------------
// Random + Bradley-Terry baseline: each trial picks a uniform grid
// index. Same BT aggregation and selection as the grid baseline.
// Demonstrates how much value comes from BT alone vs grid scheduling.
// --------------------------------------------------------------------
double runRandomSeed(const Landscape& L, int trials, int gridN, uint64_t seed,
                     double& outRecommendedProb) {
  mt19937_64 rng(seed * 4111ULL + 19ULL);
  uniform_real_distribution<double> uni01(0.0, 1.0);
  uniform_int_distribution<int> idxDist(0, gridN - 1);

  vector<double> grid(gridN);
  for(int i = 0; i < gridN; i++)
    grid[i] = -1.0 + 2.0 * (double)i / (double)(gridN - 1);

  vector<string> botNames;
  botNames.reserve(gridN + 1);
  botNames.push_back("ref");
  for(int i = 0; i < gridN; i++)
    botNames.push_back("g" + to_string(i));

  map<pair<string,string>, array<int64_t,3>> pairStats;
  for(int i = 0; i < gridN; i++)
    pairStats[{botNames[1 + i], "ref"}] = {0, 0, 0};

  for(int t = 0; t < trials; t++) {
    int idx = idxDist(rng);
    double p = trueProbExperimentWins(L, grid[idx]);
    bool experimentWon = (uni01(rng) < p);
    auto& s = pairStats[{botNames[1 + idx], "ref"}];
    if(experimentWon) s[0] += 1; else s[1] += 1;
  }

  vector<double> elo, eloStderr;
  ComputeElos::computeBradleyTerryElo(botNames, pairStats, elo, eloStderr);

  int bestIdx = 0;
  double bestElo = elo[1];
  for(int i = 1; i < gridN; i++) {
    if(elo[1 + i] > bestElo) {
      bestElo = elo[1 + i];
      bestIdx = i;
    }
  }
  outRecommendedProb = trueProbExperimentWins(L, grid[bestIdx]);
  return fabs(grid[bestIdx] - L.trueOptimum);
}

struct Aggregate {
  double meanRegret = 0.0;
  double medRegret = 0.0;
  double meanRecPeakP = 0.0;
  double ciCoverage = -1.0;
  double convexRate  = -1.0;
  double clampRate   = -1.0;
};

void printRow(const string& label, const Aggregate& a) {
  cout << "    " << left << setw(11) << label << right
       << "  meanRegret=" << fixed << setprecision(4) << setw(7) << a.meanRegret
       << "  medRegret="  << setw(7) << a.medRegret
       << "  meanRecPeakP=" << setprecision(4) << setw(7) << a.meanRecPeakP;
  if(a.ciCoverage >= 0.0) cout << "  CIcov="    << setprecision(2) << a.ciCoverage;
  if(a.convexRate  >= 0.0) cout << "  convex="   << setprecision(2) << a.convexRate;
  if(a.clampRate   >= 0.0) cout << "  clamped="  << setprecision(2) << a.clampRate;
  cout << endl;
}

}  // namespace

int MainCmds::analyzeqrs(const vector<string>& /*args*/) {
  // 1-D PUCT-like landscapes spanning peak-win-rates from "easy" to
  // "PUCT-realistic". Real PUCT tuning typically lives near peak ~0.51-0.55.
  vector<Landscape> landscapes = {
    {"steep_peak0.82", 1.5,  3.00, 0.25},
    {"medium_peak0.62", 0.5, 1.00, 0.25},
    {"flat_peak0.55",  0.2,  0.40, 0.25},
    {"vflat_peak0.52", 0.08, 0.15, 0.25},
  };
  vector<int> budgets = {200, 1000, 5000};
  const int numSeeds = 30;
  const int gridN = 11;

  cout << "QRS-Tune benchmark: QRS vs Grid+BT vs Random+BT" << endl;
  cout << "  seeds per config : " << numSeeds << endl;
  cout << "  baseline gridN   : " << gridN << endl;
  cout << "  metric           : regret = |x_recommended - x_true|, x in [-1,+1]" << endl;
  cout << endl;

  for(const Landscape& L : landscapes) {
    cout << "Landscape " << L.name
         << "  trueOpt=" << fixed << setprecision(2) << L.trueOptimum
         << "  intercept=" << L.intercept
         << "  curvature=" << L.curvature
         << "  peakProbAtTrueOpt=" << setprecision(3)
         << QRSTune::sigmoid(L.intercept) << endl;

    for(int trials : budgets) {
      cout << "  trials=" << trials << endl;

      vector<double> qRegret, gRegret, rRegret;
      vector<double> qProb, gProb, rProb;
      int convexCount = 0, clampCount = 0, ciCoverCount = 0;

      for(int s = 0; s < numSeeds; s++) {
        uint64_t seed = (uint64_t)(1000 + s * 17);
        bool conv, clmp, covers;
        double recProb;
        qRegret.push_back(runQRSSeed(L, trials, seed,
                                     conv, clmp, covers, recProb));
        qProb.push_back(recProb);
        if(conv)   convexCount++;
        if(clmp)   clampCount++;
        if(covers) ciCoverCount++;

        double gRecProb;
        gRegret.push_back(runGridSeed(L, trials, gridN, seed, gRecProb));
        gProb.push_back(gRecProb);

        double rRecProb;
        rRegret.push_back(runRandomSeed(L, trials, gridN, seed, rRecProb));
        rProb.push_back(rRecProb);
      }

      Aggregate q;
      q.meanRegret = mean(qRegret);
      q.medRegret  = median(qRegret);
      q.meanRecPeakP = mean(qProb);
      q.ciCoverage   = (double)ciCoverCount / (double)numSeeds;
      q.convexRate   = (double)convexCount  / (double)numSeeds;
      q.clampRate    = (double)clampCount   / (double)numSeeds;
      printRow("QRS", q);

      Aggregate g;
      g.meanRegret = mean(gRegret);
      g.medRegret  = median(gRegret);
      g.meanRecPeakP = mean(gProb);
      printRow("Grid+BT", g);

      Aggregate r;
      r.meanRegret = mean(rRegret);
      r.medRegret  = median(rRegret);
      r.meanRecPeakP = mean(rProb);
      printRow("Random+BT", r);
    }
    cout << endl;
  }

  return 0;
}

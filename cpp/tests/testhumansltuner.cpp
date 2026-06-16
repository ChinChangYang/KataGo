#include "../tests/tests.h"

#include "../program/humansltuner.h"

#include <cmath>
#include <functional>
#include <random>
#include <utility>
#include <vector>

using namespace std;

static double sigmoid(double z) { return 1.0 / (1.0 + std::exp(-z)); }

void Tests::runHumanSLTunerTests() {
  cout << "Running human SL tuner tests" << endl;

  // Test 1: LogisticRS recovers known coefficients.
  {
    LogisticRS rs(0.5);
    double xsv[] = {-2.0, -1.0, 0.0, 1.0, 2.0};
    for(double x : xsv) {
      double p = sigmoid(0.5 - 2.0 * x);
      rs.addSample(x, std::round(1000.0 * p), 1000.0);
    }
    rs.fit();
    testAssert(std::fabs(rs.getB0() - 0.5) < 0.1);
    testAssert(std::fabs(rs.getB1() + 2.0) < 0.1);
  }

  // Test 2: root recovers the target dial.
  {
    LogisticRS rs(0.5);
    double xsv[] = {-2.0, -1.0, 0.0, 1.0, 2.0, 3.0};
    for(double x : xsv) {
      double p = sigmoid(-x); // b ~ (0, -1)
      rs.addSample(x, std::round(1000.0 * p), 1000.0);
    }
    rs.fit();
    testAssert(std::fabs(rs.root(0.36) - 0.5754) < 0.05);
    testAssert(rs.rootSeElo(0.36) < 50.0);
  }

  // Test 3: CI shrinks with more data.
  {
    LogisticRS big(0.5), small(0.5);
    double xsv[] = {-2.0, -1.0, 0.0, 1.0, 2.0, 3.0};
    for(double x : xsv) {
      double p = sigmoid(-x);
      big.addSample(x, std::round(2000.0 * p), 2000.0);
      small.addSample(x, std::round(80.0 * p), 80.0);
    }
    big.fit();
    small.fit();
    testAssert(big.rootSeElo(0.36) < small.rootSeElo(0.36));
  }

  // Test 4: dial schedule monotonicity and continuity.
  {
    StrengthDialConfig c; // defaults
    double prevDtauA = 1e18;
    double prevPiklB = 1e18;
    int prevVisC = -1;
    for(int i = 0; i <= 60; i++) {
      double x = i * 0.05;
      StrengthDialParams p = strengthDialToParams(x, c);
      if(x < 1.0) {
        testAssert(p.maxVisits == 1);
        testAssert(p.piklLambda == StrengthDialConfig::PIKL_INERT);
        testAssert(p.deltaTau <= prevDtauA + 1e-12);
        prevDtauA = p.deltaTau;
      } else if(x < 2.0) {
        testAssert(p.maxVisits == c.searchVisits);
        testAssert(p.deltaTau == 0.0);
        testAssert(p.piklLambda <= prevPiklB + 1e-9);
        prevPiklB = p.piklLambda;
      } else {
        testAssert(std::fabs(p.piklLambda - c.piklFloor) < 1e-12);
        testAssert(p.maxVisits >= prevVisC);
        prevVisC = p.maxVisits;
      }
    }
    // Continuity at x == 2: both sides give maxVisits == searchVisits and piklLambda == piklFloor.
    StrengthDialParams justBelow = strengthDialToParams(2.0 - 1e-9, c);
    StrengthDialParams at2 = strengthDialToParams(2.0, c);
    testAssert(at2.maxVisits == c.searchVisits);
    testAssert(justBelow.maxVisits == c.searchVisits);
    testAssert(std::fabs(at2.piklLambda - c.piklFloor) < 1e-9);
    testAssert(std::fabs(justBelow.piklLambda - c.piklFloor) < 1e-6);
  }

  // Test 5: calibrateToTarget is unbiased with an honest CI. Deterministic (fixed seeds).
  {
    auto winrateOfElo = [](double elo) { return 1.0 / (1.0 + std::pow(10.0, -elo / 400.0)); };

    auto runScenario = [&](const std::function<double(double)>& eloFn) {
      const int numSeeds = 100;
      double sumErr = 0.0, sumSqErr = 0.0;
      int cover1 = 0, cover2 = 0;
      for(int s = 0; s < numSeeds; s++) {
        std::mt19937_64 playRng((uint64_t)(1000 + s));
        auto playAt = [&](double x) -> std::pair<double,int> {
          double wr = winrateOfElo(eloFn(x));
          int games = 20;
          std::binomial_distribution<int> binom(games, wr);
          int wins = binom(playRng);
          return std::make_pair((double)wins, games);
        };
        CalibrationResult res = calibrateToTarget(
          playAt, 0.0, 1.0, 0.36, 20, 30, 25.0, (uint64_t)(s + 1), 0.5, nullptr);
        double err = eloFn(res.xStar) + 100.0; // true target ELO is -100
        sumErr += err;
        sumSqErr += err * err;
        if(std::fabs(err) <= res.eloSe) cover1++;
        if(std::fabs(err) <= 2.0 * res.eloSe) cover2++;
      }
      double meanErr = sumErr / numSeeds;
      double rmse = std::sqrt(sumSqErr / numSeeds);
      double cov1 = (double)cover1 / numSeeds;
      double cov2 = (double)cover2 / numSeeds;
      testAssert(std::fabs(meanErr) < 15.0); // unbiased
      testAssert(rmse < 45.0);
      testAssert(cov1 >= 0.55 && cov1 <= 0.90); // honest, not overconfident
      testAssert(cov2 >= 0.88);
    };

    runScenario([](double x) { return -100.0 + 300.0 * (x - 0.5); });
    runScenario([](double x) { double d = x - 0.5; return -100.0 + 250.0 * d + 500.0 * d * d * d; });
  }

  // Test 6: overrideConfigText replaces existing keys, ignores comments, appends new keys.
  {
    std::string input = "a = 1\nb=2\n# c = 3\n";
    std::vector<std::pair<std::string,std::string>> ov = {{"b", "9"}, {"d", "4"}};
    std::string out = overrideConfigText(input, ov);
    testAssert(out == "a = 1\nb = 9\n# c = 3\nd = 4\n");
  }

  // Test 7: an unreachable target pins x* to the boundary, never reports "converged",
  // and keeps the reported CI NaN-safe. Exercises the degenerate extrapolation regime
  // (candidate far stronger than the target across the whole dial range).
  {
    auto winrateOfElo = [](double elo) { return 1.0 / (1.0 + std::pow(10.0, -elo / 400.0)); };
    std::mt19937_64 playRng(12345);
    auto playAt = [&](double x) -> std::pair<double,int> {
      double elo = 150.0 + 100.0 * x; // always >= +150 ELO; the 0.36 (-100 ELO) root lies below xLo
      double wr = winrateOfElo(elo);
      int games = 20;
      std::binomial_distribution<int> binom(games, wr);
      return std::make_pair((double)binom(playRng), games);
    };
    CalibrationResult res = calibrateToTarget(
      playAt, 0.0, 1.0, 0.36, 20, 30, 25.0, (uint64_t)7, 0.5, nullptr);
    testAssert(res.converged == false);
    testAssert(std::fabs(res.xStar - 0.0) < 1e-6); // pinned to xLo
    testAssert(!std::isnan(res.eloSe));            // honest CI: large/inf allowed, NaN never
    testAssert(res.eloSe >= 0.0);
    testAssert(res.totalGames > 0);
  }

  // Test 8: LogisticRS stays NaN-safe under near-degenerate data.
  {
    // (a) Perfectly separable data (all losses below 0, all wins above). The MLE slope
    // diverges; L2 must keep coefficients finite and the reported CI non-NaN.
    LogisticRS sep(0.5);
    sep.addSample(-1.0, 0.0, 50.0);
    sep.addSample(-1.0, 0.0, 50.0);
    sep.addSample( 1.0, 50.0, 50.0);
    sep.addSample( 1.0, 50.0, 50.0);
    sep.fit();
    testAssert(std::isfinite(sep.getB0()));
    testAssert(std::isfinite(sep.getB1()));
    testAssert(!std::isnan(sep.rootSeElo(0.36)));

    // (b) No spread in x: the slope is unidentified. root() must be NaN (not +-inf) and
    // rootSeElo() must be a non-NaN sentinel (+inf), with no crash.
    LogisticRS flat(0.5);
    for(int i = 0; i < 5; i++) flat.addSample(0.5, 25.0, 50.0);
    flat.fit();
    testAssert(std::isfinite(flat.getB0()));
    testAssert(std::isfinite(flat.getB1()));
    double r = flat.root(0.36);
    double se = flat.rootSeElo(0.36);
    testAssert(std::isnan(r) || std::isfinite(r)); // defined-or-NaN, never an inf trap
    testAssert(!std::isnan(se));
  }

  // Test 9: convergence is structurally impossible with fewer than 4 rounds, even on a
  // clean low-noise reachable surface (it requires >= 4 distinct dial samples). This pins
  // down the invariant that motivates the CLI's max-rounds warning.
  {
    auto winrateOfElo = [](double elo) { return 1.0 / (1.0 + std::pow(10.0, -elo / 400.0)); };
    std::mt19937_64 playRng(999);
    auto playAt = [&](double x) -> std::pair<double,int> {
      double wr = winrateOfElo(-100.0 + 300.0 * (x - 0.5)); // reachable; -100 ELO at x=0.5
      int games = 200;
      std::binomial_distribution<int> binom(games, wr);
      return std::make_pair((double)binom(playRng), games);
    };
    for(int mr = 1; mr <= 3; mr++) {
      CalibrationResult res = calibrateToTarget(
        playAt, 0.0, 1.0, 0.36, 200, mr, 25.0, (uint64_t)(100 + mr), 0.5, nullptr);
      testAssert(res.converged == false);
      testAssert(res.rounds == mr);
    }
  }

  cout << "Done human SL tuner tests" << endl;
}

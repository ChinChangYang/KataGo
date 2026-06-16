#ifndef PROGRAM_HUMANSLTUNER_H_
#define PROGRAM_HUMANSLTUNER_H_

#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <vector>

// Pure math + round loop for the `tunehuman` subcommand.
// NO KataGo NN/search dependencies — fully unit-testable without model files.

// Binomial logistic regression winrate(x) = sigmoid(b0 + b1*x), fit by
// L2-regularized Newton-MAP. Linear logit because the strength coordinate is monotone.
class LogisticRS {
 public:
  // 400 / ln(10): converts a logit difference to ELO.
  static constexpr double ELO_PER_LOGIT = 400.0 / 2.302585092994046; // ~173.7178

  explicit LogisticRS(double l2_ = 0.5);

  void addSample(double x, double wins, double games); // wins may be fractional (draws = 0.5)
  LogisticRS& fit(int iters = 50);
  double predict(double x) const;               // sigmoid(b0 + b1 x)
  double root(double targetWinrate) const;      // x* with predict(x*) == target; NaN if degenerate
  double rootSeElo(double targetWinrate) const; // delta-method SE of x*, in ELO units; +inf if degenerate
  int distinctXCount(double eps = 1e-6) const;  // number of distinct sampled x values

  double getB0() const { return b0; }
  double getB1() const { return b1; }

 private:
  double l2;
  std::vector<double> xs;
  std::vector<double> ws;
  std::vector<double> ns;
  double b0;
  double b1;
  double cov[2][2]; // covariance of (b0,b1); valid after fit()
  bool fitted;
};

struct StrengthDialParams {
  double piklLambda;
  int    maxVisits;
  double deltaTau;
};

struct StrengthDialConfig {
  double piklFloor = 0.02;
  double piklMax = 1.0e4;
  int    searchVisits = 100; // must be >= 2
  int    maxVisitsCap = 400;
  double dtauMax = 0.6;
  static constexpr double PIKL_INERT = 1.0e9; // KataGo default; "off"
};

// Maps a scalar strength coordinate x in [0,3] (low=weak, high=strong) to the three dials,
// globally monotone in strength. Clamps x to [0,3].
StrengthDialParams strengthDialToParams(double x, const StrengthDialConfig& c);

struct CalibrationResult {
  double xStar;
  double eloSe;     // 1-sigma CI half-width in ELO at xStar
  int    totalGames;
  int    rounds;
  bool   converged;
  LogisticRS model; // final fitted surface (for reporting fitted ELO)
};

// playAt(x) plays a batch at dial x and returns {wins, games}; wins may be fractional.
// onRound(round, xStar, eloSe, distinctXs, totalGames) is optional progress logging.
CalibrationResult calibrateToTarget(
  const std::function<std::pair<double,int>(double)>& playAt,
  double xLo, double xHi, double targetWinrate,
  int gamesPerRound, int maxRounds, double eloTol,
  uint64_t rngSeed, double l2 = 0.5,
  const std::function<void(int,double,double,int,int)>& onRound = nullptr);

#endif // PROGRAM_HUMANSLTUNER_H_

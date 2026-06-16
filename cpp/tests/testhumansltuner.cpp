#include "../tests/tests.h"

#include "../program/humansltuner.h"

#include <cmath>

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

  cout << "Done human SL tuner tests" << endl;
}

#include "../core/global.h"
#include "../core/config_parser.h"
#include "../core/fileutils.h"
#include "../core/logger.h"
#include "../core/rand.h"
#include "../game/board.h"
#include "../game/boardhistory.h"
#include "../neuralnet/nninputs.h"
#include "../neuralnet/nneval.h"
#include "../neuralnet/sgfmetadata.h"
#include "../dataio/trainingwrite.h"
#include "../search/search.h"
#include "../search/searchparams.h"
#include "../program/setup.h"
#include "../program/play.h"
#include "../program/playsettings.h"
#include "../program/humansltuner.h"
#include "../command/commandline.h"
#include "../main.h"

#include <atomic>
#include <fstream>
#include <functional>
#include <mutex>
#include <sstream>
#include <thread>

using namespace std;

int MainCmds::tunehuman(const vector<string>& args) {
  Board::initHash();
  ScoreValue::initTables();

  string baselineConfigPath;
  string profile;
  double targetElo = 0.0;
  string outputConfigPath;
  string modelFile;
  string humanModelFile;
  double eloTol = 25.0;
  int gamesPerRound = 32;
  int maxRounds = 24;
  int numGameThreadsArgVal = -1;
  string seedStr = "tunehuman";
  int searchVisits = 100;
  int maxVisitsCap = 400;
  double piklFloor = 0.02;
  double piklMax = 1.0e4;
  double dtauMax = 0.6;
  double xLo = 0.0;
  double xHi = 3.0;

  try {
    KataGoCommandLine cmd("Tune human-SL play parameters to hit a target ELO offset vs a baseline config.");
    cmd.addModelFileArg();
    cmd.addHumanModelFileArg();
    TCLAP::ValueArg<string> baselineConfigArg("","baseline-config","Baseline human-SL config (defines ELO 0).",true,"","FILE");
    TCLAP::ValueArg<string> profileArg("","profile","Candidate humanSLProfile, e.g. preaz_8d.",true,"","PROFILE");
    TCLAP::ValueArg<double> targetEloArg("","target-elo","Desired (candidate - baseline) ELO. Negative = weaker.",true,0.0,"ELO");
    TCLAP::ValueArg<string> outputConfigArg("","output-config","Where to write the tuned config.",true,"","FILE");
    TCLAP::ValueArg<double> eloTolArg("","elo-tol","Stop when 1-sigma CI half-width (ELO) <= this.",false,25.0,"ELO");
    TCLAP::ValueArg<int> gamesPerRoundArg("","games-per-round","Games per dial value per round.",false,32,"N");
    TCLAP::ValueArg<int> maxRoundsArg("","max-rounds","Hard cap on rounds.",false,24,"N");
    TCLAP::ValueArg<int> numGameThreadsArg("","num-game-threads","Parallel games within a round.",false,-1,"N");
    TCLAP::ValueArg<string> seedArg("","seed","Master seed for reproducibility.",false,"tunehuman","SEED");
    TCLAP::ValueArg<int> searchVisitsArg("","search-visits","Visits in the piklLambda segment (>=2).",false,100,"N");
    TCLAP::ValueArg<int> maxVisitsCapArg("","max-visits-cap","Visits at the strong end.",false,400,"N");
    TCLAP::ValueArg<double> piklFloorArg("","pikl-floor","Smallest piklLambda (strongest).",false,0.02,"F");
    TCLAP::ValueArg<double> piklMaxArg("","pikl-max","Largest active piklLambda.",false,1.0e4,"F");
    TCLAP::ValueArg<double> dtauMaxArg("","dtau-max","Max temperature offset at the weak end.",false,0.6,"F");
    TCLAP::ValueArg<double> xLoArg("","x-lo","Low end of the strength coordinate search range.",false,0.0,"F");
    TCLAP::ValueArg<double> xHiArg("","x-hi","High end of the strength coordinate search range.",false,3.0,"F");
    cmd.add(baselineConfigArg);
    cmd.add(profileArg);
    cmd.add(targetEloArg);
    cmd.add(outputConfigArg);
    cmd.add(eloTolArg);
    cmd.add(gamesPerRoundArg);
    cmd.add(maxRoundsArg);
    cmd.add(numGameThreadsArg);
    cmd.add(seedArg);
    cmd.add(searchVisitsArg);
    cmd.add(maxVisitsCapArg);
    cmd.add(piklFloorArg);
    cmd.add(piklMaxArg);
    cmd.add(dtauMaxArg);
    cmd.add(xLoArg);
    cmd.add(xHiArg);
    cmd.parseArgs(args);

    modelFile = cmd.getModelFile();
    humanModelFile = cmd.getHumanModelFile();
    baselineConfigPath = baselineConfigArg.getValue();
    profile = profileArg.getValue();
    targetElo = targetEloArg.getValue();
    outputConfigPath = outputConfigArg.getValue();
    eloTol = eloTolArg.getValue();
    gamesPerRound = gamesPerRoundArg.getValue();
    maxRounds = maxRoundsArg.getValue();
    numGameThreadsArgVal = numGameThreadsArg.getValue();
    seedStr = seedArg.getValue();
    searchVisits = searchVisitsArg.getValue();
    maxVisitsCap = maxVisitsCapArg.getValue();
    piklFloor = piklFloorArg.getValue();
    piklMax = piklMaxArg.getValue();
    dtauMax = dtauMaxArg.getValue();
    xLo = xLoArg.getValue();
    xHi = xHiArg.getValue();
  }
  catch(TCLAP::ArgException& e) {
    cerr << "Error: " << e.error() << " for argument " << e.argId() << endl;
    return 1;
  }
  catch(const StringError& e) {
    cerr << "Error: " << e.what() << endl;
    return 1;
  }

  // ---- validation ----
  if(humanModelFile.empty()) { cerr << "Error: -human-model is required." << endl; return 1; }
  if(!FileUtils::exists(baselineConfigPath)) { cerr << "Error: baseline-config not found: " << baselineConfigPath << endl; return 1; }
  if(!FileUtils::exists(modelFile)) { cerr << "Error: model not found: " << modelFile << endl; return 1; }
  if(!FileUtils::exists(humanModelFile)) { cerr << "Error: human-model not found: " << humanModelFile << endl; return 1; }
  if(gamesPerRound < 1) { cerr << "Error: -games-per-round must be >= 1." << endl; return 1; }
  if(xLo >= xHi) { cerr << "Error: -x-lo must be < -x-hi." << endl; return 1; }
  if(eloTol <= 0.0) { cerr << "Error: -elo-tol must be > 0." << endl; return 1; }
  if(searchVisits < 2) { cerr << "Error: -search-visits must be >= 2 (piklLambda needs >1 visit)." << endl; return 1; }
  if(maxRounds < 1) { cerr << "Error: -max-rounds must be >= 1." << endl; return 1; }

  int numGameThreads = numGameThreadsArgVal > 0
    ? numGameThreadsArgVal
    : std::max(1, std::min(gamesPerRound, (int)std::thread::hardware_concurrency()));

  cout << "tunehuman parsed configuration:" << endl;
  cout << "  baseline-config = " << baselineConfigPath << endl;
  cout << "  profile         = " << profile << endl;
  cout << "  target-elo      = " << targetElo << endl;
  cout << "  output-config   = " << outputConfigPath << endl;
  cout << "  model           = " << modelFile << endl;
  cout << "  human-model     = " << humanModelFile << endl;
  cout << "  elo-tol         = " << eloTol << endl;
  cout << "  games-per-round = " << gamesPerRound << endl;
  cout << "  max-rounds      = " << maxRounds << endl;
  cout << "  num-game-threads= " << numGameThreads << endl;
  cout << "  seed            = " << seedStr << endl;
  cout << "  search-visits   = " << searchVisits << endl;
  cout << "  max-visits-cap  = " << maxVisitsCap << endl;
  cout << "  pikl-floor      = " << piklFloor << endl;
  cout << "  pikl-max        = " << piklMax << endl;
  cout << "  dtau-max        = " << dtauMax << endl;
  cout << "  x-lo / x-hi     = " << xLo << " / " << xHi << endl;

  // TODO(Task 7): load nets, build params, play games, calibrate, write output.
  cout << "tunehuman: flag parsing OK (game loop not yet implemented)." << endl;
  return 0;
}

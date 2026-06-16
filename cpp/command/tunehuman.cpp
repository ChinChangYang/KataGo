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
  if(maxRounds < 4)
    cout << "WARNING: -max-rounds " << maxRounds << " < 4: calibration needs at least 4 rounds to"
         << " reach 'converged' (it requires 4 distinct dial samples). It will still run and write"
         << " a best-achievable config, but converged will be false." << endl;

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

  // ---- load baseline config, logger, params, nets ----
  ConfigParser baselineCfg(baselineConfigPath);
  Logger logger(&baselineCfg, true, false, true, false); // log to stdout, with time, don't dump config

  const bool hasHumanModel = true;
  SearchParams baselineParams = Setup::loadSingleParams(baselineCfg, Setup::SETUP_FOR_GTP, hasHumanModel);
  string baselineText = baselineCfg.getContents();

  SearchParams candidateBaseParams = baselineParams;
  try {
    candidateBaseParams.humanSLProfile = SGFMetadata::getProfile(profile);
  }
  catch(const StringError& e) {
    cerr << "Error: invalid -profile '" << profile << "': " << e.what() << endl;
    return 1;
  }

  Rand seedRand(seedStr);
  int maxBotThreads = std::max(1, baselineParams.numThreads);
  int expectedConcurrentEvals = maxBotThreads * numGameThreads;
  const int defaultMaxBatchSize = std::max(8, ((expectedConcurrentEvals + 3) / 4) * 4);
  const bool defaultRequireExactNNLen = true; // fixed 19x19
  const bool disableFP16 = false;
  const string expectedSha256 = "";
  const int boardLen = 19;

  NNEvaluator* mainNNEval = Setup::initializeNNEvaluator(
    modelFile, modelFile, expectedSha256, baselineCfg, logger, seedRand, expectedConcurrentEvals,
    boardLen, boardLen, defaultMaxBatchSize, defaultRequireExactNNLen, disableFP16, Setup::SETUP_FOR_GTP);
  logger.write("Loaded main net");

  NNEvaluator* humanNNEval = Setup::initializeNNEvaluator(
    humanModelFile, humanModelFile, expectedSha256, baselineCfg, logger, seedRand, expectedConcurrentEvals,
    boardLen, boardLen, defaultMaxBatchSize, defaultRequireExactNNLen, disableFP16, Setup::SETUP_FOR_GTP);
  logger.write("Loaded human SL net");
  if(!humanNNEval->requiresSGFMetadata())
    logger.write("WARNING: -human-model was not trained from SGF metadata; profile may have no effect.");

  // ---- minimal game-setup config (rules/board/komi only; bot strength comes from BotSpec) ----
  std::map<string,string> gameCfgMap = {
    {"koRules", "SIMPLE"},
    {"scoringRules", "AREA"},
    {"taxRules", "NONE"},
    {"multiStoneSuicideLegals", "false"},
    {"hasButtons", "false"},
    {"bSizes", "19"},
    {"bSizeRelProbs", "1"},
    {"komiMean", "7.5"},
    {"logSearchInfo", "false"},
    {"logMoves", "false"},
    {"maxMovesPerGame", "1200"},
  };
  ConfigParser gameCfg(gameCfgMap);
  PlaySettings playSettings; // default: forSelfPlay=false, allowResignation=false, no fork/cheap/reduce
  GameRunner* gameRunner = new GameRunner(gameCfg, playSettings, logger);

  // ---- dial config + target ----
  StrengthDialConfig dialConfig;
  dialConfig.piklFloor = piklFloor;
  dialConfig.piklMax = piklMax;
  dialConfig.searchVisits = searchVisits;
  dialConfig.maxVisitsCap = maxVisitsCap;
  dialConfig.dtauMax = dtauMax;

  const double TEMP_CAP = 1.0;
  auto clipTemp = [TEMP_CAP](double v) { return v < 0.0 ? 0.0 : (v > TEMP_CAP ? TEMP_CAP : v); };
  double targetWinrate = 1.0 / (1.0 + std::pow(10.0, -targetElo / 400.0));

  // ---- playAt(x): set candidate dials, play gamesPerRound games candidate-vs-baseline ----
  int roundCounter = 0;
  auto playAt = [&](double x) -> std::pair<double,int> {
    int round = roundCounter++;
    StrengthDialParams dials = strengthDialToParams(x, dialConfig);

    SearchParams cand = candidateBaseParams;
    cand.humanSLChosenMovePiklLambda = dials.piklLambda;
    cand.maxVisits = dials.maxVisits;
    cand.chosenMoveTemperature = clipTemp(baselineParams.chosenMoveTemperature + dials.deltaTau);
    cand.chosenMoveTemperatureEarly = clipTemp(baselineParams.chosenMoveTemperatureEarly + dials.deltaTau);

    std::atomic<int> nextGameIdx(0);
    double candidateWins = 0.0;
    int countedGames = 0;
    std::mutex tallyMutex;

    auto worker = [&]() {
      while(true) {
        int gameIdx = nextGameIdx.fetch_add(1);
        if(gameIdx >= gamesPerRound)
          break;
        bool candIsBlack = (gameIdx % 2 == 0);
        string seed = seedStr + ":r" + Global::intToString(round) + ":g" + Global::intToString(gameIdx);

        MatchPairer::BotSpec specCand;
        specCand.botIdx = 0; specCand.botName = "cand";
        specCand.nnEval = mainNNEval; specCand.humanEval = humanNNEval;
        specCand.baseParams = cand;
        MatchPairer::BotSpec specBase;
        specBase.botIdx = 1; specBase.botName = "base";
        specBase.nnEval = mainNNEval; specBase.humanEval = humanNNEval;
        specBase.baseParams = baselineParams;

        const MatchPairer::BotSpec& specB = candIsBlack ? specCand : specBase;
        const MatchPairer::BotSpec& specW = candIsBlack ? specBase : specCand;

        std::function<bool()> shouldStop = []() { return false; };
        std::function<void(const MatchPairer::BotSpec&, Search*)> noopAfterInit =
          [](const MatchPairer::BotSpec&, Search*) {};

        FinishedGameData* g = gameRunner->runGame(
          seed, specB, specW, NULL, NULL, logger,
          shouldStop, nullptr, nullptr, noopAfterInit, nullptr);
        if(g == NULL)
          continue;

        bool counted = true;
        double winInc = 0.0;
        if(g->endHist.isNoResult) {
          counted = false;
        } else {
          Player winner = g->endHist.winner;
          Player candColor = candIsBlack ? P_BLACK : P_WHITE;
          if(winner == C_EMPTY) winInc = 0.5;          // draw
          else winInc = (winner == candColor) ? 1.0 : 0.0;
        }
        delete g;

        if(counted) {
          std::lock_guard<std::mutex> lock(tallyMutex);
          candidateWins += winInc;
          countedGames += 1;
        }
      }
    };

    std::vector<std::thread> threads;
    threads.reserve(numGameThreads);
    for(int t = 0; t < numGameThreads; t++)
      threads.emplace_back(worker);
    for(size_t t = 0; t < threads.size(); t++)
      threads[t].join();

    return std::make_pair(candidateWins, countedGames);
  };

  // ---- progress logging per round ----
  auto onRound = [&](int round, double xStar, double eloSe, int distinctXs, int totalGames) {
    StrengthDialParams d = strengthDialToParams(xStar, dialConfig);
    logger.write(
      "Round " + Global::intToString(round) +
      ": x*=" + Global::doubleToString(xStar) +
      " eloSe=" + Global::doubleToString(eloSe) +
      " distinctX=" + Global::intToString(distinctXs) +
      " games=" + Global::intToString(totalGames) +
      " dial[piklLambda=" + Global::doubleToString(d.piklLambda) +
      " maxVisits=" + Global::intToString(d.maxVisits) +
      " deltaTau=" + Global::doubleToString(d.deltaTau) + "]");
  };

  // ---- run calibration ----
  uint64_t rngSeed = (uint64_t)std::hash<std::string>()(seedStr);
  CalibrationResult result = calibrateToTarget(
    playAt, xLo, xHi, targetWinrate, gamesPerRound, maxRounds, eloTol, rngSeed, 0.5, onRound);

  // ---- compute final dials + fitted ELO ----
  StrengthDialParams finalDials = strengthDialToParams(result.xStar, dialConfig);
  double tempBase = clipTemp(baselineParams.chosenMoveTemperature + finalDials.deltaTau);
  double tempEarly = clipTemp(baselineParams.chosenMoveTemperatureEarly + finalDials.deltaTau);
  double fittedWinrate = result.model.predict(result.xStar);
  double fittedElo = 400.0 * std::log10(fittedWinrate / (1.0 - fittedWinrate));
  bool reachedBoundary = (result.xStar <= xLo + 1e-6) || (result.xStar >= xHi - 1e-6);

  // ---- build header + overridden config text ----
  std::ostringstream hdr;
  hdr << "# Tuned by `katago tunehuman`.\n";
  hdr << "# baseline-config : " << baselineConfigPath << "\n";
  hdr << "# profile         : " << profile << "\n";
  hdr << "# models          : " << modelFile << " / " << humanModelFile << "\n";
  hdr << "# target-elo      : " << targetElo << "   (targetWinrate " << targetWinrate << " vs baseline)\n";
  hdr << "# achieved        : fitted " << fittedElo << " ELO  +/- " << result.eloSe
      << " (1-sigma),  over " << result.totalGames << " games, " << result.rounds
      << " rounds, converged=" << (result.converged ? "yes" : "no") << "\n";
  hdr << "# dial            : x*=" << result.xStar << "  piklLambda=" << finalDials.piklLambda
      << "  maxVisits=" << finalDials.maxVisits << "  deltaTau=" << finalDials.deltaTau << "\n";
  hdr << "# seed            : " << seedStr << "\n";
  if(reachedBoundary) {
    hdr << "# WARNING: target ELO not reachable within the dial range; best-achievable shown.\n";
    hdr << "#          Widen -max-visits-cap / -dtau-max / -x-lo / -x-hi to extend the range.\n";
    logger.write("WARNING: target ELO not reachable within dial range; wrote best-achievable config (x* at boundary).");
  }
  hdr << "\n";

  std::vector<std::pair<string,string>> overrides;
  overrides.push_back(std::make_pair("humanSLProfile", profile));
  overrides.push_back(std::make_pair("humanSLChosenMovePiklLambda", Global::doubleToString(finalDials.piklLambda)));
  overrides.push_back(std::make_pair("maxVisits", Global::intToString(finalDials.maxVisits)));
  overrides.push_back(std::make_pair("chosenMoveTemperature", Global::doubleToString(tempBase)));
  overrides.push_back(std::make_pair("chosenMoveTemperatureEarly", Global::doubleToString(tempEarly)));

  string finalText = hdr.str() + overrideConfigText(baselineText, overrides);

  ofstream out;
  FileUtils::open(out, outputConfigPath);
  out << finalText;
  out.close();

  logger.write(
    "Wrote tuned config to " + outputConfigPath +
    " (fitted " + Global::doubleToString(fittedElo) + " ELO +/- " + Global::doubleToString(result.eloSe) +
    ", " + Global::intToString(result.totalGames) + " games, " + Global::intToString(result.rounds) +
    " rounds, converged=" + (result.converged ? "yes" : "no") + ")");

  delete gameRunner;
  delete mainNNEval;
  delete humanNNEval;
  return 0;
}

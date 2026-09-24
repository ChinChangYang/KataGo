#include "../tests/tests.h"

#include "../core/fileutils.h"
#include "../dataio/files.h"
#include "../dataio/loadmodel.h"
#include "../neuralnet/sgfmetadata.h"

#include <chrono>
#include <thread>

//------------------------
#include "../core/using.h"
//------------------------
using namespace TestCommon;

void Tests::runCollectFilesTests() {
  {
    vector<string> collected;
    cout << "Collecting sgfs from tests" << endl;
    FileHelpers::collectSgfsFromDir("tests", collected);
    std::sort(collected.begin(),collected.end());
    for(const string& s: collected) {
      cout << s << endl;
    }
  }
  {
    vector<string> collected;
    cout << "Collecting cfgs from tests" << endl;
    FileUtils::collectFiles("tests", [](const std::string& s) {return Global::isSuffix(s,".cfg");}, collected);
    std::sort(collected.begin(),collected.end());
    for(const string& s: collected) {
      cout << s << endl;
    }
  }
}

void Tests::runSgfMetadataProfileTests() {
  cout << "Running sgf metadata profile tests" << endl;
  auto throws = [](const string& name) {
    try {
      SGFMetadata::getProfile(name);
    }
    catch(const StringError&) {
      return true;
    }
    return false;
  };

  // rankyear_<year>_<rank> is the KGS rank profile dated <year>-09-01, so 2016 is preaz exactly.
  testAssert(SGFMetadata::getProfile("rankyear_2016_5k") == SGFMetadata::getProfile("preaz_5k"));
  testAssert(SGFMetadata::getProfile("rankyear_2016_9d") == SGFMetadata::getProfile("preaz_9d"));
  testAssert(SGFMetadata::getProfile("rankyear_2016_25k") == SGFMetadata::getProfile("preaz_25k"));
  testAssert(SGFMetadata::getProfile("rankyear_2016_5k_3d") == SGFMetadata::getProfile("preaz_5k_3d"));

  {
    SGFMetadata meta = SGFMetadata::getProfile("rankyear_2019_5k");
    testAssert(meta.gameDate == SimpleDate(2019,9,1));
    testAssert(meta.source == SGFMetadata::SOURCE_KGS);
    testAssert(meta.inverseBRank == 14 && meta.inverseWRank == 14);
    SGFMetadata expected = SGFMetadata::getProfile("preaz_5k");
    expected.gameDate = SimpleDate(2019,9,1);
    testAssert(meta == expected);
  }
  {
    // rank_ is dated 2020-03-01, so the same year is not the same profile.
    testAssert(SGFMetadata::getProfile("rankyear_2020_3d") != SGFMetadata::getProfile("rank_3d"));
    SGFMetadata asym = SGFMetadata::getProfile("rankyear_2023_2k_1d");
    testAssert(asym.inverseBRank == 11 && asym.inverseWRank == 9);
    testAssert(asym.gameDate == SimpleDate(2023,9,1));
  }

  // Legacy forms keep their dates.
  testAssert(SGFMetadata::getProfile("preaz_5k").gameDate == SimpleDate(2016,9,1));
  testAssert(SGFMetadata::getProfile("rank_5k").gameDate == SimpleDate(2020,3,1));
  testAssert(SGFMetadata::getProfile("proyear_1997").gameDate == SimpleDate(1997,6,1));

  testAssert(throws("rankyear_abc_5k"));
  testAssert(throws("rankyear_2019_99k"));
  testAssert(throws("rankyear_2019"));
  testAssert(throws("rankyear_2019_"));
  testAssert(throws("rankyear__5k"));
  testAssert(throws("rankyear_1799_5k"));
  testAssert(throws("rankyear_2101_5k"));
  testAssert(throws("rankyear_2019_5k_3d_1d"));
  testAssert(!throws("rankyear_1800_5k"));
  testAssert(!throws("rankyear_2100_5k"));
}

void Tests::runLoadModelTests() {
  bool logToStdoutDefault = true;
  bool logToStderrDefault = false;
  bool logTimeDefault = false;
  Logger logger(nullptr, logToStdoutDefault, logToStderrDefault, logTimeDefault);

  {
    string modelsDir = "tests/models/findLatestModelTest1";
    string modelName;
    string modelFile;
    string modelDir;
    time_t modelTime;
    bool suc = LoadModel::findLatestModel(modelsDir, logger, modelName, modelFile, modelDir, modelTime);
    testAssert(suc);
    cout << modelsDir << endl;
    cout << modelName << " " << modelFile << " " << modelDir << " " << modelTime << endl;
    testAssert(modelTime == 0);
    testAssert(modelName == "random");
    testAssert(modelDir == "/dev/null");
    testAssert(modelFile == "/dev/null");
  }

  {
    string modelsDir = "tests/models/findLatestModelTest2";
    string modelName;
    string modelFile;
    string modelDir;
    time_t modelTime;
    bool suc = LoadModel::findLatestModel(modelsDir, logger, modelName, modelFile, modelDir, modelTime);
    testAssert(suc);
    cout << modelsDir << endl;
    cout << modelName << " " << modelFile << " " << modelDir << endl;
    testAssert(modelTime > 0);
    testAssert(modelName == "abc.bin.gz");
    testAssert(modelDir == "tests/models/findLatestModelTest2" || modelDir == "tests\\models\\findLatestModelTest2");
    testAssert(modelFile == "tests/models/findLatestModelTest2/abc.bin.gz" || modelFile == "tests\\models\\findLatestModelTest2\\abc.bin.gz");
    testAssert(FileUtils::weaklyCanonical(modelDir) == FileUtils::weaklyCanonical(modelsDir));
    testAssert(Global::isPrefix(FileUtils::weaklyCanonical(modelDir), FileUtils::weaklyCanonical(modelsDir)));
  }


  {
    string modelsDir = "tests/models/findLatestModelTest3";
    string modelName;
    string modelFile;
    string modelDir;
    time_t modelTime;
    bool suc = LoadModel::findLatestModel(modelsDir, logger, modelName, modelFile, modelDir, modelTime);
    testAssert(suc);
    cout << modelsDir << endl;
    cout << modelName << " " << modelFile << " " << modelDir << endl;
    testAssert(modelTime > 0);
    testAssert(modelName == "def");
    testAssert(modelDir == "tests/models/findLatestModelTest3/def" || modelDir == "tests\\models\\findLatestModelTest3\\def");
    testAssert(modelFile == "tests/models/findLatestModelTest3/def/model.bin.gz" || modelFile == "tests\\models\\findLatestModelTest3\\def\\model.bin.gz");
    testAssert(FileUtils::weaklyCanonical(modelDir) != FileUtils::weaklyCanonical(modelsDir));
    testAssert(Global::isPrefix(FileUtils::weaklyCanonical(modelDir), FileUtils::weaklyCanonical(modelsDir)));
  }

  {
    LoadModel::setLastModifiedTimeToNow("tests/models/findLatestModelTest4/abc.bin.gz", logger);

    string modelsDir = "tests/models/findLatestModelTest4";
    string modelName;
    string modelFile;
    string modelDir;
    time_t modelTime;
    bool suc = LoadModel::findLatestModel(modelsDir, logger, modelName, modelFile, modelDir, modelTime);
    testAssert(suc);
    cout << modelsDir << endl;
    cout << modelName << " " << modelFile << " " << modelDir << endl;
    testAssert(modelTime > 0);
    testAssert(modelName == "abc.bin.gz");
    testAssert(modelDir == "tests/models/findLatestModelTest4" || modelDir == "tests\\models\\findLatestModelTest4");
    testAssert(modelFile == "tests/models/findLatestModelTest4/abc.bin.gz" || modelFile == "tests\\models\\findLatestModelTest4\\abc.bin.gz");
    testAssert(FileUtils::weaklyCanonical(modelDir) == FileUtils::weaklyCanonical(modelsDir));
    testAssert(Global::isPrefix(FileUtils::weaklyCanonical(modelDir), FileUtils::weaklyCanonical(modelsDir)));
  }
  std::this_thread::sleep_for(std::chrono::duration<double>(1.5));
  {
    LoadModel::setLastModifiedTimeToNow("tests/models/findLatestModelTest4/def/model.bin.gz", logger);

    string modelsDir = "tests/models/findLatestModelTest4";
    string modelName;
    string modelFile;
    string modelDir;
    time_t modelTime;
    bool suc = LoadModel::findLatestModel(modelsDir, logger, modelName, modelFile, modelDir, modelTime);
    testAssert(suc);
    cout << modelsDir << endl;
    cout << modelName << " " << modelFile << " " << modelDir << endl;
    testAssert(modelTime > 0);
    testAssert(modelName == "def");
    testAssert(modelDir == "tests/models/findLatestModelTest4/def" || modelDir == "tests\\models\\findLatestModelTest4\\def");
    testAssert(modelFile == "tests/models/findLatestModelTest4/def/model.bin.gz" || "tests\\models\\findLatestModelTest4\\def\\model.bin.gz");
    testAssert(FileUtils::weaklyCanonical(modelDir) != FileUtils::weaklyCanonical(modelsDir));
    testAssert(Global::isPrefix(FileUtils::weaklyCanonical(modelDir), FileUtils::weaklyCanonical(modelsDir)));
  }
  std::this_thread::sleep_for(std::chrono::duration<double>(1.5));
  {
    LoadModel::setLastModifiedTimeToNow("tests/models/findLatestModelTest4/def/ghi.bin.gz", logger);

    string modelsDir = "tests/models/findLatestModelTest4";
    string modelName;
    string modelFile;
    string modelDir;
    time_t modelTime;
    bool suc = LoadModel::findLatestModel(modelsDir, logger, modelName, modelFile, modelDir, modelTime);
    testAssert(suc);
    cout << modelsDir << endl;
    cout << modelName << " " << modelFile << " " << modelDir << endl;
    testAssert(modelTime > 0);
    testAssert(modelName == "ghi.bin.gz");
    testAssert(modelDir == "tests/models/findLatestModelTest4/def" || modelDir == "tests\\models\\findLatestModelTest4\\def");
    testAssert(modelFile == "tests/models/findLatestModelTest4/def/ghi.bin.gz" || modelFile == "tests\\models\\findLatestModelTest4\\def\\ghi.bin.gz");
    testAssert(FileUtils::weaklyCanonical(modelDir) != FileUtils::weaklyCanonical(modelsDir));
    testAssert(Global::isPrefix(FileUtils::weaklyCanonical(modelDir), FileUtils::weaklyCanonical(modelsDir)));
  }
  cout << "testloadmodel okay" << endl;
}

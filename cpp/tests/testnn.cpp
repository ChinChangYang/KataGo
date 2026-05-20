#include "../tests/tests.h"
#include "../neuralnet/nninterface.h"

#include <cmath>

using namespace std;

static bool approxEqual(float x, float y, bool useFP16) {
  float tolerance;
  if(useFP16)
    tolerance = 0.03f * std::max(std::fabs(x),std::max(std::fabs(y),3.0f));
  else
    tolerance = 0.0001f * std::max(std::fabs(x),std::max(std::fabs(y),1.0f));
  return std::fabs(x - y) < tolerance;
}

static void checkApproxEqual(
  const string& label,
  const vector<float>& vec, const vector<float>& expected, int nSize, int cSize, int ySize, int xSize, bool useFP16,
  const char* file, const char* func, int line
) {
  int cyxSize = cSize * ySize * xSize;
  int yxSize = ySize * xSize;

  int totalSize = nSize * cSize * ySize * xSize;
  if (expected.size() < totalSize) {
    cout << "Size mismatch: expected = " << expected.size() << " totalSize = " << totalSize << endl;
    return;
  }
  if (vec.size() < totalSize) {
    cout << "Size mismatch: vec = " << vec.size() << " totalSize = " << totalSize << endl;
    return;
  }

  bool mismatch = false;
  for(int n = 0; n < nSize; n++) {
    for(int c = 0; c < cSize; c++) {
      for(int y = 0; y < ySize; y++) {
        for(int x = 0; x < xSize; x++) {
          int i = n * cyxSize + c * yxSize + y * xSize + x;
          if(!approxEqual(vec[i],expected[i],useFP16) && !mismatch) {
            mismatch = true;
            cout << "File " << file << " func " << func << " line " << line << endl;
            cout << label << endl;
            cout << "Test failed at n c y x = " << n << " " << c << " " << y << " " << x << endl;
          }
        }
      }
    }
  }
  if(mismatch) {
    cout << "==========" << endl;
    cout << "Actual" << endl;
    cout << "==========" << endl;
    for(int n = 0; n < nSize; n++) {
      for(int c = 0; c < cSize; c++) {
        for(int y = 0; y < ySize; y++) {
          for(int x = 0; x < xSize; x++) {
            int i = n * cyxSize + c * yxSize + y * xSize + x;
            cout << Global::strprintf("%.5g, ",vec[i]);
          }
          cout << endl;
        }
        cout << endl;
      }
      cout << "-------" << endl;
    }
    cout << "==========" << endl;
    cout << "Expected" << endl;
    cout << "==========" << endl;
    for(int n = 0; n < nSize; n++) {
      for(int c = 0; c < cSize; c++) {
        for(int y = 0; y < ySize; y++) {
          for(int x = 0; x < xSize; x++) {
            int i = n * cyxSize + c * yxSize + y * xSize + x;
            cout << Global::strprintf("%.5g, ",expected[i]);
          }
          cout << endl;
        }
        cout << endl;
      }
      cout << "-------" << endl;
    }
  }
}
#define CHECK_APPROX_EQUAL(label,vec,expected,n,c,h,w,useFP16) (checkApproxEqual((label),(vec),(expected),(n),(c),(h),(w),(useFP16),__FILE__,#vec,__LINE__))


static vector<float> NCHWtoNHWC(const vector<float>& vec, int nSize, int cSize, int ySize, int xSize) {
  vector<float> ret(vec.size());
  int cyxSize = cSize * ySize * xSize;
  int yxSize = ySize * xSize;
  int xcSize = xSize * cSize;
  for(int n = 0; n < nSize; n++) {
    for(int c = 0; c < cSize; c++) {
      for(int y = 0; y < ySize; y++) {
        for(int x = 0; x < xSize; x++) {
          ret[n * cyxSize + y * xcSize + x * cSize + c] = vec[n * cyxSize + c * yxSize + y * xSize + x];
        }
      }
    }
  }
  return ret;
}


static void testConvLayer(int64_t& numTestsRun) {

  auto testConfigurations = [&](
    const string& label,
    int batchSize, int nnXLen, int nnYLen,
    const ConvLayerDesc& desc, const vector<float>& input, const vector<float>& expected
  ) {
    for(int useNHWC = 0; useNHWC <= 1; useNHWC++) {
      for(int useFP16 = 0; useFP16 <= 1; useFP16++) {
        vector<float> inputThisLoop = useNHWC ? NCHWtoNHWC(input,batchSize,desc.inChannels,nnYLen,nnXLen) : input;
        vector<float> expectedThisLoop = useNHWC ? NCHWtoNHWC(expected,batchSize,desc.outChannels,nnYLen,nnXLen) : expected;

        vector<float> outputThisLoop;
        bool supported = NeuralNet::testEvaluateConv(
          &desc,batchSize,nnXLen,nnYLen,useFP16,useNHWC,inputThisLoop,outputThisLoop
        );

        if(supported) {
          numTestsRun += 1;
          string subLabel = label + Global::strprintf(" useNHWC %d useFP16 %d", useNHWC, useFP16);
          if(useNHWC)
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,nnYLen,nnXLen,desc.outChannels,useFP16);
          else
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,desc.outChannels,nnYLen,nnXLen,useFP16);
        }
      }
    }
  };

  {
    int batchSize = 2;
    int inChannels = 2;
    int nnYLen = 3;
    int nnXLen = 4;

    //NCHW
    vector<float> input({
      5,5,4,4,
      5,5,4,4,
      1,1,8,8,

      0,1,2,3,
      3,4,5,6,
      8,7,6,5,

      0,1,0,2,
      3,0,4,0,
      0,5,0,6,

      1,0,0,2,
      0,2,2,0,
      0,2,2,0,
    });

    {
      string label("1x1 convolution");

      //oc,ic,y,x
      vector<float> convWeights({
          0.0f,1.0f,
          1.0f,-1.0f,
          10.0f,0.1f,
      });
      //NCHW
      vector<float> expected({
        0.0f, 1.0f, 2.0f, 3.0f,
        3.0f, 4.0f, 5.0f, 6.0f,
        8.0f, 7.0f, 6.0f, 5.0f,

        5.0f, 4.0f, 2.0f, 1.0f,
        2.0f, 1.0f, -1.0f, -2.0f,
        -7.0f, -6.0f, 2.0f, 3.0f,

        50.0f, 50.1f, 40.2f, 40.3f,
        50.3f, 50.4f, 40.5f, 40.6f,
        10.8f, 10.7f, 80.6f, 80.5f,

        1.0f, 0.0f, 0.0f, 2.0f,
        0.0f, 2.0f, 2.0f, 0.0f,
        0.0f, 2.0f, 2.0f, 0.0f,

        -1.0f, 1.0f, 0.0f, 0.0f,
        3.0f, -2.0f, 2.0f, 0.0f,
        0.0f, 3.0f, -2.0f, 6.0f,

        0.1f, 10.0f, 0.0f, 20.2f,
        30.0f, 0.2f, 40.2f, 0.0f,
        0.0f, 50.2f, 0.2f, 60.0f,
      });

      ConvLayerDesc desc;
      desc.convYSize = 1;
      desc.convXSize = 1;
      desc.inChannels = inChannels;
      desc.outChannels = 3;
      desc.dilationY = 1;
      desc.dilationX = 1;
      desc.weights = convWeights;

      testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,expected);
    }

    {
      string label("3x3 convolution");

      //oc,ic,y,x
      vector<float> convWeights({
          1,0,0,
          0,0,0,
          0,0,0,

          0,0,0,
          0,0,0,
          0,0,0,

          0,0,0,
          0,0,1,
          0,1,0,

          0,0,0,
          0,-1,0,
          0,0,0,

          0,0,0,
          0,1,0,
          0,0,0,

          0,0,0,
          0,0,0,
          0,0,2,
      });
      //NCHW
      vector<float> expected({
        0, 0, 0, 0,
        0, 5, 5, 4,
        0, 5, 5, 4,

        10, 8, 6, 1,
        3, 1, 7, 2,
        -7, 1, 2, -5,

        13, 15, 16, 4,
        19, 17, 14, 4,
        1, 1, 8, 8,

        0, 0, 0, 0,
        0, 0, 1, 0,
        0, 3, 0, 4,

        3, 0, 6, -2,
        0, 7, -2, 6,
        5, -2, 4, 0,

        4, 5, 0, 2,
        7, 4, 4, 0,
        0, 5, 0, 6,
      });

      ConvLayerDesc desc;
      desc.convYSize = 3;
      desc.convXSize = 3;
      desc.inChannels = inChannels;
      desc.outChannels = 3;
      desc.dilationY = 1;
      desc.dilationX = 1;
      desc.weights = convWeights;

      testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,expected);
    }

    {
      string label("5x5 convolution");

      //oc,ic,y,x
      vector<float> convWeights({
          0,0,0,0,1,
          0,0,0,1,0,
          0,0,1,0,0,
          0,0,0,0,0,
          0,0,0,0,0,

          0,0,0,0,0,
          0,0,0,0,0,
          0,0,1,0,0,
          0,1,0,0,0,
          1,0,0,0,0,

          0,0,0,0,0,
          0,0,0,0,0,
          0,0,0,0,0,
          0,0,0,0,0,
          0,0,0,0,2,

          0,0,0,0,0,
          0,0,1,0,0,
          2,0,0,0,0,
          0,0,0,0,0,
          0,0,0,0,0,
      });

      //NCHW
      vector<float> expected({
        5, 9,18,19,
       13,21,20,16,
       18,16,18,13,

       16,16, 0, 2,
        0, 1, 8,11,
        3, 4,21,20,

        1, 1, 2, 8,
        4, 2,10, 2,
        0,13, 2, 6,

        0,12, 2, 0,
        1, 0, 0, 6,
        0, 2, 2, 4,
      });

      ConvLayerDesc desc;
      desc.convYSize = 5;
      desc.convXSize = 5;
      desc.inChannels = inChannels;
      desc.outChannels = 2;
      desc.dilationY = 1;
      desc.dilationX = 1;
      desc.weights = convWeights;

      testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,expected);
    }

  }


}


static void testBatchNormLayer(int64_t& numTestsRun) {

  auto testConfigurations = [&](
    const string& label,
    int batchSize, int nnXLen, int nnYLen,
    const BatchNormLayerDesc& desc, const vector<float>& input, const vector<float>& mask, const vector<float>& expected
  ) {
    for(int useNHWC = 0; useNHWC <= 1; useNHWC++) {
      for(int useFP16 = 0; useFP16 <= 1; useFP16++) {
        vector<float> inputThisLoop = useNHWC ? NCHWtoNHWC(input,batchSize,desc.numChannels,nnYLen,nnXLen) : input;
        vector<float> maskThisLoop = mask;
        vector<float> expectedThisLoop = useNHWC ? NCHWtoNHWC(expected,batchSize,desc.numChannels,nnYLen,nnXLen) : expected;

        vector<float> outputThisLoop;
        bool supported = NeuralNet::testEvaluateBatchNorm(
          &desc,batchSize,nnXLen,nnYLen,useFP16,useNHWC,inputThisLoop,maskThisLoop,outputThisLoop
        );

        if(supported) {
          numTestsRun += 1;
          string subLabel = label + Global::strprintf(" useNHWC %d useFP16 %d", useNHWC, useFP16);
          if(useNHWC)
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,nnYLen,nnXLen,desc.numChannels,useFP16);
          else
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,desc.numChannels,nnYLen,nnXLen,useFP16);
        }
      }
    }
  };

  {
    int batchSize = 2;
    int numChannels = 2;
    int nnYLen = 2;
    int nnXLen = 5;

    //NCHW
    vector<float> input({
        5,5,4,4,9,
        1,1,8,8,9,

        0,1,2,3,4,
        8,7,6,5,4,

        3,0,4,0,5,
        0,5,0,6,0,

        1,0,0,2,1,
        0,2,2,0,2,
    });

    {
      string label("Batch norm");

      BatchNormLayerDesc desc;
      desc.numChannels = numChannels;
      desc.epsilon = 0.1f;
      desc.hasScale = true;
      desc.hasBias = true;
      desc.mean = vector<float>({0.0f,2.0f});
      desc.variance = vector<float>({3.9f,0.15f});
      desc.scale = vector<float>({0.1f,1.0f});
      desc.bias = vector<float>({10.0f,0.0f});

      vector<float> mask({
        1,1,1,1,1,
        1,1,1,1,1,

        1,1,1,1,1,
        1,1,1,1,1,
      });

      //NCHW
      vector<float> expected({
          10.25f, 10.25f, 10.2f, 10.2f, 10.45f,
          10.05f, 10.05f, 10.4f, 10.4f, 10.45f,

          -4.0f, -2.0f, 0.0f, 2.0f, 4.0f,
          12.0f, 10.0f, 8.0f, 6.0f, 4.0f,

          10.15f, 10.00f, 10.20f, 10.00f, 10.25f,
          10.00f, 10.25f, 10.00f, 10.30f, 10.00f,

          -2.0f, -4.0f, -4.0f, 0.0f, -2.0f,
          -4.0f, 0.0f, 0.0f, -4.0f, 0.0f,
      });
      testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,mask,expected);
    }

    {
      string label("Batch norm with mask");

      BatchNormLayerDesc desc;
      desc.numChannels = numChannels;
      desc.epsilon = 0.1f;
      desc.hasScale = false;
      desc.hasBias = true;
      desc.mean = vector<float>({0.0f,2.0f});
      desc.variance = vector<float>({3.9f,0.15f});
      desc.scale = vector<float>({1.0f,1.0f});
      desc.bias = vector<float>({10.0f,0.0f});

      vector<float> mask({
        1,1,1,0,0,
        1,1,1,0,0,

        1,1,1,1,1,
        0,0,0,0,0,
      });

      //NCHW
      vector<float> expected({
          12.5, 12.5, 12, 0, 0,
          10.5, 10.5, 14, 0, 0,

          -4, -2, 0, 0, 0,
          12, 10, 8, 0, 0,

          11.5, 10, 12, 10, 12.5,
          0, 0, 0, 0, 0,

          -2, -4, -4, 0, -2,
          0, 0, 0, 0, 0,
      });

      testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,mask,expected);
    }

  }

}


static void testResidualBlock(int64_t& numTestsRun) {

  auto testConfigurations = [&](
    const string& label,
    int batchSize, int nnXLen, int nnYLen,
    const ResidualBlockDesc& desc, const vector<float>& input, const vector<float>& mask, const vector<float>& expected
  ) {
    for(int useNHWC = 0; useNHWC <= 1; useNHWC++) {
      for(int useFP16 = 0; useFP16 <= 1; useFP16++) {
        vector<float> inputThisLoop = useNHWC ? NCHWtoNHWC(input,batchSize,desc.preBN.numChannels,nnYLen,nnXLen) : input;
        vector<float> maskThisLoop = mask;
        vector<float> expectedThisLoop = useNHWC ? NCHWtoNHWC(expected,batchSize,desc.preBN.numChannels,nnYLen,nnXLen) : expected;

        vector<float> outputThisLoop;
        bool supported = NeuralNet::testEvaluateResidualBlock(
          &desc,batchSize,nnXLen,nnYLen,useFP16,useNHWC,inputThisLoop,maskThisLoop,outputThisLoop
        );

        if(supported) {
          numTestsRun += 1;
          string subLabel = label + Global::strprintf(" useNHWC %d useFP16 %d", useNHWC, useFP16);
          if(useNHWC)
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,nnYLen,nnXLen,desc.preBN.numChannels,useFP16);
          else
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,desc.preBN.numChannels,nnYLen,nnXLen,useFP16);
        }
      }
    }
  };

  {
    string label("Basic residual block");

    int batchSize = 2;
    int trunkChannels = 1;
    int midChannels = 2;
    int nnYLen = 3;
    int nnXLen = 4;

    //NCHW
    vector<float> input({
      1,0,0,0,
      0,2,2,0,
      0,0,0,1,

      0,0,0,0,
      0,3,-5,0,
      1,1,1,1,
    });

    //Also, mask out some values
    vector<float> mask({
      1,1,0,1,
      1,1,1,1,
      1,1,0,1,

      1,1,1,1,
      1,1,1,0,
      1,1,1,1,
    });

    ResidualBlockDesc desc;

    //Doubles all values
    desc.preBN.name = "preBN";
    desc.preBN.numChannels = trunkChannels;
    desc.preBN.epsilon = 0.1f;
    desc.preBN.hasScale = true;
    desc.preBN.hasBias = true;
    desc.preBN.mean = vector<float>({0});
    desc.preBN.variance = vector<float>({0.9f});
    desc.preBN.scale = vector<float>({2});
    desc.preBN.bias = vector<float>({0});

    //ReLU gets applied, smooshing negatives
    //2,0,0,3,
    //0,4,4,0,
    //0,0,0,2,

    //0,0,0,0,
    //0,6,0,0,
    //2,2,2,2,

    //Split into two channels, shifting up and shifting down.
    desc.regularConv.name = "regularConv";
    desc.regularConv.convYSize = 3;
    desc.regularConv.convXSize = 3;
    desc.regularConv.inChannels = trunkChannels;
    desc.regularConv.outChannels = midChannels;
    desc.regularConv.dilationY = 1;
    desc.regularConv.dilationX = 1;
    desc.regularConv.weights = vector<float>({
        0,1,0,
        0,0,0,
        0,0,0,

        0,0,0,
        0,0,0,
        0,1,0,
    });
    //0,0,0,0,
    //2,0,0,3,
    //0,4,0,0,

    //0,4,0,0,
    //0,0,0,2,
    //0,0,0,0,

    //0,0,0,0,
    //0,0,0,0,
    //0,6,0,0,

    //0,6,0,0,
    //2,2,2,0,
    //0,0,0,0,

    //Subtract 3 from all values in the 0th channel
    desc.midBN.name = "midBN";
    desc.midBN.numChannels = midChannels;
    desc.midBN.epsilon = 0.1f;
    desc.midBN.hasScale = false;
    desc.midBN.hasBias = false;
    desc.midBN.mean = vector<float>({3,0});
    desc.midBN.variance = vector<float>({0.9f,0.9f});
    desc.midBN.scale = vector<float>({1,1});
    desc.midBN.bias = vector<float>({0,0});

    //ReLU gets applied, smooshing negatives
    //0,0,0,0,
    //0,0,0,0,
    //0,1,0,0,

    //0,4,0,0,
    //0,0,0,2,
    //0,0,0,0,

    //0,0,0,0,
    //0,0,0,0,
    //0,3,0,0,

    //0,6,0,0,
    //2,2,2,0,
    //0,0,0,0,


    //Sum pointwise
    desc.finalConv.name = "finalConv";
    desc.finalConv.convYSize = 1;
    desc.finalConv.convXSize = 1;
    desc.finalConv.inChannels = midChannels;
    desc.finalConv.outChannels = trunkChannels;
    desc.finalConv.dilationY = 1;
    desc.finalConv.dilationX = 1;
    desc.finalConv.weights = vector<float>({
        1,1
    });

    //0,4,0,0,
    //0,0,0,2,
    //0,1,0,0,

    //0,6,0,0,
    //2,2,2,0,
    //0,3,0,0,

    //Then add to the original which was:

    //1,0,0,0,
    //0,2,2,0,
    //0,0,0,1,

    //0,0,0,0,
    //0,3,-5,0,
    //1,1,1,1,

    //Result:

    //1,4,0,0,
    //0,2,2,2,
    //0,1,0,1,

    //0,6,0,0,
    //2,5,-3,0,
    //1,4,1,1,


    //NCHW
    vector<float> expected({
        1, 4, 0, 0,
        0, 2, 2, 2,
        0, 1, 0, 1,

        0, 6, 0, 0,
        2, 5, -3, 0,
        1, 4, 1, 1,
    });

    testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,mask,expected);
  }

}

static void testGlobalPoolingResidualBlock(int64_t& numTestsRun) {

  auto testConfigurations = [&](
    const string& label,
    int batchSize, int nnXLen, int nnYLen,
    const GlobalPoolingResidualBlockDesc& desc, const vector<float>& input, const vector<float>& mask, const vector<float>& expected
  ) {
    for(int useNHWC = 0; useNHWC <= 1; useNHWC++) {
      for(int useFP16 = 0; useFP16 <= 1; useFP16++) {
        vector<float> inputThisLoop = useNHWC ? NCHWtoNHWC(input,batchSize,desc.preBN.numChannels,nnYLen,nnXLen) : input;
        vector<float> maskThisLoop = mask;
        vector<float> expectedThisLoop = useNHWC ? NCHWtoNHWC(expected,batchSize,desc.preBN.numChannels,nnYLen,nnXLen) : expected;

        vector<float> outputThisLoop;
        bool supported = NeuralNet::testEvaluateGlobalPoolingResidualBlock(
          &desc,batchSize,nnXLen,nnYLen,useFP16,useNHWC,inputThisLoop,maskThisLoop,outputThisLoop
        );

        if(supported) {
          numTestsRun += 1;
          string subLabel = label + Global::strprintf(" useNHWC %d useFP16 %d", useNHWC, useFP16);
          if(useNHWC)
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,nnYLen,nnXLen,desc.preBN.numChannels,useFP16);
          else
            CHECK_APPROX_EQUAL(subLabel,outputThisLoop,expectedThisLoop,batchSize,desc.preBN.numChannels,nnYLen,nnXLen,useFP16);
        }
      }
    }
  };

  {
    string label("Global pooling residual block");

    int batchSize = 2;
    int trunkChannels = 1;
    int regularChannels = 1;
    int gpoolChannels = 2;
    int nnYLen = 3;
    int nnXLen = 4;

    //NCHW
    vector<float> input({
      1,2,0,0,
      0,3,4,0,
      0,0,5,0,

      0,0,0,0,
      0,5,-3,0,
      0,-1,1,1,
    });

    vector<float> mask({
      1,1,1,0,
      1,1,1,0,
      1,1,1,0,

      0,0,0,0,
      0,1,1,1,
      0,1,1,1,
    });

    GlobalPoolingResidualBlockDesc desc;

    //Identity map
    desc.preBN.name = "preBN";
    desc.preBN.numChannels = trunkChannels;
    desc.preBN.epsilon = 0.1f;
    desc.preBN.hasScale = true;
    desc.preBN.hasBias = true;
    desc.preBN.mean = vector<float>({0});
    desc.preBN.variance = vector<float>({0.9f});
    desc.preBN.scale = vector<float>({1});
    desc.preBN.bias = vector<float>({0});

    //ReLU gets applied, smooshing negatives
    //1,2,0,0,
    //0,3,4,0,
    //0,0,5,0,

    //0,0,0,0,
    //0,5,0,0,
    //0,0,1,1,

    //Double the value
    desc.regularConv.name = "regularConv";
    desc.regularConv.convYSize = 1;
    desc.regularConv.convXSize = 1;
    desc.regularConv.inChannels = trunkChannels;
    desc.regularConv.outChannels = regularChannels;
    desc.regularConv.dilationY = 1;
    desc.regularConv.dilationX = 1;
    desc.regularConv.weights = vector<float>({
        2
    });
    //2,4,0,0,
    //0,6,8,0,
    //0,0,10,0,

    //0,0,0,0,
    //0,10,0,0,
    //0,0,2,2,

    //For gpooling, split into two channels, shifting left and right
    desc.gpoolConv.name = "gpoolConv";
    desc.gpoolConv.convYSize = 3;
    desc.gpoolConv.convXSize = 3;
    desc.gpoolConv.inChannels = trunkChannels;
    desc.gpoolConv.outChannels = gpoolChannels;
    desc.gpoolConv.dilationY = 1;
    desc.gpoolConv.dilationX = 1;
    desc.gpoolConv.weights = vector<float>({
        0,0,0,
        0,0,1,
        0,0,0,

        0,0,0,
        1,0,0,
        0,0,0,
    });
    //2,0,0,0,
    //3,4,0,0,
    //0,5,0,0,

    //0,1,2,0,
    //0,0,3,0,
    //0,0,0,0,

    //0,0,0,0,
    //0,0,0,0,
    //0,1,1,0,

    //0,0,0,0,
    //0,0,5,0,
    //0,0,0,1,

    //Subtract 2 from all values in the 1th channel
    desc.gpoolBN.name = "gpoolBN";
    desc.gpoolBN.numChannels = gpoolChannels;
    desc.gpoolBN.epsilon = 0.1f;
    desc.gpoolBN.hasScale = false;
    desc.gpoolBN.hasBias = false;
    desc.gpoolBN.mean = vector<float>({0,0});
    desc.gpoolBN.variance = vector<float>({0.9f,0.9f});
    desc.gpoolBN.scale = vector<float>({1,1});
    desc.gpoolBN.bias = vector<float>({0,-2});

    //And apply RELU

    //2,0,0,0,
    //3,4,0,0,
    //0,5,0,0,

    //0,0,0,0,
    //0,0,1,0,
    //0,0,0,0,

    //0,0,0,0,
    //0,0,0,0,
    //0,1,1,0,

    //0,0,0,0,
    //0,0,3,0,
    //0,0,0,0,

    //Pooling - mean, mean * (sqrt(masksum) - 14) * 0.1, max

    //14.0/9.0, 14.0/9.0*(-11)*0.1, 5
    //1.0/9.0, 1.0/9.0*(-11)*0.1, 1

    //2.0/6.0, 2.0/6.0*(sqrt(6)-14)*0.1, 1
    //3.0/6.0, 3.0/6.0*(sqrt(6)-14)*0.1, 3

    //Recombine values
    desc.gpoolToBiasMul.inChannels = 6;
    desc.gpoolToBiasMul.outChannels = regularChannels;
    desc.gpoolToBiasMul.weights = vector<float>({36,36, 18,18, 1,1});

    //56 + 28*(-11)*0.1 + 5 +
    //4 + 2*(-11)*0.1 + 1

    //12 + 6*(sqrt(6)-14)*0.1 + 1 +
    //18 + 9*(sqrt(6)-14)*0.1 + 3

    //Identity map
    desc.midBN.name = "midBN";
    desc.midBN.numChannels = regularChannels;
    desc.midBN.epsilon = 0.1f;
    desc.midBN.hasScale = false;
    desc.midBN.hasBias = false;
    desc.midBN.mean = vector<float>({0});
    desc.midBN.variance = vector<float>({0.9f});
    desc.midBN.scale = vector<float>({1});
    desc.midBN.bias = vector<float>({0});

    //Relu gets applied, should hit nothing in this case

    //Identity map
    desc.finalConv.name = "finalConv";
    desc.finalConv.convYSize = 1;
    desc.finalConv.convXSize = 1;
    desc.finalConv.inChannels = regularChannels;
    desc.finalConv.outChannels = trunkChannels;
    desc.finalConv.dilationY = 1;
    desc.finalConv.dilationX = 1;
    desc.finalConv.weights = vector<float>({
        1
    });

    vector<float> expected({
      3,6,0,0,
      0,9,12,0,
      0,0,15,0,

      0,0,0,0,
      0,15,-3,0,
      0,-1,3,3,
    });

    for(int i = 0; i<12; i++) {
      expected[i] += (float)(
        56 + 28*(-11)*0.1 + 5 +
        4 + 2*(-11)*0.1 + 1
      );
      expected[i] *= mask[i];
    }
    for(int i = 12; i<24; i++) {
      expected[i] += (float)(
        12 + 6*(sqrt(6)-14)*0.1 + 1 +
        18 + 9*(sqrt(6)-14)*0.1 + 3
      );
      expected[i] *= mask[i];
    }

    testConfigurations(label,batchSize,nnXLen,nnYLen,desc,input,mask,expected);
  }

}


void Tests::runNNLayerTests() {
  NeuralNet::globalInitialize();
  int64_t numTestsRun = 0;
  testConvLayer(numTestsRun);
  runMLXWinogradTests();
  runMLXWinotunerTests();
  testBatchNormLayer(numTestsRun);
  testResidualBlock(numTestsRun);
  testGlobalPoolingResidualBlock(numTestsRun);
  NeuralNet::globalCleanup();
  cout << "Tested " << numTestsRun << " configurations" << endl;
  cout << "Done" << endl;
}


#ifdef USE_MLX_BACKEND
#include "../neuralnet/mlxwinograd.h"
#include <array>
#include <random>
// SP3 Task 2: BatchNormLayer is internal to mlxbackend.cpp; its fp16 test
// is defined there and forward-declared here.
void runMLXBatchNormFP16Test_SP3();
void runMLXConvLayerFP16WinogradTest_SP3();
void Tests::runMLXWinogradTests() {
  cout << "Running MLX Winograd F(2,3) tests" << endl;
  // Naive direct 3x3 "same" conv NHWC, OIHW weights, as independent oracle.
  auto direct = [](const vector<float>& in,int N,int H,int W,int Cin,
                    const vector<float>& w,int Cout){
    vector<float> out((size_t)N*H*W*Cout,0.f);
    for(int n=0;n<N;n++)for(int oy=0;oy<H;oy++)for(int ox=0;ox<W;ox++)
    for(int oc=0;oc<Cout;oc++){ float s=0.f;
      for(int ic=0;ic<Cin;ic++)for(int a=0;a<3;a++)for(int b=0;b<3;b++){
        int iy=oy+a-1,ix=ox+b-1;
        if(iy>=0&&iy<H&&ix>=0&&ix<W)
          s+=in[(((size_t)n*H+iy)*W+ix)*Cin+ic]
             *w[(((size_t)oc*Cin+ic)*3+a)*3+b];
      }
      out[(((size_t)n*H+oy)*W+ox)*Cout+oc]=s;
    }
    return out;
  };
  std::mt19937 rng(12345);
  std::uniform_real_distribution<float> dist(-1.f,1.f);
  for(auto dims : vector<array<int,5>>{{1,5,5,3,4},{2,19,19,8,16},{1,7,13,4,4}}){
    int N=dims[0],H=dims[1],W=dims[2],Cin=dims[3],Cout=dims[4];
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=dist(rng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=dist(rng);
    auto ref = direct(in,N,H,W,Cin,w,Cout);
    auto got = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    double maxErr=0.0;
    for(size_t i=0;i<ref.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(ref[i]-got[i]));
    cout<<"  dims "<<N<<"x"<<H<<"x"<<W<<"x"<<Cin<<"->"<<Cout
        <<" maxErr="<<maxErr<<endl;
    testAssert(maxErr < 1e-4);
  }
  cout << "MLX Winograd F(2,3) CPU reference OK" << endl;

  // GPU Winograd metal_kernel validated against the Task 1 CPU oracle.
  {
    namespace mxc = mlx::core;
    int N=2,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 grng(777);
    std::uniform_real_distribution<float> gdist(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
    auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    mxc::array inArr(in.data(),{N,H,W,Cin},mxc::float32);
    auto Uw = MLXWinograd::makeWinogradWeights(w,Cout,Cin);
    MLXWinograd::InputTransform inCfg;
    MLXWinograd::OutputUntransform outCfg;
    mxc::array o = MLXWinograd::winogradConv2d(inArr,Uw,Cout,inCfg,outCfg);
    mxc::eval(o);
    const float* od = o.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<refv.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
    cout<<"  MLX-metal winograd maxErr="<<maxErr<<endl;
    testAssert(maxErr < 2e-3);
  }

  // FP16 Winograd: input/weights/output all fp16, compared against fp32 CPU oracle.
  // Tolerance ~5e-2 covers (a) fp16 input quantization, (b) fp16 weight quantization,
  // (c) fp16 transform/store rounding. The matmul itself accumulates in fp32 (MLX
  // steel gemm default), so the dominant error is the storage round-trip.
  {
    namespace mxc = mlx::core;
    int N=2,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 grng(778);
    std::uniform_real_distribution<float> gdist(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
    auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    mxc::array inArrF32(in.data(),{N,H,W,Cin},mxc::float32);
    mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
    auto Uw = MLXWinograd::makeWinogradWeights(w,Cout,Cin,/*useFP16=*/true);
    MLXWinograd::InputTransform inCfg;
    MLXWinograd::OutputUntransform outCfg;
    mxc::array o = MLXWinograd::winogradConv2d(inArr,Uw,Cout,inCfg,outCfg,/*useFP16=*/true);
    mxc::eval(o);
    testAssert(o.dtype() == mxc::float16);
    mxc::array oF32 = mxc::astype(o, mxc::float32);
    mxc::eval(oF32);
    const float* od = oF32.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<refv.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
    cout<<"  MLX-metal winograd FP16 maxErr="<<maxErr<<endl;
    testAssert(maxErr < 5e-2);
  }

  runMLXBatchNormFP16Test_SP3();
  runMLXConvLayerFP16WinogradTest_SP3();
}
#else
void Tests::runMLXWinogradTests() {}
#endif

#ifdef USE_MLX_BACKEND
#include "../neuralnet/mlxwinotuner.h"
#include <chrono>
#include <cstdio>
#include <random>

void Tests::runMLXWinotunerTests() {
  cout << "Running MLX Winograd tuner tests" << endl;

  // ---- File round-trip ----
  {
    MLXWinogradTuneParams written;
    written.inputTransform.tg0 = 64;
    written.inputTransform.tg1 = 2;
    written.outputUntransform.tg0 = 16;
    written.outputUntransform.tg1 = 4;
    testAssert(written.isValid());

    std::string tmp = "/tmp/katago_mlx_winotuner_roundtrip.txt";
    MLXWinogradTuneParams::save(tmp, written);
    MLXWinogradTuneParams readBack = MLXWinogradTuneParams::load(tmp);

    testAssert(readBack.inputTransform.tg0 == written.inputTransform.tg0);
    testAssert(readBack.inputTransform.tg1 == written.inputTransform.tg1);
    testAssert(readBack.outputUntransform.tg0 == written.outputUntransform.tg0);
    testAssert(readBack.outputUntransform.tg1 == written.outputUntransform.tg1);
  }

  // SP3 Task 4: dtype-aware cache filenames must coexist in the same directory
  // without collision. Verify defaultFileName gains a _fp16/_fp32 suffix.
  {
    std::string nameF32 = MLXWinogradTuner::defaultFileName(
      "AppleSilicon", 19, 19, 384, 13, /*useFP16=*/false);
    std::string nameF16 = MLXWinogradTuner::defaultFileName(
      "AppleSilicon", 19, 19, 384, 13, /*useFP16=*/true);
    testAssert(nameF32 != nameF16);
    testAssert(nameF32.find("_fp32") != std::string::npos);
    testAssert(nameF16.find("_fp16") != std::string::npos);
    testAssert(nameF32.size() >= 4 && nameF32.substr(nameF32.size()-4) == ".txt");
    testAssert(nameF16.size() >= 4 && nameF16.substr(nameF16.size()-4) == ".txt");
    cout << "  defaultFileName dtype suffix OK: "
         << nameF32 << " vs " << nameF16 << endl;
  }

  // ---- Corrupt-version rejection ----
  {
    std::string tmp = "/tmp/katago_mlx_winotuner_badversion.txt";
    {
      std::ofstream f(tmp);
      f << "VERSION=999\n#inputTransform\ntg0=32 tg1=1\n#outputUntransform\ntg0=32 tg1=1\n";
    }
    bool threw = false;
    try { (void)MLXWinogradTuneParams::load(tmp); }
    catch(const IOError&) { threw = true; }
    testAssert(threw);
  }

  // ---- isValid edges ----
  {
    MLXWinogradTuneParams a; testAssert(a.isValid());          // defaults
    MLXWinogradTuneParams b; b.inputTransform.tg0 = 0;  testAssert(!b.isValid());
    MLXWinogradTuneParams c; c.outputUntransform.tg1 = -1; testAssert(!c.isValid());
    MLXWinogradTuneParams d; d.inputTransform.tg0 = 1024; d.inputTransform.tg1 = 2;
    testAssert(!d.isValid()); // 2048 > 1024
    MLXWinogradTuneParams e; e.inputTransform.tg0 = 1024; e.inputTransform.tg1 = 1;
    testAssert(e.isValid());  // exactly at boundary: 1024 == 1024
  }

  // ---- Measurement primitives return finite positive times ----
  // We can't call the static helpers from the test, so we use the public
  // surface that will be wired in Task 4: loadOrAutoTune with reTune=true
  // would run the search; for Task-3 scope we just verify the public
  // schema struct works with valid configs. The measurement primitive itself
  // is exercised by the search-works test added in Task 4.

  // ---- Search-works (per stage): bad seed; assert (a) beats bad by >=25% (tWinner <= 0.8 * tBad),
  //      (b) within 5% of optimum (tWinner <= 1.05 * tOpt). 0.8 threshold matches the amended
  //      spec §7.1(a) — Apple Silicon's SIMD coalescing limits the practical dynamic range to ~1.5x.
  // Gated behind KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 to keep runnnlayertests fast
  // (full search runs ~30-60s on first call).
  if(std::getenv("KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST") != nullptr) {
    cout << "Running MLX Winograd tuner search-works test" << endl;
    namespace mx = mlx::core;

    MLXWinogradTuner::ModelInfoForTuning mi;
    mi.trunkNumChannels = 256;
    mi.midNumChannels = 256;
    mi.maxConvChannels3x3 = 256;
    mi.modelVersion = 15;

    int N = 8, H = 19, W = 19;

    std::string tmpFile = "/tmp/katago_mlx_winotuner_searchtest.txt";
    std::remove(tmpFile.c_str());

    // Pass the bad seed explicitly via seedOverride so the search's prepended
    // anchor is genuinely bad — this lets assertion (a) catch the broken
    // "returns anchor unchanged" failure mode.
    MLXWinogradTuneParams badSeed;
    badSeed.inputTransform.tg0 = 1; badSeed.inputTransform.tg1 = 1;
    badSeed.outputUntransform.tg0 = 1; badSeed.outputUntransform.tg1 = 1;
    MLXWinogradTuneParams tuned = MLXWinogradTuner::loadOrAutoTune(
        tmpFile, /*homeDataDirOverride=*/"", /*gpuName=*/"UnitTestGpu",
        /*nnXLen=*/W, /*nnYLen=*/H, /*batchSize=*/N,
        mi, /*logger=*/nullptr, /*full=*/false, /*reTune=*/true,
        /*useFP16=*/false,
        /*seedOverride=*/&badSeed);

    // Re-time the three configs via winogradConv2d on synthetic data, OUTSIDE
    // the tuner -- so the assertions don't depend on the tuner's measurement
    // plumbing being correct.
    std::vector<float> inV((size_t)N * H * W * mi.trunkNumChannels);
    std::mt19937 rng(0x12345);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    for(auto& x : inV) x = dist(rng);
    mx::array input(inV.data(), {N, H, W, mi.trunkNumChannels}, mx::float32);
    mx::eval(input);

    std::vector<float> wOIHW((size_t)mi.trunkNumChannels * mi.trunkNumChannels * 9);
    for(auto& x : wOIHW) x = dist(rng);
    mx::array Uw = MLXWinograd::makeWinogradWeights(wOIHW, mi.trunkNumChannels, mi.trunkNumChannels, /*useFP16=*/false);
    mx::eval(Uw);

    auto timeCfg = [&](const MLXWinograd::InputTransform& ic,
                       const MLXWinograd::OutputUntransform& oc) -> double {
      const int reps = 10;
      double total = 0;
      for(int i = 0; i < reps; i++) {
        auto t0 = std::chrono::steady_clock::now();
        mx::array out = MLXWinograd::winogradConv2d(input, Uw, mi.trunkNumChannels, ic, oc, /*useFP16=*/false);
        mx::eval(out);
        auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if(i > 0) total += ms; // discard warmup
      }
      return total / (reps - 1);
    };

    MLXWinograd::InputTransform   badIn{1, 1};
    MLXWinograd::OutputUntransform badOut{1, 1};
    MLXWinograd::InputTransform   optIn{32, 1};
    MLXWinograd::OutputUntransform optOut{32, 1};

    double tWinner = timeCfg(tuned.inputTransform, tuned.outputUntransform);
    double tBad    = timeCfg(badIn, badOut);
    double tOpt    = timeCfg(optIn, optOut);

    cout << Global::strprintf(
        "  winner=(%d,%d)/(%d,%d) %.3fms ; bad=(1,1)/(1,1) %.3fms ; opt=(32,1)/(32,1) %.3fms",
        tuned.inputTransform.tg0, tuned.inputTransform.tg1,
        tuned.outputUntransform.tg0, tuned.outputUntransform.tg1,
        tWinner, tBad, tOpt) << endl;

    // (a) Winner must beat bad seed by at least 25%.
    testAssert(tWinner <= 0.8 * tBad);
    // (b) Winner must be within 5% of known optimum.
    testAssert(tWinner <= 1.05 * tOpt);

    cout << "MLX Winograd tuner search-works test passed" << endl;
  } else {
    cout << "Skipping MLX Winograd tuner search-works test (set KATAGO_MLX_WINOTUNER_RUN_SEARCH_TEST=1 to enable)" << endl;
  }

  cout << "MLX Winograd tuner tests passed" << endl;
}
#else
void Tests::runMLXWinotunerTests() {
  cout << "MLX backend not built; skipping MLX Winograd tuner tests" << endl;
}
#endif

void Tests::runNNSymmetryTests() {
  auto testConfigurations = [&](
    const string& label,
    int batchSize, int numChannels, int nnXLen, int nnYLen,
    const vector<float>& input
  ) {
    for(int useNHWC = 0; useNHWC <= 1; useNHWC++) {
      for(int symmetry = 0; symmetry < 8; symmetry++) {
        vector<float> inputThisLoop = useNHWC ? NCHWtoNHWC(input,batchSize,numChannels,nnYLen,nnXLen) : input;
        vector<float> outputThisLoop(inputThisLoop.size());
        SymmetryHelpers::copyInputsWithSymmetry(
          inputThisLoop.data(),outputThisLoop.data(),batchSize,nnXLen,nnYLen,numChannels,useNHWC,symmetry
        );
        cout << label << " useNHWC " << useNHWC << " " << symmetry << endl;
        for(int i = 0; i<outputThisLoop.size(); i++)
          cout << outputThisLoop[i] << " ";
        cout << endl;
      }
    }
    for(int symmetry = 0; symmetry < 8; symmetry++) {
      vector<float> inputThisLoop = input;
      vector<float> outputThisLoop(inputThisLoop.size());
      SymmetryHelpers::copyOutputsWithSymmetry(
        inputThisLoop.data(),outputThisLoop.data(),batchSize*numChannels,nnXLen,nnYLen,symmetry
      );
      cout << label << " OUTPUT " << endl;
      for(int i = 0; i<outputThisLoop.size(); i++)
        cout << outputThisLoop[i] << " ";
      cout << endl;
    }
  };

  {
    {
      //NCHW
      vector<float> input({
        0,1,2,
        3,4,5,
        6,7,8,

        3,0,4,
        0,5,0,
        0,6,0,

        1,0,0,
        1,1,1,
        1,0,1,
      });
      testConfigurations("Symmetry 3-1-3-3",3,1,3,3,input);
      testConfigurations("Symmetry 1-3-3-3",1,3,3,3,input);
    }

    {
      //NCHW
      vector<float> input({
        0,1,2,3,
        4,5,6,7,
        8,9,10,11,

        12,13,14,15,
        16,17,18,19,
        20,21,22,23
      });

      testConfigurations("Symmetry 2-1-3-4",2,1,3,4,input);
      testConfigurations("Symmetry 2-3-2-2",2,3,2,2,input);
    }

  }

}

# PROTOTYPE results (wayfinder #36), 2026-10-19

Machine: Apple M3 Max (`Mac15,9`, Neural Engine architecture `h15c`), macOS 27.0.1 (26A434), Xcode 27.1 (27A9275),
`coreai-core` 1.0.0b3, `coremltools` 9.0. Network: `kata1-b18c384nbt-s9996604416-d4316597426` (model version 14,
lead multiplier 20, no scale8). Core ML packages: FP16 compute, FP32 I/O, mask on, batch 1. Numerics only; no timing
here is a benchmark.

Positions: 44 at 19x19 (empty, `humanslbigdiff.sgf` every 10 moves, 9 random-play, 24 self-play) and 53 at 37x37
(empty, 20 random-play, 32 self-play). "Self-play" means games the FP32 network played with its policy sampled.

## Facts outside the tables

- **Translation.** 16 MIL op types (`const add mul real_div conv exp squeeze reduce_sum sub cast matmul reshape sqrt
  concat reduce_max linear`) cover b18c384nbt. The translator runs in under 1 s and writes a 53 MB `.aimodel`; it
  contains no `log` and no `tanh`.
- **Determinism.** A rerun on the ANE reproduced every output bit for bit, for both frameworks.
- **App batch config.** Core ML's dynamic batch 1..3 model (the iOS app's) gives the same bits at batch 1 as the
  batch-1 model.
- **Residency, Core AI, preferred `.neuralEngine`**, same at 19x19 and 37x37: 1307 of the 1308 MPSGraph-delegate ops
  carry an `ANE` residency at the MPSGraph level. The remaining one is the top-level function op, with only an
  mps-level `GPU` tag (the graph-level entry). The 50 `odix` records are delegate dispatch with no kernel residency.
- **Residency, Core ML, `CPU_AND_NE`** (`MLComputePlan`): all 1372 non-const ops on the Neural Engine.
- **Loads** (not gating): Core AI's first ANE specialization took 4.4 s at 19x19 and 14.5 s at 37x37, and a cached
  load 0.03 s. Core ML's ANE load, including the `coremltools` compile, took 4.2 to 6.6 s.

## Tables (`run.sh <workDir> compare`)

### 19x19: 44 positions
FP32 Core AI (cpu) vs FP32 Core ML (cpu), the reference: max |diff| per head policy_p2_conv 4.8e-05, policy_pass 9.5e-06, value_v3_bias 1.3e-05, value_sv3_bias 1.5e-05, value_ownership_conv 6.4e-06

App batch config (Core ML, max batch 3, ANE) vs max batch 1, at batch 1: max |diff| policy_p2_conv 0, policy_pass 0, value_v3_bias 0, value_sv3_bias 0, value_ownership_conv 0

#### Raw outputs, element by element (|diff| percentiles p50 / p99 / p99.9 / max; rms)

| head | unit | Core AI vs Core ML | identical | Core ML vs FP32 | Core AI vs FP32 | rms ratio AI/ML [90% CI] |
|---|---|---|---|---|---|---|
| policy_p2_conv | cpu | 0.02 / 0.11 / 0.16 / 0.22; 0.036 | 7% | 0.016 / 0.09 / 0.13 / 0.3; 0.029 | 0.018 / 0.1 / 0.14 / 0.22; 0.033 | 1.13 [0.98, 1.28] |
| policy_p2_conv | ane | 0.0039 / 0.016 / 0.031 / 0.043; 0.0067 | 31% | 0.008 / 0.042 / 0.058 / 0.088; 0.013 | 0.0067 / 0.041 / 0.056 / 0.073; 0.012 | 0.88 [0.83, 0.93] |
| policy_pass | cpu | 0.016 / 0.079 / 0.082 / 0.082; 0.028 | 6% | 0.014 / 0.071 / 0.073 / 0.073; 0.026 | 0.014 / 0.09 / 0.093 / 0.094; 0.031 | 1.19 [0.99, 1.43] |
| policy_pass | ane | 0.00098 / 0.013 / 0.019 / 0.02; 0.0045 | 50% | 0.0055 / 0.026 / 0.035 / 0.036; 0.0096 | 0.0051 / 0.022 / 0.035 / 0.036; 0.0087 | 0.91 [0.82, 0.99] |
| value_v3_bias | cpu | 0.011 / 0.061 / 0.062 / 0.062; 0.021 | 10% | 0.012 / 0.074 / 0.096 / 0.099; 0.024 | 0.017 / 0.098 / 0.15 / 0.16; 0.031 | 1.30 [1.10, 1.45] |
| value_v3_bias | ane | 0.002 / 0.012 / 0.013 / 0.014; 0.0041 | 33% | 0.0047 / 0.017 / 0.03 / 0.031; 0.0069 | 0.0035 / 0.016 / 0.019 / 0.02; 0.0056 | 0.82 [0.74, 0.91] |
| value_sv3_bias | cpu | 0.0049 / 0.097 / 0.21 / 0.25; 0.025 | 2% | 0.0055 / 0.15 / 0.22 / 0.23; 0.03 | 0.0045 / 0.21 / 0.26 / 0.26; 0.04 | 1.33 [1.06, 1.69] |
| value_sv3_bias | ane | 0.00069 / 0.03 / 0.049 / 0.055; 0.0059 | 23% | 0.0018 / 0.042 / 0.099 / 0.1; 0.011 | 0.0013 / 0.042 / 0.085 / 0.094; 0.0097 | 0.89 [0.66, 1.15] |
| value_ownership_conv | cpu | 0.0029 / 0.025 / 0.038 / 0.066; 0.0069 | 3% | 0.0021 / 0.022 / 0.037 / 0.052; 0.0059 | 0.0027 / 0.021 / 0.03 / 0.047; 0.0059 | 0.99 [0.95, 1.04] |
| value_ownership_conv | ane | 0.00031 / 0.0039 / 0.0049 / 0.012; 0.0009 | 26% | 0.00079 / 0.0094 / 0.013 / 0.018; 0.0025 | 0.00076 / 0.0089 / 0.012 / 0.016; 0.0024 | 0.95 [0.93, 0.97] |

#### testgpuerror-style, per position vs FP32 (p50 / p90 / max over positions)

| stat | unit | Core ML | Core AI | max ratio AI/ML | mean ratio AI/ML [90% CI] |
|---|---|---|---|---|---|
| winrate % | cpu | 0.111 / 0.467 / 1.02 | 0.192 / 0.649 / 1.03 | 1.00 | 1.40 [1.09, 1.79] |
| lead pts | cpu | 0.0382 / 0.125 / 0.289 | 0.0477 / 0.114 / 0.187 | 0.64 | 0.94 [0.77, 1.16] |
| top policy % | cpu | 0.262 / 0.941 / 1.77 | 0.321 / 0.677 / 1.25 | 0.71 | 0.94 [0.78, 1.17] |
| policy KL | cpu | 0.000217 / 0.000617 / 0.00202 | 0.000143 / 0.000393 / 0.00087 | 0.43 | 0.65 [0.54, 0.80] |
| winrate % | ane | 0.0321 / 0.166 / 0.44 | 0.0314 / 0.13 / 0.258 | 0.59 | 0.70 [0.57, 0.86] |
| lead pts | ane | 0.0291 / 0.0827 / 0.118 | 0.0157 / 0.0516 / 0.0988 | 0.83 | 0.69 [0.60, 0.78] |
| top policy % | ane | 0.056 / 0.264 / 0.51 | 0.0573 / 0.32 / 0.456 | 0.90 | 1.04 [0.90, 1.20] |
| policy KL | ane | 1.16e-05 / 3.73e-05 / 6.82e-05 | 9.12e-06 / 3.55e-05 / 5.18e-05 | 0.76 | 0.87 [0.73, 1.04] |

FP16-graph reduce_sum peak (global pooling sums, FP32 run): 4380 at value_v1_pool_316_sum (headroom 15.0x)

FP32 activation peak over 311 conv, BN-bias, residual and sum results: 4380 at value_v1_pool_316_sum (6.69% of the FP16 max, headroom 15x); residual stream 70.84; worst position selfplay5_m200

### 37x37: 53 positions
FP32 Core AI (cpu) vs FP32 Core ML (cpu), the reference: max |diff| per head policy_p2_conv 3e-05, policy_pass 1.4e-05, value_v3_bias 4.9e-05, value_sv3_bias 5.2e-05, value_ownership_conv 6.4e-06

#### Raw outputs, element by element (|diff| percentiles p50 / p99 / p99.9 / max; rms)

| head | unit | Core AI vs Core ML | identical | Core ML vs FP32 | Core AI vs FP32 | rms ratio AI/ML [90% CI] |
|---|---|---|---|---|---|---|
| policy_p2_conv | cpu | 0.02 / 0.13 / 0.2 / 0.3; 0.037 | 6% | 0.017 / 0.088 / 0.13 / 0.24; 0.031 | 0.019 / 0.12 / 0.18 / 0.23; 0.036 | 1.19 [1.01, 1.41] |
| policy_p2_conv | ane | 0.0039 / 0.023 / 0.039 / 0.047; 0.0068 | 34% | 0.0069 / 0.041 / 0.052 / 0.069; 0.013 | 0.0065 / 0.035 / 0.047 / 0.07; 0.012 | 0.91 [0.82, 1.00] |
| policy_pass | cpu | 0.017 / 0.097 / 0.16 / 0.17; 0.035 | 4% | 0.016 / 0.082 / 0.086 / 0.087; 0.03 | 0.016 / 0.1 / 0.15 / 0.15; 0.033 | 1.10 [0.88, 1.37] |
| policy_pass | ane | 0.002 / 0.015 / 0.037 / 0.039; 0.0057 | 35% | 0.0035 / 0.028 / 0.035 / 0.036; 0.0089 | 0.0035 / 0.026 / 0.027 / 0.027; 0.0075 | 0.85 [0.70, 1.00] |
| value_v3_bias | cpu | 0.031 / 0.24 / 0.28 / 0.28; 0.068 | 3% | 0.036 / 0.16 / 0.22 / 0.23; 0.065 | 0.033 / 0.25 / 0.33 / 0.34; 0.076 | 1.18 [0.94, 1.43] |
| value_v3_bias | ane | 0.0068 / 0.035 / 0.039 / 0.039; 0.011 | 21% | 0.011 / 0.057 / 0.062 / 0.062; 0.02 | 0.009 / 0.05 / 0.052 / 0.052; 0.018 | 0.92 [0.83, 1.02] |
| value_sv3_bias | cpu | 0.02 / 0.39 / 0.83 / 0.96; 0.1 | 3% | 0.017 / 0.44 / 0.94 / 1; 0.11 | 0.021 / 0.43 / 0.88 / 1; 0.12 | 1.03 [0.90, 1.18] |
| value_sv3_bias | ane | 0.0029 / 0.038 / 0.059 / 0.062; 0.0095 | 18% | 0.0063 / 0.066 / 0.078 / 0.08; 0.018 | 0.0066 / 0.057 / 0.08 / 0.085; 0.016 | 0.91 [0.81, 1.02] |
| value_ownership_conv | cpu | 0.0024 / 0.023 / 0.041 / 0.074; 0.0059 | 3% | 0.0016 / 0.018 / 0.031 / 0.053; 0.0045 | 0.0023 / 0.019 / 0.031 / 0.052; 0.005 | 1.11 [1.06, 1.17] |
| value_ownership_conv | ane | 0.00024 / 0.0029 / 0.0039 / 0.0078; 0.00075 | 23% | 0.00066 / 0.007 / 0.01 / 0.016; 0.0017 | 0.00065 / 0.0069 / 0.01 / 0.016; 0.0017 | 0.98 [0.95, 1.01] |

#### testgpuerror-style, per position vs FP32 (p50 / p90 / max over positions)

| stat | unit | Core ML | Core AI | max ratio AI/ML | mean ratio AI/ML [90% CI] |
|---|---|---|---|---|---|
| winrate % | cpu | 0.399 / 1.73 / 8.09 | 0.496 / 2.89 / 5.21 | 0.64 | 1.16 [0.79, 1.70] |
| lead pts | cpu | 0.174 / 0.403 / 0.638 | 0.135 / 0.486 / 0.731 | 1.15 | 1.01 [0.80, 1.27] |
| top policy % | cpu | 0.296 / 0.971 / 1.36 | 0.305 / 0.64 / 1.25 | 0.92 | 0.90 [0.72, 1.12] |
| policy KL | cpu | 0.000241 / 0.000679 / 0.00113 | 0.000188 / 0.000537 / 0.000833 | 0.74 | 0.80 [0.67, 0.96] |
| winrate % | ane | 0.1 / 0.686 / 0.982 | 0.1 / 0.657 / 1.99 | 2.02 | 1.09 [0.93, 1.30] |
| lead pts | ane | 0.0668 / 0.16 / 0.301 | 0.0569 / 0.167 / 0.252 | 0.84 | 0.96 [0.86, 1.06] |
| top policy % | ane | 0.0656 / 0.221 / 0.348 | 0.0703 / 0.213 / 0.288 | 0.83 | 0.98 [0.82, 1.16] |
| policy KL | ane | 1.57e-05 / 3.72e-05 / 8.28e-05 | 1.36e-05 / 3.63e-05 / 4.85e-05 | 0.59 | 0.87 [0.79, 0.97] |

FP16-graph reduce_sum peak (global pooling sums, FP32 run): 1.614e+04 at value_v1_pool_316_sum (headroom 4.1x)

FP32 activation peak over 311 conv, BN-bias, residual and sum results: 1.614e+04 at value_v1_pool_316_sum (24.64% of the FP16 max, headroom 4x); residual stream 73.14; worst position random3_m1200

## Residency (`run.sh <workDir> residency`)

```
coreai-ane 19x19: MPSGraph_optimized:ANE 1307, MPSGraph_optimized:no kernel residency 1, odix:no kernel residency 50
coreai-ane 37x37: MPSGraph_optimized:ANE 1307, MPSGraph_optimized:no kernel residency 1, odix:no kernel residency 50
coreml-ane 19x19 and 37x37: add 420, cast 8, concat 7, conv 119, exp 118, linear 3, matmul 8, mul 377, real_div 243, reduce_max 6, reduce_sum 14, reshape 7, sqrt 7, squeeze 21, sub 14: all MLNeuralEngineComputeDevice
```

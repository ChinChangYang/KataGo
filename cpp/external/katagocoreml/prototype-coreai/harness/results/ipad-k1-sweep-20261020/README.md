# iPad K=1 and K=2 speed sweep (2026-10-20)

Raw results behind the verdict of
[Go or no-go for the Core AI backend?](https://github.com/ChinChangYang/KataGo/issues/39).

The stage 1 harness was run unchanged, from the app bundle built for
[What are stage 1's numbers on an idle Mac and on the iPad A17 Pro?](https://github.com/ChinChangYang/KataGo/issues/38).
It ran on the iPad A17 Pro (iPad16,1, iOS 27.0.1, Core AI architecture `h16p`):

```bash
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
  chinchangyang.KataGo-iOS.tw.coreaigate -- --mode speed --sweep 1,2 --k 2 --exit
```

Every repetition passed the idle gate and stayed at a nominal thermal state.

- `run.log` is the console.
- `speed-20261020-180346-8960.json` is the app's result file.

The harness's own verdict lines apply the original per-framework spread rule. The gate judges the **paired ratio**
instead: Core AI over CoreML/NE within each repetition. That ratio, computed from the `rep` lines:

| Arm | Paired ratio, reps 1-3 | Median | Spread |
|---|---|---|---|
| K=1 `coreai-encode-b1x1` (fastest) | 0.920 / 0.932 / 0.911 | 92.0% | 2.3% |
| K=1 `coreai-run-b1x1` | 0.888 / 0.901 / 0.893 | 89.3% | 1.5% |
| K=1 `coreai-run-b1` | 0.895 / 0.896 / 0.898 | 89.6% | 0.4% |
| K=2 `coreai-run-b1x2` | 1.011 / 0.996 / 1.012 | 101.1% | 1.6% |

The p50 latency at K=1 is 4.17 ms for CoreML/NE and 4.54 to 4.63 ms for Core AI. At K=2 it is about 9.1 ms for both.

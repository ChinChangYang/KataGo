# QRS-Tune Analysis: Is Quadratic Regression a Good Way to Tune PUCT?

This note evaluates the QRS-Tune optimizer (`cpp/qrstune/QRSOptimizer.cpp`)
on synthetic 1-D PUCT-like landscapes and compares it to two simpler
baselines: Grid + Bradley-Terry MLE, and Random + Bradley-Terry MLE.

The harness is reproducible:

```
katago analyze-qrs
```

Source: `cpp/command/analyzeqrs.cpp`. Seeds: 30 per cell. Baselines use an
11-point grid. Each "trial" is one simulated game (Bernoulli draw from the
true win-rate function `p(x) = sigmoid(intercept - curvature * (x - x*)^2)`).

## Results (regret = `|x_recommended - x_true|`, x in `[-1,+1]`)

| Landscape (peak P) | Trials | QRS regret | Grid+BT regret | Rand+BT regret | QRS CI cov. | QRS convex-fallback |
|---|---:|---:|---:|---:|---:|---:|
| steep (0.82) | 200 | **0.072** | 0.177 | 0.183 | 0.97 | 0% |
| steep (0.82) | 1000 | **0.034** | 0.143 | 0.150 | 1.00 | 0% |
| steep (0.82) | 5000 | **0.016** | 0.110 | 0.093 | 0.90 | 0% |
| medium (0.62) | 200 | **0.158** | 0.290 | 0.310 | 0.90 | 0% |
| medium (0.62) | 1000 | **0.100** | 0.233 | 0.213 | 0.93 | 0% |
| medium (0.62) | 5000 | **0.040** | 0.127 | 0.160 | 0.87 | 0% |
| flat (0.55) | 200 | **0.249** | 0.447 | 0.420 | 0.73 | 17% |
| flat (0.55) | 1000 | **0.138** | 0.313 | 0.260 | 0.87 | 3% |
| flat (0.55) | 5000 | **0.101** | 0.183 | 0.233 | 0.87 | 0% |
| very-flat (0.52) | 200 | **0.274** | 0.570 | 0.480 | 0.50 | 40% |
| very-flat (0.52) | 1000 | **0.219** | 0.417 | 0.377 | 0.77 | 13% |
| very-flat (0.52) | 5000 | **0.174** | 0.310 | 0.280 | 0.90 | 0% |

(See raw output in the commit message; identical numbers reproduce locally.)

## What the numbers say

1. **QRS beats both Bradley-Terry baselines on raw regret in every cell.**
   Sequential adaptation with a parametric quadratic surface is genuinely
   more sample-efficient than handing the same trials to grid+BT or
   random+BT for a fixed-grid choice.

2. **The advantage shrinks to the noise floor in the realistic PUCT
   regime.** On the very-flat landscape (peak win-rate 0.52 — the regime
   where realistic cpuctExploration tweaks actually live), at 5000
   simulated games QRS recommends an `x` whose true win-rate is **0.5174**,
   while Grid+BT achieves **0.5143**. The absolute gain QRS extracts over
   a fixed-grid baseline is **~0.003** in win-rate. To detect a 0.003
   win-rate edge with 95% confidence requires on the order of `1/(0.003)^2
   ~ 100,000` games — orders of magnitude more than any practical PUCT
   tuning run uses. The "winner" of the comparison is not statistically
   resolvable from the binary outcomes.

3. **QRS's reported 95% CI is not calibrated in the regime that matters.**
   Coverage is essentially 95% on the steep landscape, but drops to **50%**
   on very-flat with 200 trials, and only recovers to ~85-90% by 5000
   trials. The delta-method derivation in `QRSModel::computeOptimumSE`
   assumes a well-conditioned quadratic — an assumption that fails
   silently on flat truth, so users acting on these CIs will be
   over-confident.

4. **Convex-fallback fires often on flat truth.** On very-flat at 200
   trials, **40%** of seeds end with a non-concave fitted quadratic, and
   the optimizer falls back to returning the prior centre (0). This means
   "the recommendation is no recommendation"; absent a flag in the output,
   the user cannot tell.

5. **Even at the largest budget tested, QRS regret on flat truth is
   ~0.10-0.17.** Translated to real `cpuctExploration` with the default
   search range `[0.5, 1.5]` (radius 0.5), that is **±0.05 to ±0.085**
   absolute uncertainty in the recommended cpuct value — on a quantity
   whose true effect on win-rate over its entire range is only ~3
   percentage points. The recommendation is essentially within the noise
   floor of the underlying signal.

## Why QRS is not "ideal", structurally

The benchmark above only varies one axis (curvature) of the actual problem.
Several concerns are intrinsic to the approach and not addressed by giving
it more trials:

- **Mis-specified surrogate.** The win-rate-vs-PUCT surface is not a
  quadratic. Real PUCT effects often saturate (a plateau of near-equal
  configs) or have multiple local plateaus driven by interactions with
  exploration depth, time control, network strength, ruleset, and game
  phase. A quadratic must come back down on each side of its peak, so
  it will systematically pull the estimate past any plateau edge.

- **Single point estimate hides conditioning.** PUCT optima drift with
  time control and network. A scalar recommendation (one number) cannot
  expose this.

- **Pruning is circular.** `QRSBuffer::prune` drops samples the *current*
  quadratic predicts as low-quality, then refits on what remains. On
  flat truth this amplifies whichever spurious peak emerged from noise;
  the patch history on this branch shows multiple fixes ("Fix pruning
  bias that drives optimizer to boundary values", "Fix over-aggressive
  null-game abort", "intercept divergence", "warm-start saturation
  cascade") — symptoms of a method that is fragile in the regime it is
  being asked to operate in.

- **Dimension reduction trail.** The branch began with multiple PUCT
  dimensions (`cpuctExploration`, `cpuctUtilityStdevPrior`,
  `cpuctUtilityStdevPriorWeight`, `cpuctExplorationLog`) and removed
  them one by one until only `cpuctExploration` remained. That is itself
  evidence that the joint quadratic surface could not be fit reliably
  from binary-outcome games at the available budgets — i.e., the method
  collapses to a 1-D problem to remain stable, defeating the point of a
  general optimizer.

- **L2 prior centred at zero ≡ "no effect" prior.** On truly flat truth
  the prior wins, and the reported "best" is whatever Gaussian noise
  happened to nudge the linear coefficient toward.

## What this implies

QRS is not strictly worse than naïve fixed-grid Bradley-Terry — it
extracts more information per trial. But on the kind of landscape PUCT
actually presents (very-flat, asymmetric, possibly plateau-shaped), the
*reliable* portion of its output is small: the regret is large in
absolute terms relative to the recoverable win-rate signal, the CIs are
under-cover, and the convex-fallback path silently substitutes the prior
centre for an answer.

A more appropriate replacement would be:

- a **non-parametric surrogate** (Gaussian-process / Bayesian
  optimisation with a Matérn kernel) so the method is not committed to a
  quadratic shape,
- with an **explicit acquisition function** (expected improvement,
  upper-confidence-bound) so trials are spent where they reduce
  posterior uncertainty,
- and a **paired Bradley-Terry likelihood** rather than independent
  logistic regression, so the variance information from the
  fixed-reference structure is preserved.

For the existing implementation, two narrow improvements would partially
mitigate the issues:

1. Surface the convex-fallback state in the user-facing output of
   `tune-params`. When `model().hasConvexDim()` is true at the end of the
   run, the report should say "no reliable recommendation" instead of
   printing the prior centre as if it were the optimum.
2. Calibrate the reported CI by inflating SE on flat fits (e.g. a
   profile-likelihood-based CI rather than the delta-method
   approximation), so that coverage stays near nominal in the regime
   where the quadratic surface is poorly identified.

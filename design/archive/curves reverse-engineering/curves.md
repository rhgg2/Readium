# REAPER CC interpolation curves — recovered formulas

Shapes recovered from `design/curve_samples/*.csv` (seeded by `curve_probe.lua`, baked through a MIDI send and recaptured). Samples are 14-bit (MSB on CC N, LSB on CC N+32 — REAPER auto-pairs these into a true 14-bit stream), giving ~125 rows per curve across `SEGMENT_PPQ = 49152` (4 QN at this project's 12288 PPQ/QN).

Normalised coordinates: `t = ppq / SEGMENT_PPQ ∈ [0, 1]`, `y = val / 16383 ∈ [0, 1]`.

Quantisation floor at 14 bits is `(1/16383)/√12 ≈ 1.76e-5`, so "exact fit" = residual RMSE at that scale.

## Exact forms (non-bezier)

| shape | formula | RMSE |
| --- | --- | --- |
| step | `y = 0` for `t < 1`, `y = 1` at `t = 1` | 0.00000 |
| linear | `y = t` | ~0 (floor) |
| slow | `y = 3t² − 2t³` (smoothstep) | ~0 (floor) |
| fast-start | `y = 1 − (1−t)³` | ~0 (floor) |
| fast-end | `y = t³` | ~0 (floor) |

Smootherstep (`6t⁵−15t⁴+10t³`), sinusoids, and the quadratic variants are all an order of magnitude worse. The cubics are unambiguous.

## Bezier — canonical (h₁ = h₂) parameterisation

Cubic Bézier through `(0,0)` and `(1,1)` with control handles

    P₁ = (h·cos θ₁, h·sin θ₁)
    P₂ = (1 − h·cos θ₂, 1 − h·sin θ₂)

Both handles have equal tangent magnitude `h`; `θ₁` is the exit angle from the origin, `θ₂` the entry angle at `(1,1)`. Fitted per tension by coarse-to-fine grid search over `(h, θ₁, θ₂)` on 21 tensions at Δτ = 0.1.

### Structure

Two symmetries reduce the fit to a single `|τ|`-indexed table:

1. **h depends only on |τ|.** At matched ±τ the two fitted `h` values agree to ≤ 0.0001.
2. **The angles swap under τ → −τ.** At matched ±τ, `θ₁(+τ) = θ₂(−τ)` and vice versa, to ≤ 0.08°.

Both are the canonical content of the antisymmetry relation `bezier(+τ, t) = 1 − bezier(−τ, 1−t)`: reflecting through `(½, ½)` exchanges the two handles, so it swaps the angles but leaves their shared magnitude alone.

### Table (folded on |τ|)

`θ_large` is the steeper angle (near the "flat" end of the curve), `θ_small` the shallower one.

| \|τ\| | h       | θ_large (°) | θ_small (°) |
| ---   | ---     | ---         | ---         |
| 0.00  | 0.2794  | 26.56       | 26.56       |
| 0.10  | 0.3442  | 44.14       | 19.39       |
| 0.20  | 0.4020  | 56.43       | 14.13       |
| 0.30  | 0.4642  | 65.63       | 10.38       |
| 0.40  | 0.5326  | 72.46       |  7.75       |
| 0.50  | 0.6059  | 77.53       |  5.79       |
| 0.60  | 0.6820  | 81.35       |  4.23       |
| 0.70  | 0.7604  | 84.30       |  2.95       |
| 0.80  | 0.8397  | 86.61       |  1.84       |
| 0.90  | 0.9198  | 88.47       |  0.88       |
| 1.00  | 1.0000  | 90.00       |  0.00       |

To reconstruct `(aₓ, aᵧ, bₓ, bᵧ)` for a given τ:

    h, θ_large, θ_small = interpolate(|τ|)
    if τ ≥ 0:  θ₁, θ₂ = θ_small, θ_large   -- fast-start family
    else:      θ₁, θ₂ = θ_large, θ_small   -- fast-end family
    aₓ, aᵧ = h·cos θ₁, h·sin θ₁
    bₓ, bᵧ = 1 − h·cos θ₂, 1 − h·sin θ₂

### Fit quality

- `|τ| ≤ 0.5`: RMSE ≤ 1e-4 — near the 14-bit quantisation floor (~1.8e-5).
- `|τ| ∈ {0.7, 0.8}`: RMSE ~3e-4, ~16× floor. Not yet explained — possibly REAPER's internal integer quantisation biting where the curve is most "square", or mild capture aliasing near the visible inflection. Inconsequential for visualisation.
- Canonical fit beats the unconstrained 4-param fit by up to 20× at `|τ| = 0.8` (the free fit lands in shallow local minima there). The h₁=h₂ constraint is a structural property of REAPER's curves, not just a convenience.

### Clean values at the fixed points

- **τ = 0**: `h = √5/8 ≈ 0.2795`, `θ₁ = θ₂ = arctan(½) ≈ 26.565°`. So `P₁ = (¼, ⅛)`, `P₂ = (¾, ⅞)` — a mild S through `(½, ½)`, *not* the identity. (Passing `shape = 5, beztension = 0` is not the same as `shape = 1`.)
- **τ = ±1**: `h = 1`, angles `(90°, 0°)` or `(0°, 90°)`. Both handles collapse onto a single corner — `(0, 1)` or `(1, 0)` — and the curve degenerates into an explicit cubic through a right-angled corner.

### No clean closed form for h(|τ|), θ(|τ|)

Simple candidates (power laws in |τ|, low-order polynomials, trig) don't match within floor. The 11-row table is smooth and monotonic; linear interpolation between rows is adequate for visualisation.

## For visualisation

`curveSample(shape, tension, t) → y`:

- **Non-bezier shapes**: use the closed forms above directly.
- **Bezier**: linear-interpolate `(h, θ_large, θ_small)` between the nearest two rows above using `|τ|`, apply the sign rule to get `(θ₁, θ₂)`, derive `(aₓ, aᵧ, bₓ, bᵧ)`, then solve `y(t)` by dense sampling of the cubic Bézier in `s` with binary search on `x`. (See `makeBezFn` in `curve_fit.lua` for the reference implementation.)

Placement — `util.lua` vs nearer the view layer — still to be decided with the user.

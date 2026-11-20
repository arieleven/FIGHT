# Methodology

This page documents how FIGHT turns heart-rate data into ratings, readiness, plans and warnings. Every calculation runs on-device. Source files are linked for each section.

> **Scoring convention.** Most components are mapped linearly onto 0–100 between a "worst" and a "best" reference value, clamped at both ends. A metric's score is the weighted mean of the components that have data. Components without data are skipped, and their weight is redistributed. If no component has data, the metric shows *Need Data*. Grades: **Elite** ≥ 85 · **Strong** ≥ 70 · **Solid** ≥ 55 · **Developing** ≥ 40 · **Needs Work** below 40.
>
> Ratings use the **last 28 days**. The trend arrow compares against the **28 days before that**. Only sessions belonging to the active fighter profile are used.

---

## 1. Heart-rate zones

[`Models.swift`](../Sources/App/Models.swift)

| Method | Zone ceilings (Z1–Z4; Z5 is above Z4) |
|---|---|
| **Karvonen (HRR)** *(default)* | resting + (max − resting) × 0.60 / 0.70 / 0.80 / 0.90 |
| **Lactate threshold** | LTHR × 0.81 / 0.89 / 0.95 / 1.00 |
| **% Max HR** | max × 0.60 / 0.70 / 0.80 / 0.90 |
| **Manual** | user-defined |

- **Max HR**, when auto-estimated, uses Tanaka: `208 − 0.7 × age`.
- **LTHR field test** (Friel protocol): a 10-minute progressive warm-up, then a 20-minute maximal sustainable effort. LTHR is the mean HR of the 20-minute trial. Completing the test switches the profile to LTHR zones.

## 2. Session metrics

[`Models.swift`](../Sources/App/Models.swift) · [`LiveWorkoutView.swift`](../Sources/App/LiveWorkoutView.swift)

| Metric | Definition |
|---|---|
| **Calories** | Keytel et al. HR-based energy expenditure (sex, weight, age, HR), floored at BMR. BMR uses Mifflin–St Jeor. *Active* = total − BMR. |
| **TRIMP** (training load) | Banister: Σ Δt(min) × HRr × 0.64 × e^(b × HRr), where HRr = (HR − rest)/(max − rest) and b = 1.92 (male) or 1.67 (female). |
| **Cardiac drift** | % change in mean HR between the first and second halves of the session, after discarding the first 10%. |
| **HRR-60** | HR drop 60 s after a round ends (stool recovery), or after a detected high-effort peak (≥ 80% max HR) in continuous sessions. Drops under 8 BPM are ignored. |
| **EPOC estimate** | (Z4 min × 1.6 + Z5 min × 3.4) × weight/75 kcal. |
| **Points of interest** | Peak HR; fastest 60-s recovery; largest ≥ 24 BPM rise within 20–26 s; first Zone 5 entry. |

## 3. Beat-to-beat (RR) analysis

[`HRVMath.swift`](../Sources/App/HRVMath.swift)

**Artifact correction.** RR intervals outside 300–2000 ms are rejected. So is any beat deviating more than 20% from the median of up to 5 valid neighbours on each side. The artifact rate (rejected ÷ total) gates every downstream feature:

| Feature | Requirement |
|---|---|
| HRV (RMSSD) | ≥ 60 clean beats and ≤ 10% artifacts |
| DFA α1 | ≥ 100 clean beats and ≤ 5% artifacts |

**RMSSD** = √(mean of squared successive differences of clean RR). The **HRV score** shown in the app is `ln(RMSSD) × 20`.

**DFA α1** (short-term detrended fluctuation analysis):
1. Integrate the mean-centred RR series.
2. For box sizes n = 4…16 beats, linearly detrend each box and compute the RMS fluctuation F(n).
3. α1 = slope of log F(n) vs. log n.

α1 ≈ 1.0 at easy intensity and falls through **0.75 at the aerobic threshold (VT1)**.

**VT1 estimate.** Sliding 2-minute windows (30-s step) across a session yield (mean HR, α1) pairs. A linear fit of α1 on HR is solved for α1 = 0.75. The estimate is accepted only with ≥ 6 valid windows, a ≥ 15 BPM HR range, a negative slope, r² ≥ 0.25, and a result within 10 BPM of the observed range.

**Live α1** is recomputed every 10 s from the most recent ~160 beats during a workout.

**HR surge** = the largest HR rise within any 20-second span (cardiovascular on-kinetics / explosiveness).

> Optical armbands produce usable RR at rest but frequently fail the artifact gates during hard exercise. Chest straps are recommended for in-exercise RR features.

## 4. Training load model

[`CoachEngine.swift`](../Sources/App/CoachEngine.swift)

Banister impulse-response model on daily TRIMP, with an 84-day warm-up window:

- **Fitness (CTL)**: `CTL += (load − CTL) / 42`
- **Fatigue (ATL)**: `ATL += (load − ATL) / 7`
- **Form (TSB)** = CTL − ATL
- **Acute:chronic workload ratio** = ATL / CTL (shown once CTL ≥ 5)
- **Training monotony** (Foster) = mean ÷ SD of the last 7 daily loads

## 5. Metric ratings

| Metric | Components (worst → best · weight) |
|---|---|
| **Aerobic Base** | Z1–2 min/week (20 → 150 · 40%) · steady-session drift (12% → 3% · 25%) · VT1 as % max (65% → 85% · 20%) · morning resting HR (75 → 45 BPM · 15%) |
| **Anaerobic Power** | Z4–5 min/week (5 → 35 · 35%) · peak % max (85% → 97% · 20%) · max 20-s surge (15 → 40 BPM · 25%) · rounds peaking above Z4 per week (2 → 15 · 20%) |
| **Fight Stamina** | Round HR creep: mean of the last third of rounds vs. the first third (12% → 1% · 45%) · drift in ≥ 30-min continuous sessions (12% → 3% · 30%) · rounds per round-based session (3 → 10 · 25%) |
| **Recovery Speed** | Mean 60-s HR drop (12 → 35 BPM · 50%) · late ÷ early round recovery (0.6 → 1.0 · 25%) · 7-day vs. 28-day ln RMSSD z-score (−1.5 → +0.5 · 25%) |
| **Consistency** | Sessions/week (1 → 5 · 60%) · weeks with ≥ 2 sessions out of 4 (1 → 4 · 40%) |
| **Load Balance** | 100 − \|ACWR − 1.05\| × 160 (70%) · monotony (2.5 → 1.2 · 30%) |
| **Intensity Mix** | Z3 share (45% → 15% · 60%) · Z1–2 share (40% → 70% · 40%) |

**Fight Fitness** = the mean of Aerobic Base, Anaerobic Power, Fight Stamina and Recovery Speed.

## 6. Readiness

| Component | worst → best | Weight |
|---|---|---|
| Form (TSB) | −30 → +10 | 30% |
| Today's ln RMSSD z-score vs. the previous 14 checks | −2 → +0.5 | 25% |
| Resting HR vs. baseline | +8 → −2 BPM | 15% |
| Sleep + (6 − soreness) | 2 → 10 | 15% |
| Hours since the last hard session (≥ 20% time in Z4–5 or TRIMP ≥ 90) | 12 → 48 | 15% |

Labels: **Primed** ≥ 75 · **Good to train** ≥ 55 · **Go easy** ≥ 35 · **Recover** below 35. A check counts as "today" if it was taken within the last 18 hours.

## 7. Next-session prescription

Rules are evaluated in order:

1. **Recovery day**: readiness < 35 or form < −30. A 20–30 min Zone 1 walk plus mobility.
2. **Technical flow**: readiness < 55, ACWR > 1.5, or a hard session within the last 24 h. 5 × 3 min controlled, kept under the Z3 ceiling.
3. **Targeted session** for the weakest of the four core metrics:
   - Aerobic Base → 40 min Zone 2 roadwork (capped at VT1 if known)
   - Anaerobic Power → 10 × 30 s all-out bag work, 90 s rest
   - Fight Stamina → 7 × 3 min, 30 s rest
   - Recovery Speed → 6 × 3 min fight pace, 60 s rest with paced nasal breathing

## 8. Workout review

| Item | Scoring |
|---|---|
| **Intent match** | Zone distribution vs. the drill tag. *Aerobic Z2*: ≥ 80% Z1–2 · *Technical*: ≥ 70% Z1–3 and little Z4–5 · *Bag / HIIT*: ≥ 25% Z4–5 · *Sparring / Shark tank*: ≥ 35% Z4–5 |
| **Round consistency** | Round HR creep (12% → 1%) |
| **Recovery** | Mean 60-s drop (12 → 35 BPM) |
| **Pacing** | Cardiac drift on continuous sessions ≥ 20 min (12% → 3%) |
| **Peak output** | Max HR as % of max on hard sessions (82% → 97%) |
| **Load vs. normal** | Session TRIMP ÷ median of the previous 28 days |

## 9. Fight-camp periodization

[`CampPlanner.swift`](../Sources/App/CampPlanner.swift)

The camp counts back from fight day in 7-day blocks:

- **Taper:** 1 week (2 weeks for camps of 10+ weeks)
- **Peak:** 2 weeks (1 week for camps under 8 weeks)
- **Build:** ~50% of the remaining weeks
- **Base:** the rest

**Baseline weekly load** = CTL at camp start × 7, with a minimum of 250.

| Phase | Weekly target | Intensity mix (easy/tempo/hard) |
|---|---|---|
| Base | +8% per week | 80 / 10 / 10 |
| Build | +5% per week | 70 / 10 / 20 |
| Peak | 100% then 90% of top load | 65 / 10 / 25 |
| Taper | 65% → 50%; fight week 40% | 75 / 5 / 20 |

Every 4th week in base or build is a **deload** at 70% of target.

## 10. Weight-cut analysis

[`CampPlanner.swift`](../Sources/App/CampPlanner.swift)

- **Trend:** linear regression over the last 14 days of weigh-ins (needs ≥ 3 entries spanning ≥ 4 days), reported in kg/week.
- **Required rate** = kg to go ÷ weeks to fight. **Projection** = current + trend × weeks to fight.

| Warning | Trigger |
|---|---|
| 🔴 Rapid drop | ≥ 2% loss between weigh-ins ≤ 36 h apart |
| 🟡 Fast daily loss | ≥ 1.2% in ≤ 36 h (outside fight week) |
| 🔴 / 🟡 Urine colour | ≥ 6 / 4–5 on the 8-point Armstrong chart, logged within 24 h |
| 🔴 Dehydration signs | Resting HR ≥ +6 BPM vs. baseline **and** ≥ 1% weight loss over the previous 24–72 h |
| 🔴 / 🟡 HRV suppressed | ln RMSSD z ≤ −1.5 (red if weight is also dropping) |
| 🟡 Losing too fast | Trend > 1.5% of body weight per week (outside fight week) |
| 🟡 / 🔴 Aggressive target | Required rate > 1% / > 1.5% of body weight per week |
| 🔴 Unsafe water cut | > 5% of body weight still to lose in fight week |

---

## References

- Banister EW. *Modeling elite athletic performance.* In: Physiological Testing of Elite Athletes, 1991.
- Foster C. *Monitoring training in athletes with reference to overtraining syndrome.* Med Sci Sports Exerc, 1998.
- Gabbett TJ. *The training–injury prevention paradox: should athletes be training smarter and harder?* Br J Sports Med, 2016.
- Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. *Training adaptation and heart rate variability in elite endurance athletes.* Sports Med, 2013.
- Rogers B, Giles D, Draper N, Hoos O, Gronwald T. *A new detection method defining the aerobic threshold for endurance exercise and training prescription based on fractal correlation properties of heart rate variability.* Front Physiol, 2021.
- Karvonen MJ, Kentala E, Mustala O. *The effects of training on heart rate; a longitudinal study.* Ann Med Exp Biol Fenn, 1957.
- Tanaka H, Monahan KD, Seals DR. *Age-predicted maximal heart rate revisited.* J Am Coll Cardiol, 2001.
- Keytel LR et al. *Prediction of energy expenditure from heart rate monitoring during submaximal exercise.* J Sports Sci, 2005.
- Mifflin MD, St Jeor ST et al. *A new predictive equation for resting energy expenditure in healthy individuals.* Am J Clin Nutr, 1990.
- Armstrong LE et al. *Urinary indices of hydration status.* Int J Sport Nutr, 1994.
- Friel J. *The Triathlete's Training Bible* (LTHR field test protocol).

*All thresholds are coaching heuristics derived from this literature. They are designed to guide training decisions, not to diagnose.*

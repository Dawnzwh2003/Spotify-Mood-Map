# STSCI 5954: Direct-Feature Mood Map

This project places songs on a two-dimensional map using **valence on the horizontal axis** and **energy on the vertical axis**. It also selects a song for a requested screen position, with an optional local tempo-aware rule for continued listening.

All explanations are in this README. The R files contain executable code. The analysis writes **only five high-resolution PNG figures** to `outputs/`: no CSV tables, saved catalogues, PDF duplicates, logs or intermediate result files. Statistics and the catalogue remain available as R objects during the session.

## 1. Run the project

source("mood_map.R")
result <- run_analysis(file.choose(), "outputs")


## 2. What the code does, step by step

| Step | Function / object | Purpose |
|---|---|---|
| Read the data | `read.csv()` | Load playlist–track records. The same song can occur in multiple playlists. |
| Clean and deduplicate | `clean_tracks(raw)` | Validate feature values, inspect conflicting duplicates, and retain one row per track ID. |
| Set the coordinates | `transform_axes(cleaned$data)` | Set x to observed valence and y to observed energy, both on their original 0–1 scales. |
| Select an initial song | `select_song(..., mode = "nearest")` | Return the song closest to the requested point. |
| Continue listening | `select_song(..., mode = "smooth")` | Choose among nearby tracks using tempo compatibility and location fidelity. |
| Evaluate | `evaluate_paths()`, `grid_coverage()` | Examine scripted song transitions and screen coverage. |
| Draw the figures | `run_analysis()` | Perform the analysis and write the five presentation images. |

The entry script demonstrates the main objects and song-selection calls, then calls the complete analysis. It prints a few checks in the R console; it does not save those checks as files.

### Data preparation

Missing track identifiers are removed. Numeric audio values outside their valid ranges are treated as missing. Tempo values at or below zero are unavailable tempo estimates. Duplicate track identifiers retain an actual row, prioritizing valid coordinates and more complete audio information, followed by a fixed lexical tie rule. This makes the result independent of input row order.

A song needs only valid energy and valence to receive coordinates. Missing tempo does not remove it from the map. Popularity values of zero are retained; popularity does not affect either coordinates or retrieval. Other available audio features are used for descriptive correlations and cleaning checks, not weighted into the axes.

The original data contained 32,833 playlist–track records. Removing 4,477 repeated records left **28,356 unique tracks**, with no conflicting duplicate audio rows. One track had zero recorded tempo, leaving 28,355 valid tempo estimates while retaining all 28,356 map positions.

## 3. The coordinate method

For track i:

\[
x_i=\mathrm{valence}_i,\qquad y_i=\mathrm{energy}_i.
\]

| Direction | Interpretation |
|---|---|
| Right / left | More / less musical positiveness |
| Up / down | Higher / lower perceived intensity |

This is deliberate feature selection that prioritizes clear labels and stable placement of new songs. It does not claim to preserve every audio property. Valence is an audio descriptor rather than a measurement of an individual listener's emotion. Energy is not the same as tempo; songs with similar coordinates can differ in speed, vocals, instrumentation or genre.

There are no fitted coordinate parameters or outcome labels. Therefore, no model training or train/test split is needed for this fixed mapping. The reported checks evaluate the current catalogue, not emotion-prediction accuracy. Adding new songs leaves existing coordinates unchanged.

## 4. How a click selects a song

For click q and track coordinates (x, y), calculate Euclidean distance:

\[
d_i(q)=\sqrt{(x_i-q_x)^2+(y_i-q_y)^2}.
\]

Both axes have equal distance weight, an explicit interface-design choice.

**Initial selection:** `mode = "nearest"` returns the minimum-distance track. Exact ties are resolved by ascending track ID (Identifier). For a fixed catalogue and position, the answer is deterministic.

**Continued listening:** `mode = "smooth"` first keeps at most the 20 closest tracks satisfying

\[
d_i\leq d_{\min}+\epsilon,
\]

where the default extra-distance allowance is epsilon = 0.03. It prefers candidates outside the supplied recent history. If all candidates are excluded, it excludes only the previous song; if that also empties the pool, it permits a repeat. It then minimizes

\[
\mathrm{score}_i=
\frac{|\mathrm{tempo}_i-\mathrm{tempo}_{\mathrm{previous}}|}{30}
+\frac{d_i-d_{\min}}{\max(\epsilon,10^{-12})}.
\]

The first term penalizes tempo changes; the second penalizes extra map error. BPM (Beats Per Minute) measures tempo. The 30-BPM scale, 0.03 allowance and 20-candidate cap are adjustable design choices, not statistically established optima.

The allowance is **additional distance relative to the nearest song**, not an absolute radius around the click. A chosen distance above 0.10 sets a sparse-match flag, while still returning a song. This threshold is a geometric diagnostic rather than a validated perceptual cutoff.

Missing candidate tempos receive a penalty; when all candidate tempos or the previous tempo are unavailable, local distance order provides a fallback. Smooth mode without a previous song also returns the nearest track. The evaluation retains five recent selections; application code must provide its own `recent_ids`, because the function stores no persistent playback history.

## 5. How to use the method for a new request

### A. Return a song for a screen position

If the complete analysis has already run, reuse its in-memory catalogue:

```r
catalogue <- result$catalogue

first_song <- select_song(
  catalogue,
  tap = c(0.65, 0.70),
  mode = "nearest"
)

first_song[, c("track_id", "track_name", "track_artist", "x", "y", "tap_distance")]
```

Alternatively, build the catalogue without generating figures:

```r
source("mood_map.R")
raw <- read.csv("C:/path/to/spotify_songs.csv", stringsAsFactors = FALSE, encoding = "UTF-8")
catalogue <- transform_axes(clean_tracks(raw)$data)
```

Select a subsequent song using the previous selection:

```r
next_song <- select_song(
  catalogue,
  tap = c(0.66, 0.70),
  previous_id = first_song$track_id,
  recent_ids = first_song$track_id,
  mode = "smooth"
)

next_song[, c("track_name", "tempo", "tap_distance", "excess_distance")]
```

For another call, update `previous_id` and retain the last five identifiers in `recent_ids`. Different playback histories can return different songs. The function returns track information; it does not connect to a streaming player.

### B. Position a new song

```r
new_song <- data.frame(track_id = "new_song_001", valence = 0.60, energy = 0.80)
transform_axes(new_song)
```

The output position is x = 0.60, y = 0.80. This is a fixed mapping of supplied descriptors, not a learned prediction. **The inputs must already include energy and valence. The code cannot infer them from a title or an audio file.**

To add the song to the searchable catalogue without moving existing tracks:

```r
new_song <- data.frame(
  track_id = "new_song_001",
  track_name = "Example song",
  track_artist = "Example artist",
  valence = 0.60,
  energy = 0.80,
  tempo = 120
)

updated_catalogue <- add_songs(catalogue, new_song)
```

`add_songs()` cleans the new records and appends previously unseen identifiers. Existing identifiers retain their records. New songs without tempo can still be positioned and retrieved by distance.

### Selection diagnostics

| Field | Meaning |
|---|---|
| `x`, `y` | The selected song's coordinates |
| `tap_distance` | Distance from the selected song to the click |
| `nearest_distance` | Smallest available click-to-song distance |
| `excess_distance` | Selected distance minus nearest distance |
| `candidate_count` | Number of retained local candidates |
| `sparse_region` | Whether selected distance exceeds 0.10 |

## 6. Presentation figures and their messages

The generated `outputs` folder contains exactly these **five 300-DPI PNG images**. Figures 2–5 use a 16:9 canvas at 3600 × 2025 pixels; Figure 1 uses a square 2700 × 2700 canvas to keep the correlation matrix readable. All have English labels and white backgrounds, ready to insert into PowerPoint.

| Figure | Filename | What it shows and how to interpret it |
|---|---|---|
| 1. Feature relationships | `fig1_feature_relationships.png` | Song-level Spearman correlations among available audio features. Red indicates positive association, blue negative association. This describes relationships and supports discussion of different musical properties; the other features do not enter the coordinate formula. |
| 2. Direct mood map | `fig2_interpretable_mood_map.png` | Valence horizontally and energy vertically, with darker regions indicating greater song density. The dotted midlines are visual guides, not trained emotion-class boundaries. |
| 3. Screen coverage | `fig3_screen_coverage.png` | Nearest-song distance at 31 × 31 screen locations. Darker regions have farther matches. Gaps are larger near the lowest-energy boundary; geometric coverage does not establish perceptual appropriateness. |
| 4. Tempo along a path | `fig4_path_tempo.png` | Selected tempos along a horizontal path at energy 0.5, comparing nearest-track and local tempo-aware retrieval. This illustrates one path; aggregate conclusions use all five paths. |
| 5. Locality tradeoff | `fig5_locality_tradeoff.png` | How extra-distance allowances of 0, 0.01, 0.03 and 0.05 affect median changed-track tempo jumps and mean click error. This is an exploratory design tradeoff, not independent validation of an optimal parameter. |

Suggested slide captions:

1. **Energy and valence provide distinct, interpretable controls.** Correlations describe audio-feature relationships, not perceptual mood accuracy.
2. **Direct coordinates keep the map meanings stable.** New songs can be placed without refitting or moving existing tracks.
3. **Coverage is broad, with larger gaps near the lowest-energy boundary.** Of 961 grid points, 98.75% have a closest song within 0.05 map units.
4. **Local retrieval can reduce tempo jumps without changing the axes.** Both rules follow the same requested path through the full catalogue.
5. **Wider local search trades position fidelity for tempo continuity.** Increasing the allowance from 0 to 0.05 reduces the median changed-track tempo jump from 25.44 to 2.29 BPM and increases mean click distance from 0.00561 to 0.01298 in these paths.

## 7. Evaluation and current results

Five predetermined paths contain 61 positions each: horizontal at energy 0.25 and 0.50, vertical at valence 0.50, a diagonal and an antidiagonal. Each spans 0.05–0.95. History resets for each path, yielding 305 selections and 300 possible transitions per rule. Tempo jumps are summarized only when the song changes; repeat rates are reported separately.

| Full-catalogue diagnostic | Nearest track | Local tempo-aware |
|---|---:|---:|
| Changed-track transitions | 278 | 298 |
| Median tempo jump, BPM | 27.0170 | 3.2395 |
| 90th percentile tempo jump, BPM | 76.3784 | 12.1969 |
| Changed-track transitions over 30 BPM | 46.04% | 3.36% |
| Mean click-to-song distance | 0.00561 | 0.01069 |
| Immediate repeat rate | 7.33% | 0.67% |

The local rule improves the measured tempo-continuity diagnostic while accepting larger location error. These are full-catalogue scripted-path results, not a human listening experiment or predictive-accuracy estimate. At epsilon = 0, smooth retrieval can still use tempo and history among exact-distance ties, so it need not match nearest retrieval exactly.

On the coverage grid, the largest nearest-song distance is 0.07203. Adding half the grid-cell diagonal gives a conservative all-screen bound of approximately 0.09560. This is a geometric statement under the chosen coordinate distance, not a guarantee about perceived mood. Smooth retrieval may add up to epsilon beyond the nearest-song distance.

Inspect statistics in R without writing intermediate files:

```r
result$performance
result$coverage
result$sensitivity
result$audit
```

Remaining limitations include half/double-time tempo estimates, audible changes not represented by the two axes, dependence on scripted click paths, and the absence of listening tests. Lower tempo jumps alone do not establish a better listening experience.

## 8. Files and checks

| File | Purpose |
|---|---|
| `mood_map.R` | Cleaning, fixed coordinates, retrieval, new-song insertion, evaluation and figure generation |
| `run_analysis.R` | Editable entry script and step-by-step calls |
| `tests.R` | Constructed edge cases and a temporary synthetic-data end-to-end check |
| `README.md` | Methods, usage, interpretation and presentation captions |
| `outputs/*.png` | The five final presentation figures |

The checks cover distance ties, missing tempo, invalid clicks, empty and single-track catalogues, repeat-exclusion fallbacks, locality limits, duplicate handling, minimal new-song input and unchanged existing coordinates after additions. The end-to-end test also verifies that the output directory contains exactly five PNG files. Temporary synthetic input is created only for testing and is not included in the deliverable.

The included real-catalogue results were checked against the prior full-catalogue evaluation. No streaming integration or user-satisfaction study was performed.

Project context: [scope of work](https://docs.google.com/document/d/1mtpCZh2Tg7SAlpydjaPwFc06HawbccWKIZZHylgiYo8/edit), [client questions](https://docs.google.com/document/d/12a-lRoPQdV8DzWUppTol1-FF8rZScgfWzKhVwUX0eos/edit), and [intermediate deck](https://docs.google.com/presentation/d/1gv46m2c7UEY2oZQGtQx6zbTDkz0QmeISqDBX5wnvo38/edit). Descriptor definitions follow the [Spotify audio-feature reference](https://developer.spotify.com/documentation/web-api/reference/get-audio-features); the code makes no Spotify requests.

Artificial Intelligence (AI) assistance: ChatGPT assisted with the code and documentation. Team members should review the methods, numbers and interpretations before submission.

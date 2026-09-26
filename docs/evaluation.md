# Evaluation results: pipeline and models

What was measured to arrive at the current placement pipeline and model profiles, September 2026. Every number
comes from `arrumator eval` runs through the live pipeline in a throw-away archive; nothing here is estimated.

## Setup

- **Server:** Mac mini (M5, 16 GB unified memory) running Ollama 0.34.4, reached over the local network
  (`ARRUMATOR_OLLAMA_URL`). About 11 GB of that memory is available to the GPU, which caps model size at the 14B
  class; larger models would have to swap.
- **Profile under test:** one model makes the decisions, describes images and names files, with one context size
  (12,288 tokens). The embedding model is `bge-m3` unless stated otherwise.
- **Standard corpus:** `Tests/Fixtures`, 41 documents, `eval --passes 2`. Pass 2 files the same documents again.
- **Three-instance corpora:** each kind of document occurs three times, as a recurring document does. They are built
  from the fixture generator run with several seeds, which keeps each document's kind, sender and dates and changes
  its identifiers and amounts:
  - `fixturegen --out <dir>/s43 --seed 43`, then `--seed 44` into `s44`. The committed fixtures are seed 42.
  - One `expected.json` lists seed 42, then 43, then 44, with each path prefixed by its seed folder (`s43/pt/…`).
    The negative fixtures are kept for the first seed only, which gives 113 documents.
  - The same corpus in reverse order, to measure how much arrival order matters.
  - A second corpus from seeds 45, 46 and 47, to measure how much the particular documents matter.
  - `eval --passes 1` on each.
- **Robust numbers are means over those three trajectories** (forward, reversed, second corpus). One run is
  deterministic, but a slightly different prompt changes a few early decisions, and they cascade through what is
  learned. Differences under about ±0.04 F1 are within the spread between trajectories.

### Metrics

- **F1, P, R:** grouping precision and recall over document pairs, as `arrumator eval` reports them. P falls when
  kinds are mixed in one folder; R falls when one kind is split over several.
- **Folders:** folders holding documents after the run. There are 21 kinds.
- **Recurrence:** the later instances of a kind filed into the folder its first instance went to. On the standard
  corpus, **stable** is the same measure between pass 1 and pass 2.
- **ARI:** adjusted Rand index between the groupings of the forward and reversed runs. 1 means arrival order changes
  nothing.
- **Sender:** the recognised sender matches the corpus, counting its accepted alternative names and matching across
  scripts and legal forms.
- **Time:** mean seconds per document, and minutes for the 113 documents.

## Pipeline: what helped

`gemma4:e2b-it-qat`, three-instance corpora, means of three trajectories:

| pipeline | F1 | P | R | folders | recurrence | ARI | s/doc |
|---|---|---|---|---|---|---|---|
| name-based folder matching (before) | 0.45 | 0.84 | 0.31 | 50 | 55% | 0.55 | 7.7 |
| canonicalization | 0.52 | 0.67 | 0.43 | 38 | 54% | 0.36 | 8.3 |
| **canonicalization + recurring documents join their predecessor** | **0.66** | 0.76 | **0.58** | **27** | **83%** | 0.54 | **5.9** |

- **Canonicalization** (`PlacementGuard`, `placementGuard.offerAbove`, `choices`, `rankFusionK`) maps a folder the
  model named freely onto the few most alike folders beside it, in one multiple-choice question.
- **Recurring documents join their predecessor.** A document almost identical to a confidently filed one goes to its
  folder without the model deciding (`learning.directPlacement.knnMinNeighbors` 1).
- **Why this works:** `gemma4:e2b` proposed the same path for only 24 of 66 repeat documents, and the same top-level
  area for 39 of them. A small model names a recurring document differently every time, so the archive's own filings
  have to keep repeats together.
- **It holds for larger models too** (canonicalization → with the recurring-document step, forward order, 113
  documents):

| model | F1 | P | recurrence | folders | s/doc |
|---|---|---|---|---|---|
| gemma4:e4b | 0.51 → 0.61 | 0.77 → 0.76 | 40% → 81% | 43 → 30 | 15.7 → 11.1 |
| gemma4:12b | 0.57 → 0.62 | 0.90 → 0.91 | 71% → 93% | 40 → 33 | 30.3 → 23.5 |

  A document that joins its predecessor needs no model call, so the step also makes filing faster.

- **On the standard corpus** (`eval Tests/Fixtures --passes 2`, name-based → canonicalization → with the
  recurring-document step):

| model | F1 pass 1 / 2 | P pass 2 | stable | folders |
|---|---|---|---|---|
| gemma4:e2b | 0.35/0.18 → 0.44/0.48 → **0.53/0.60** | 0.67 → 0.70 → 0.82 | 56% → 42% → 81% | 48 → 40 → 30 |
| gemma4:e4b | 0.19/0.48 → 0.39/0.47 → 0.39/0.48 | 1.00 → 0.64 → 0.70 | 33% → 47% → 86% | 55 → 40 → 29 |

No run filed a document with another sender's documents (sender mix-ups: 0).

## Pipeline: what did not help

Each was built and measured against the pipeline above. Measured on `gemma4:e2b` on the three-instance corpus unless
stated.

| approach | result | verdict |
|---|---|---|
| Ask the folder question in 3 rotated orders and take the majority (permutation self-consistency) | F1 0.50 vs 0.51; recurrence 56% vs 43%. Combined with the recurring-document step, 0.63 vs 0.68 | no gain |
| The model's own new folder as a numbered option instead of "none" | F1 0.37, P 0.94, 62 folders: the small model almost always picks its own | worse |
| Show the paths of similar past filings while the model decides (retrieval few-shot) | F1 0.48, P 0.61, recurrence 57% | worse: the model copies paths that don't fit, as the "show no folders" design anticipated |
| Before making a folder, ask whether the folder of the most similar past documents is the home | F1 0.57, recurrence 74% alone; with the recurring-document step 0.65 vs 0.66 | redundant once repeats join their predecessor |
| Offer every sibling (up to 8), 3 orders, plus the step above | F1 0.60, P 0.62, 10.5 s/doc | worse and slower |
| A logic with fixed top-level areas, with or without typical topics per area (standard corpus, 2 passes) | F1 0.32/0.42 and 0.37/0.33 vs 0.44/0.48 | worse: the small model files into the area and stops |
| The same with at least two levels enforced by the schema | F1 0.49–0.54 vs 0.68 | worse |
| Refresh folder descriptions every 3 documents | F1 0.61 vs 0.61, slower | no gain |
| Send back folder names written in another language than the archive's (NaturalLanguage recogniser) | e2b 0.69 vs 0.68 (it names in English anyway); e4b 0.58 vs 0.61 (foreign names 5 → 2) | no gain |
| Stricter candidate floor, `offerAbove` 0.7 (forward + reversed) | F1 0.60 vs 0.64; P 0.84 vs 0.74; ARI 0.66 vs 0.54; 33 folders vs 27 | a trade-off toward precision, not a gain |
| Near-duplicate threshold `knnMinSimilarity` 0.88 / 0.95 (forward + reversed) | 0.645 / 0.582 vs 0.644 at 0.92 | 0.92 is on the plateau |
| EmbeddingGemma 300M as the embedder, thresholds unchanged | F1 0.46 vs 0.51 | worse without recalibrated thresholds |
| The model says which of the detected identifiers are the sender's, and only those are learned (plus the contrast rule below) | sender accuracy +2 points, fewer held for review; F1 0.58 vs 0.66 (means of three) | costs grouping consistency |
| An identifier identifies a sender only once other senders' documents lack it (`stableKeyMinContrast`), without the model attributing identifiers (standard corpus, 2 passes) | F1 0.41/0.30 vs 0.43/0.19; sender 78% vs 81% | no clear gain |

### Candidate retrieval for the folder question

These were measured on 25 hand-labelled pairs of top-level folder names from one run, 11 of them the same thing.
AUC shows how well similarity separates same from different. "In top 4" is the share of cases where the true
match was among the first four candidates out of 20.

| embedding | names AUC | name + description AUC | in top 4: names / fused |
|---|---|---|---|
| bge-m3 (in use) | 0.76 | 0.80 | 59% / **91%** |
| EmbeddingGemma 300M | 0.95 | 0.84 | 86% / 95% |
| EmbeddingGemma, prefix `task: sentence similarity \| query:` | 0.95 | 0.90 | – / 91–100% |
| EmbeddingGemma, prefix `task: clustering \| query:` | 0.59 | 0.70 | – / 73% |
| qwen3-embedding 0.6B | 0.85 | 0.92 | 73% / 86% |

"Fused" is reciprocal rank fusion of the ranking by name and the ranking by name with description, as
`PlacementGuard.offers` does.

## Models

The pipeline above ran on every model that fits the 16 GB Mac mini, one model per profile. Rows with three runs
are means over the three trajectories; the others ran on the forward corpus only, because they were clearly behind
after it.

| model (download) | runs | F1 | P | R | folders | recurrence | ARI | sender | held | s/doc | min / 113 docs |
|---|---|---|---|---|---|---|---|---|---|---|---|
| gemma4:e2b-it-qat (4.3 GB) | 3 | 0.66 ±0.04 | 0.76 | 0.58 | 27 | 83% | 0.54 | ~77% | 5.0 | **5.9** | **11** |
| qwen3.5:4b (3.4 GB) | 1 | 0.56 | 0.97 | 0.40 | 37 | 92% | – | 80% | 0 | 8.3 | 16 |
| gemma3:4b (3.3 GB) | 1 | 0.59 | 0.64 | 0.55 | 30 | 75% | – | 78% | 6 | 10.6 | 20 |
| gemma4:e4b (9.6 GB) | 3 | 0.63 ±0.03 | 0.81 | 0.52 | 31 | 81% | 0.52 | 85% | 0 | 13.1 | 25 |
| ministral-3:8b (6.0 GB) | 3 | 0.65 ±0.03 | 0.92 | 0.51 | 33 | 85% | 0.71 | 85% | 1.0 | 15.6 | 29 |
| qwen3.5:9b (6.6 GB) | 1 | 0.56 | 0.69 | 0.47 | 32 | 78% | – | 87% | 6 | 26.2 | 49 |
| gemma4:12b (7.6 GB) | 3 | 0.63 ±0.01 | **0.94** | 0.48 | 33 | **94%** | 0.84 | **90%** | 0 | 36.3 | 68 |
| **ministral-3:14b (9.1 GB)** | 3 | **0.71 ±0.03** | 0.90 | **0.58** | 30 | 92% | **0.85** | 86% | 2.0 | 24.8 | 47 |

- **Larger models are more precise and more stable.** They mix kinds less and file repeats together more often.
  F1 does not rise evenly with size, because the more careful models also merge less.
- **`ministral-3:14b` is the best on this hardware:** the highest F1, arrival order barely matters, and it is faster
  than `gemma4:12b`, which is as precise but 1.5 times slower.
- **Dominated models:**
  - `gemma4:e4b` and `gemma3:4b` are beaten by `gemma4:e2b` on time and grouping.
  - `qwen3.5:9b` is slow and mixes kinds.
  - `qwen3.5:4b` is very precise but splits every kind.
- **Processing time is ordered by size, except for** `gemma4:e4b`: its larger file (audio and vision encoders) makes
  it slower than `ministral-3:8b` per unit of quality.

The profiles in `pipeline.json` follow this table:

| profile | model | quality | s/doc | memory |
|---|---|---|---|---|
| `standard` | ministral-3:14b | best | 25 | ~10 GB |
| `balanced` | ministral-3:8b | same precision, less grouping | 16 | ~7 GB |
| `lowMemory` | gemma4:e2b-it-qat | fastest, mixes more | 6 | ~5.5 GB |

## Image descriptions and the model's context

An image is described by the model only when OCR finds too little text in it. Image descriptions used to be
requested without a context size, so Ollama applied its own default. Measured on the server with `gemma4:e2b`, a
description request without `num_ctx` reloaded the model at 131,072 tokens (1.9 s). The next decision, asked with
the profile's 12,288, reloaded it again (1.4 s). That is about 3 s spent on reloading per described image, and more
for larger models. Every vision request now sends the context its model is loaded with (`ResolvedModels.visionNumCtx`),
and a model that decides and describes stays loaded once.

The corpora don't show this: OCR found enough text in each of their images, so no run described one. With the change,
the three-instance forward runs took 6.2 s/doc (was 5.9) on `gemma4:e2b` and 23.7 (was 23.5) on `gemma4:12b`, with
the same grouping. These differences are within run-to-run variation.

## Limits of these results

- **Synthetic documents.** The corpora are synthetic, 21 kinds in three languages, three instances each. Real
  archives have more kinds and longer histories.
- **Unconfirmed filings.** No run included a user confirming or correcting filings, so learned rules and identifiers
  barely form. With confirmations the recurring-document step gets more trusted predecessors to follow.
- **Wrong first placements repeat.** Following a predecessor repeats its folder, including a wrong one, until the user
  moves it. One move corrects the kind for the future through the learned rules.
- **Language drift.** `gemma4:e4b` names some folders in Portuguese or Russian despite an English naming setting.
  The other models don't.
- **No image descriptions.** Every image in the corpora has enough text for OCR, so the corpora never test how well
  a model describes a photo without text.

# Evaluation: how well documents are read

How the pipeline and the model profiles are measured, and what was measured. Every number here comes from
`arrumatorcli eval` runs through the live pipeline in a throw-away archive; nothing is estimated.

## The evaluation

`arrumatorcli eval Tests/Fixtures --passes 2` files every document of the synthetic corpus in `Tests/Fixtures` through
the real pipeline and the configured models, in a throw-away home and archive, and scores each against
`expected.json` ([the corpus](../Tests/Fixtures/README.md)):

| Score | What counts as right |
|---|---|
| status | Filed, waiting for you or taken for a copy, as the corpus expects: ordinary documents are filed; the encrypted, damaged and blank files wait for you; the byte-identical copy is a duplicate. |
| type | The document type, or one the corpus also accepts. |
| sender | The sender's name contains the expected one, or one the corpus also accepts, ignoring case and accents. |
| date | The issue date, exactly. |
| title | The file name or title contains one of the words the corpus expects. |
| language | The language labels include the language the document is written in. |
| labelled | Of the documents that should be filed, the share the model labelled at all, and how many labels each has. |

Type, sender, date, title and language are scored only for documents the corpus expects to be filed. The median
time per document is reported too. A second pass files the same documents again with different bytes, which shows
what was learned about senders in the first. `--min-accuracy <x>` fails the run when the first pass reads fewer than
that share of type, sender, date and title right.

**Label quality has not yet been measured with the profile models.** The corpus records the expected sender, type,
date, title words and language, but not the subjects, objects and jurisdictions a document should be labelled with, so
the language label is the only label scored against the corpus. Adding expected labels to the generator is the next
step for this measurement.

## Image descriptions and the model's context

An image is described by the model only when OCR finds too little text in it. Image descriptions used to be requested
without a context size, so Ollama applied its own default. Measured on the server with `gemma4:e2b`, a description
request without `num_ctx` reloaded the model at 131,072 tokens (1.9 s). The next request to read a document, asked with
the profile's 12,288, reloaded it again (1.4 s). That is about 3 s spent on reloading per described image, and more for
larger models. Every vision request now sends the context its model is loaded with (`ResolvedModels.visionNumCtx`), and
a model that reads documents and describes images stays loaded once.

The corpora don't show this: OCR found enough text in each of their images, so no run described one.

## Search

Search lists the documents that contain the query's words first, then documents found by meaning alone, most similar
first. Cosine similarity gives every query nearest neighbours, so without a floor every search returned the whole
archive. `search.semanticMinSimilarity` is that floor. It was calibrated, before documents had labels, on the 36 fixture
documents filed into a scratch archive, with 51 queries in English, Portuguese and Russian: kinds of document
("electricity bill", "extrato bancário", "налоговая декларация"), senders, and six with no relevant document ("banana",
"wedding"). A document was relevant when the corpus then gave it the queried category (the corpus labelled which
documents belong together) or sender. Only documents without the query's words count, because the floor decides only
about those. Query vectors are from `bge-m3`, the embedding model of every profile.

| floor | found by meaning | relevant | precision | recall | F0.5 | queries with an irrelevant hit |
|---|---|---|---|---|---|---|
| none (before) | every document | – | 0.04 | 1.00 | – | 51 / 51 |
| 0.50 | 132 | 52 | 0.39 | 0.73 | 0.43 | 20 / 51 |
| 0.54 | 64 | 40 | 0.62 | 0.56 | 0.61 | 11 / 51 |
| **0.56** | 45 | 31 | **0.69** | 0.44 | **0.62** | 7 / 51 |
| 0.58 | 31 | 22 | 0.71 | 0.31 | 0.56 | 6 / 51 |
| 0.60 | 17 | 14 | 0.82 | 0.20 | 0.50 | 3 / 51 |

- **The floor maximises F0.5,** which weighs precision twice as much as recall: a document that doesn't belong costs
  the user more than one that is missed, which a more precise query finds.
- **Remaining misses are near:** a phone bill for "fatura de eletricidade", an income certificate for "tax return".
  None of the six queries without a relevant document finds anything by meaning.
- **For short queries, `bge-m3` similarities are compressed:** relevant documents score 0.37 to 0.67. Another
  embedding model needs its own floor.

## Earlier measurements: filing into folders

The model profiles were chosen when Arrumator filed documents into folders the archive's logic described. Those runs
scored how consistently documents of one kind were grouped into one folder (F1), on a Mac mini (M5, 16 GB) through
Ollama 0.34.4, over three-instance corpora rendered with several seeds. They no longer measure what the app does, and
are kept only because the profiles still follow them.

The profiles in `pipeline.json` follow this table:

| profile | model | F1 three-instance / standard pass 1 | P three-instance / standard | s/doc three-instance / standard pass 1 | memory |
|---|---|---|---|---|---|
| `standard` | ministral-3:14b | **0.71 / 0.55** | 0.90 / **0.89** | 25 / 39 | ~10 GB |
| `balanced` | ministral-3:8b | 0.65 / 0.46 | **0.92** / 0.86 | 16 / 29 | ~7 GB |
| `lowMemory` | gemma4:e2b-it-qat | 0.66 / 0.53 | 0.76 / 0.82 | **6 / 8.5** | ~5.5 GB |

`ministral-3:14b` grouped best at about 25 s per document, `ministral-3:8b` as precisely at 16 s, and
`gemma4:e2b-it-qat` fastest at 6 s with more mixing. Larger models do not fit such a Mac's memory. Reading a document
now takes one model call instead of up to several, so these times are upper bounds.

## Limits of these results

- **Synthetic documents.** The corpus is synthetic, 36 documents of 21 kinds in three languages and five edge cases.
  Real archives have more kinds and longer histories.
- **Labels are scored only by language.** See above.
- **No image descriptions.** Every image in the corpus has enough text for OCR, so the corpus never tests how well a
  model describes a photo without text.

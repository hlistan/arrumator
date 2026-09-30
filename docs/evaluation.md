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
| type | The `type` label is the expected type, or one the corpus also accepts. |
| sender | A `sender` label contains the expected sender, or one the corpus also accepts, ignoring case and accents. |
| date | The `date` label is the expected issue date, exactly. |
| title | The file name contains one of the words the corpus expects. |
| language | The `language` labels include the language the document is written in. |
| labelled | Of the documents that should be filed, the share the model labelled at all, and how many labels each has. |
| labels per kind | Of those labelled, the share with at least one label of each kind (`sender`, `party`, `type`, `topic`, `object`, `reference`, `date`, `period`, `deadline`, `amount`, `jurisdiction`, `language`): how much of the label set the prompt draws out. |
| expected labels | Of the other labels the corpus expects a document to get (its parties, objects, references, periods, deadlines, amounts and jurisdictions), the share it got, in all and by kind. An amount must match in number and currency; a date or period must start with the expected value; anything else must contain the expected words, ignoring case, accents and spacing. |
| sender writings | Of the senders the corpus expects on more than one document, how many ways each was written on average: 1 when every document from one sender got the same sender label. |
| distinct labels | How many different labels of each kind the documents got in all, as a label list would show them: fewer, for as many expected labels found, is a tidier vocabulary. |

Type, sender, date, title and language are scored only for documents the corpus expects to be filed. The median
time per document is reported too. A second pass files the same documents again with different bytes, which shows
how consistently they are read. `--min-accuracy <x>` fails the run when the first pass reads fewer than that share of
type, sender, date and title right.

The 21 documents of the international set (`intl/`) record the labels they should get besides their type, sender and
date. The others record only sender, type, date, title words and language, and their other labels are measured by
coverage alone.

## Results

Measured on 2026-09-30 with the `standard` profile (`ministral-3:14b`, `bge-m3`) on an Ollama server on the local
network, the full corpus, two passes. Prompt version 6 shows the model the archive's labels and your decisions about
them, and the labels it gives are tidied to the archive's ([keeping labels one
vocabulary](how-it-works.md#keeping-labels-one-vocabulary)); version 5 did neither:

| prompt | pass | status | type | sender | date | title | language | labels each | expected labels | median |
|---|---|---|---|---|---|---|---|---|---|---|
| 6 | 1 | 100% | 89% | 89% | 98% | 93% | 100% | 14.4 | 92% | 28.6 s |
| 6 | 2 | 100% | 89% | 89% | 98% | 98% | 100% | 14.6 | 93% | 31.1 s |
| 5 | 1 | 100% | 91% | 95% | 98% | 95% | 100% | 15.0 | 92% | 26.8 s |
| 5 | 2 | 100% | 89% | 93% | 98% | 95% | 100% | 15.0 | 92% | 26.8 s |

How consistent the labels are, for the same documents:

| prompt | pass | sender writings | senders | parties | topics | objects | references | jurisdictions |
|---|---|---|---|---|---|---|---|---|
| 6 | 1 | 1.25 | 49 | 26 | 63 | 105 | 97 | 26 |
| 6 | 2 | 1.25 | 49 | 29 | 55 | 103 | 97 | 26 |
| 5 | 1 | 1.38 | 53 | 37 | 91 | 121 | 84 | 39 |
| 5 | 2 | 1.50 | 52 | 38 | 86 | 123 | 83 | 38 |

Expected labels found in pass 1, by kind, are the same with both prompts: party 91%, object 91%, reference 100%,
period 75%, deadline 91%, amount 100%, jurisdiction 100%. Share of labelled documents with at least one label of each
kind, version 6 (version 5): sender 97% (98%), party 98% (98%), type 98% (98%), topic 100% (100%), object 91% (98%),
reference 91% (90%), date 98% (98%), period 79% (81%), deadline 47% (52%), amount 81% (81%), jurisdiction 98% (98%),
language 100% (100%).

The prompt is generic: its fields are defined by meaning and format, with no example values from the corpus. On the 21
international documents it reads as well as the previous prompt, whose examples came from the Portuguese and Russian
documents, which were scored the same way:

| prompt | type | sender | date | title | language | expected labels | median |
|---|---|---|---|---|---|---|---|
| version 4, examples from the corpus | 90% | 100% | 100% | 100% | 86% | 93% | 22.5 s |
| version 5, generic | 86% | 100% | 100% | 100% | 100% | 92% | 23.5 s |

What the runs showed about the prompt:

- **An example format anchors the model.** Without an example amount, the model left the currency code off most
  amounts (37% of the expected amounts found). Describing the pattern (`1234.50 XXX`, the code never left out) brought
  it to 100%, and amounts written with the code first are normalised to that form.
- **File names follow the document's language only when told to use its own words.** Asked for a description "in the
  document's language", the model translated English documents about Portugal into Portuguese. Asked to make the
  description of words that appear in the document, its title first, every English document got an English name.
- **Remaining misses:**
  - A traffic fine and a dentist's booking are typed `ticket`.
  - Two names on one line are sometimes kept as one party ("Thomas und Anna Beispiel").
  - A period is sometimes written at month precision where the document gives days.
  - A private seller's contract names both parties as senders.

### Keeping labels one vocabulary

Version 6 reads with the same number of expected labels found (92% and 93% against 92%) and gives far fewer different
labels for the same 62 documents: a third fewer topics and jurisdictions, a quarter fewer parties, and each sender
that recurs is written fewer ways (1.25 against 1.38 and 1.50). The tidying after the model's answer changed only
labels written the same way but for case or punctuation (`invoice: FS 0231/376823` became the archive's
`invoice FS 0231/376823`, `Univerzita Karlova` its `UNIVERZITA KARLOVA`); none of its changes was wrong. Each reading
takes a second or two more: the prompt is longer by the archive's labels.

The sender score is 89% in both passes against 95% and 93%. Of the three documents version 6 reads differently in
pass 1, one is read unstably by version 5 too (a passport's sender is `HMPO` in one pass and `UK Government` in the
next); in the other two the model wrote a longer form than the corpus's (`Федеральная кадастровая палата по Москве`
for `ФКП Росреестра`) or a shorter one than the one the archive already had (`ACME` beside `ACME LTD`). The regression
is accepted for what the vocabulary gains; setting `labels.vocabulary.kinds.sender.promptLimit` to 0 stops showing
the model the senders in use, if names matter more than their consistency.

What the runs showed about telling the model of the archive:

- **A list of labels in use makes the model label less, unless told it must not.** Told to "give a new label only
  for something no listed label names", it gave fewer labels of every kind (13.4 each), fewer references (86% of the
  expected), and no sender at all for three private landlords and sellers. Told instead that the lists never decide
  what to label, only how a label is written, it labelled as fully as before.
- **Naming the list inside a field forces its labels.** Adding "when the archive lists a sender label for it, give
  that label" to the sender field made the model give a listed sender that was wrong (the tax authority for a pension
  card) and drop senders it did not find listed, for five documents. The instruction stays in one paragraph after the
  fields.
- **Objects are not shown.** Almost every document has objects of its own, and listing those in use gave the model
  nothing to reuse.
- **Look Alike's thresholds.** On the labels the corpus got, every pair offered at `suggestSimilarity` was the same
  thing written two ways for objects (the same account, meter, plate or policy), parties (`M. EXEMPLE JULIEN` and
  `Julien Exemple`) and senders (`ACME LTD` and `ACME`). Topics at 0.85 offered only different subjects sharing a word
  (`property tax` and `property sale`, 0.92) or a narrower topic beside a broad one (`plumbing repair`, 0.91), which
  the prompt asks for; typos and plurals score 0.97 and above, so topics are offered from 0.94.

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

- **Synthetic documents.** The corpus is synthetic: 57 documents of 21 kinds in 18 languages and 8 scripts, and five
  edge cases. Real archives have more kinds and longer histories.
- **Expected labels on a third of the corpus.** Parties, objects, references, periods, deadlines, amounts and
  jurisdictions are checked on the 21 international documents only; on the rest they are measured by coverage.
- **No image descriptions.** Every image in the corpus has enough text for OCR, so the corpus never tests how well a
  model describes a photo without text.

# Evaluation: how well documents are read

How the pipeline and the model profiles are measured, and what was measured. Every number here comes from
`arrumatorcli eval` runs through the live pipeline in a throw-away archive; nothing is estimated.

## The evaluation

`arrumatorcli eval Tests/Fixtures --passes 2` files every document of the synthetic corpus in `Tests/Fixtures` through
the real pipeline, in a throw-away home and archive with the settings the app comes with, and scores each against
`expected.json` ([the corpus](../Tests/Fixtures/README.md)). It reads with Standard, the profile the app comes set to,
and `--profile` reads with another profile the app comes with instead, by its id (`fast`, `smart`): profiles of your
own and your changes to the predefined ones are not used, as the throw-away home has none. `--model` reads with another
model in place of the profile's reading model:

| Score | What counts as right |
|---|---|
| status | Filed, waiting for you or taken for a copy, as the corpus expects: ordinary documents are filed; the encrypted, damaged and blank files wait for you; the byte-identical copy makes no document of its own: it is right when History says it had the document of the file it copies read again. |
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

Type, sender, date, title and language are scored only for documents the corpus expects to be filed. The median time per
document is reported too, the time a document waited for Ollama included: should Ollama be away during a run, a document
waits for it, as in the app, and is read once it is back, never scored unread. A second pass files the same documents
again with different bytes, which shows how consistently they are read. `--min-accuracy <x>` fails the run when the
first pass reads fewer than that share of type, sender, date and title right. Every score is computed by `Evaluation` in
Core from what the run recorded, and `EvaluationTests` checks each on recorded outcomes, without a model.

The 21 documents of the international set (`intl/`) record the labels they should get besides their type, sender and
date. The others record only sender, type, date, title words and language, and their other labels are measured by
coverage alone.

The corpus also holds 35 pairs of labels that look alike (`label_pairs` in `expected.json`), each with how many
documents have each label, the names of some, and whether the two are one label written two ways: typos, an accent
written out, a legal form, a plural, the same number grouped otherwise, in Latin and Cyrillic scripts; and two people a
letter apart, a woman's surname beside a man's, a son beside his father, two tax offices, two banks, two
municipalities, two plates, two countries, a narrow topic beside a broad one. Five of them are held out
(`held_out`): kinds of difference the judge's prompt neither names nor shows (a word abbreviated, a small word written
otherwise, a roman numeral, a Russian name transliterated two ways), so their score says how the model judges what it
was not told of. No label of a pair, nor a word of one, is a value the prompt quotes, and no word of a pair held out is
a word of one (`LabelPairJudgeTests`). No pair is two labels written alike, which the archive keeps as one whatever its
thresholds (`Evaluation.PairCase.problem`). With the default thresholds the app would not ask about all of them: seven
are less alike than their kind's `suggestSimilarity`, which a lower one offers, and five typos of topics and countries
are as alike as their kind's `mergeSimilarity`, so a reading makes them one, which a higher one leaves to the model.
After the documents of each pass, the reading model judges every pair as the app would
([how](how-it-works.md#keeping-labels-one-vocabulary)), and the run reports the share judged right, of all and of
those held out, how many pairs it would have merged that are two labels, the costly error, how many it would have kept
apart that are one, how many it gave no valid answer for, and the median time of a judgement.
`--pairs` judges the pairs alone, reading no document. Every label of a pair is one the archive could hold, in its
kind's form, of a kind the vocabulary keeps, which `EvaluationTests` checks of the corpus.

## Results

Measured on 2026-09-30 with the `standard` profile (`ministral-3:14b`, `bge-m3`) on an Ollama server on the local
network, the full corpus, two passes. Prompt version 6 shows the model the archive's labels and your decisions about
them, and the labels it gives are tidied to the archive's ([keeping labels one
vocabulary](how-it-works.md#keeping-labels-one-vocabulary)); version 5 did neither. Version 7, measured on 2026-10-02
on the same server, tells the types apart that version 6 confused (a fine or an appointment is a letter, a card with a
social insurance number an id-document, an identity document's sender the office that issued it) and names the
identifiers it is shown in words rather than by the app's own names; version 6 measured again that day read exactly as
on 2026-09-30. Version 10, measured on 2026-10-04 on the same server with version 7 measured again first, gives
examples in each kind's form rather than descriptions the model copied as templates, lists the archive's labels as JSON
strings, names a document after the labels the user's rules keep, and is validated more closely: a sender or party
must be written by the document, an amount is a number and its currency, two labels in one are split, and a title the
document's words do not make is sent back once. Its sender score counts the full name of Russia's tax service, which
two documents print beside "ФНС России" and the model now gives, as the corpus does since. Version 11, measured on
2026-10-05 on the same server, asks for a title in sentence case even where a document prints its heading in capitals,
and sends back once, beside the title, what the document may not bear out: an object with no number in it, a date given
to a document that writes neither a date nor its year, and a reading that names two parties and no sender; the
extractor reads a date an identity card prints with spaces (`01 02 2025`). Version 12, measured on 2026-10-05 on the
same server with version 11 measured again first, reads a PDF's text layer with what a page sets apart on one line, two
columns or a label and its value, apart by a tab, and writes at once, with a note, what the document itself tells in
place of what is written otherwise than the prompt asks: a party joined to the sender's name printed beside it as the
other cell, a title in capitals as the document writes its words in a sentence, and a reference described by the
field's name printed beside it as its number; what the document does not tell goes back once:

| prompt | pass | status | type | sender | date | title | language | labels each | expected labels | median |
|---|---|---|---|---|---|---|---|---|---|---|
| 12 | 1 | 100% | 93% | 89% | 98% | 95% | 100% | 13.0 | 96% | 37.6 s |
| 12 | 2 | 100% | 95% | 89% | 98% | 95% | 100% | 13.3 | 94% | 36.7 s |
| 11 | 1 | 100% | 96% | 89% | 98% | 97% | 100% | 13.2 | 94% | 28.1 s |
| 11 | 2 | 100% | 95% | 89% | 98% | 95% | 100% | 13.3 | 93% | 32.2 s |
| 10 | 1 | 100% | 95% | 88% | 98% | 97% | 100% | 13.5 | 93% | 26.0 s |
| 10 | 2 | 100% | 93% | 88% | 98% | 97% | 100% | 13.8 | 93% | 28.3 s |
| 7 | 1 | 100% | 95% | 91% | 98% | 98% | 100% | 14.5 | 92% | 29.0 s |
| 7 | 2 | 100% | 93% | 91% | 98% | 98% | 100% | 14.5 | 91% | 31.4 s |
| 6 | 1 | 100% | 89% | 89% | 98% | 93% | 100% | 14.4 | 92% | 28.6 s |
| 6 | 2 | 100% | 89% | 89% | 98% | 98% | 100% | 14.6 | 93% | 31.1 s |
| 5 | 1 | 100% | 91% | 95% | 98% | 95% | 100% | 15.0 | 92% | 26.8 s |
| 5 | 2 | 100% | 89% | 93% | 98% | 95% | 100% | 15.0 | 92% | 26.8 s |

How consistent the labels are, for the same documents:

| prompt | pass | sender writings | senders | parties | topics | objects | references | jurisdictions |
|---|---|---|---|---|---|---|---|---|
| 12 | 1 | 1.12 | 46 | 25 | 44 | 58 | 79 | 31 |
| 12 | 2 | 1.12 | 46 | 25 | 44 | 64 | 86 | 31 |
| 11 | 1 | 1.12 | 46 | 26 | 40 | 61 | 89 | 30 |
| 11 | 2 | 1.12 | 46 | 25 | 40 | 68 | 87 | 30 |
| 10 | 1 | 1.00 | 45 | 25 | 45 | 84 | 83 | 31 |
| 10 | 2 | 1.12 | 46 | 26 | 42 | 98 | 79 | 30 |
| 7 | 1 | 1.12 | 48 | 27 | 66 | 109 | 95 | 32 |
| 7 | 2 | 1.12 | 48 | 28 | 55 | 109 | 84 | 30 |
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

What version 10 changed, against version 7 measured the same day: type, date and language read the same; the
expected labels rose from 92% and 91% to 93% in both passes, periods from 75% to 94% and 88%; the vocabulary is
tidier, with a third fewer topics and a fifth fewer objects, as an object or reference is no longer written as a field
and its value ("account and its number: 123456780" is now "account 123456780"). Sender fell from 91% to 88%: both
leases and contracts of the corpus now name their two signatories as parties and no sender, though the prompt says the
party that issues one is its sender; read alone, outside the evaluation's archive, the lease gets its landlord as
sender. Title fell from 98% to 97%, on an e-mail written in Portuguese and English, now titled in Portuguese.

What version 11 changed, against version 10: type rose from 95% and 93% to 96% and 95%, as a vehicle registration
renewal is now a letter; sender from 88% to 89% in both passes, as the lease, sent back for naming its two sides as
parties and no sender, now names its landlord; date stayed at 98%; the expected labels rose to 94% and 93%. A third
fewer objects are written (61 and 68, from 84 and 98), as a job title or a receipt's groceries go back and are left out,
while the objects the corpus expects are found as often or more (91% and 100%, from 91% and 91%). Title fell in pass 2
from 97% to 95%, one receipt whose heading "FATURA-RECIBO" the model wrote "Fatura-receito" when turning it to sentence
case. Sending back costs time: the median rose by 2 s in pass 1 and 4 s in pass 2, where the archive's labels make each
prompt longer. Two earlier runs of version 11 showed what to send back. The first checked a date against the days the
extractor read, and sent back the issue date of a residence card that prints it with spaces, which the extractor did
not read: the model then gave none, and date fell to 96%; only whether the document writes a date or its year is
checked since, and the extractor reads such dates. The second sent back a home policy's address, "Calle del Ejemplo
7", for its house number of one digit, and the model left it out in both passes; a number standing alone beside a name
identifies an object since.

What version 12 changed, against version 11 measured again the same day, whose first pass read as version 11 had and
whose second lost a document to a restart of the server: the expected labels rose from 94% to 96% in pass 1, and to 94%
in pass 2, where version 11 had 93% when first measured, parties from 86% to 91% and objects from 91% to 100% in pass 1,
as a value no longer runs into the label beside it, and a reference no longer holds the field's name printed beside it,
which leaves 79 different references rather than 89; sender, date and language read the same. Type fell from 96% to
93% in pass 1, as two documents got another type from text that now sets its fields apart: a vehicle registration
renewal, whose table lists a "Vehicle license fee", is a `license` rather than the `letter` the corpus accepts, in both
passes, and a social security number's proof is a `certificate` rather than an `attestation` in one pass, as version 11
read it in its second. Title fell from 97% to 95%, one licence certificate titled after its subscription, "Toolbox
Subscription", rather than its product, "All Products Pack", in both passes; the pharmacy receipt version 11 titled
"Fatura-receito" in its second pass is "Fatura-recibo" in both. The medians, measured while the server read for other
clients too, are not compared.

What the runs showed about the prompt:

- **An example format anchors the model, and a described one is copied.** Without an example amount, the model left
  the currency code off most amounts (37% of the expected amounts found). Describing the pattern (`1234.50 XXX`)
  brought it to 100%, but a description is copied as a template too: "an account and its number" became labels written
  "account and its number: 123456780". Version 10 gives values in each kind's form instead (`54.21 EUR`, `account
  0012345678`), and `LabelFormTests` keeps every example a label its kind keeps.
- **A title example in one language is copied in that language.** One Portuguese example made English documents get
  Portuguese titles; examples in three languages, and sending back a title the document's words do not make, keep each
  title in its document's language.
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
- **The thresholds of what looks alike.** On the labels the corpus got, every pair offered at `suggestSimilarity` was
  the same thing written two ways for objects (the same account, meter, plate or policy), parties (`M. EXEMPLE JULIEN`
  and `Julien Exemple`) and senders (`ACME LTD` and `ACME`). Topics at 0.85 offered only different subjects sharing a
  word (`property tax` and `property sale`, 0.92) or a narrower topic beside a broad one (`plumbing repair`, 0.91),
  which the prompt asks for; typos and plurals score 0.97 and above, so topics are offered from 0.94.

### Labels that look alike, judged by the model

The judgement was measured on 2026-10-08 with `arrumatorcli eval Tests/Fixtures --pairs --passes 2 --model <model>`,
on the 35 pairs of the corpus, 5 of them held out. None of the three profiles' reading models was installed on the Mac
the measurement ran on, and none was downloaded for it, so the models at hand were measured: one larger than
Standard's of the same family, one of Smart's family, and one as small as Fast's; and `gemma4:latest`, of Fast's family,
with the documents of the run that measured interpretations ([below](#what-the-model-says-a-document-is)). Both passes
judged every pair alike.

| Model | Judged right | Held out right | Merged wrongly | Kept apart wrongly | Median |
|---|---|---|---|---|---|
| `qwen3:8b` | 97% | 5 of 5 | 0 | 1 | 2.9 s |
| `gemma3:4b` | 91% | 5 of 5 | 0 | 3 | 2.3 s |
| `mistral-small3.2:24b` | 94% | 4 of 5 | 2 | 0 | 7.1 s |
| `gemma4:latest` | 91% | 5 of 5 | 2 | 1 | 1.8 s |

Every model judged the Russian name transliterated two ways, held out, one person (`Aleksandr Volkov` and
`Alexandr Volkov`). The medians were measured while the Mac also built and tested, and are not compared.

What was learned on the way to the prompt:

- **Describe a difference by what it is, not how it looks.** The first prompt said that two people may differ by a
  letter; `qwen3:8b` then judged every typo two labels ("they differ by a single letter, indicating two different
  people"), 57% right with no wrong merge and no merge at all. Asking it first to find what differs, and then whether
  that is a slip in writing one name or another name spelt right in both, took it to 93%.
- **A rule the model reads as one sentence it misreads.** The rules of "different" written as one long sentence led
  `mistral-small3.2:24b` to call `Maria` a misspelling of `Mario` and merge six pairs wrongly (80%); the same rules as
  short lists, one kind of difference to a line, gave 91%.
- **What it gets wrong is a first name that is a name of its own.** `mistral-small3.2:24b` merged `Julie Exemple`
  into `Julien Exemple` with every prompt, calling it "likely a gender difference" though the prompt names a man's and
  a woman's form of a name two people, and, of the held-out pairs, a roman numeral (`Canal de Isabel III` and
  `Canal de Isabel II`). Smaller models rather keep a pair apart that is one: a legal form, a misspelt word beside a
  number, the same number grouped otherwise.

### Fast

Fast's labels were first measured on 2026-10-05, on the same server and corpus, with the `fast` profile
(`gemma4:e2b-it-qat`, `bge-m3`): version 11 first, then version 12, which was made for what the QA run of that day
found in Fast's readings.

| prompt | pass | status | type | sender | date | title | language | labels each | expected labels | median |
|---|---|---|---|---|---|---|---|---|---|---|
| 12 | 1 | 100% | 84% | 88% | 86% | 95% | 98% | 14.8 | 69% | 10.4 s |
| 12 | 2 | 100% | 88% | 84% | 88% | 93% | 97% | 14.9 | 69% | 9.5 s |
| 11 | 1 | 100% | 88% | 86% | 86% | 93% | 97% | 14.9 | 66% | 9.1 s |
| 11 | 2 | 100% | 88% | 84% | 88% | 93% | 97% | 15.3 | 68% | 8.2 s |

Fast reads a document in about a quarter of Standard's time and finds fewer of the labels a document should get, 69%
against 96%: most jurisdictions are missed (17%), and a third of the periods and amounts. Version 12 raised the parties
found from 86% to 95% in both passes, as a party no longer joins the sender's name printed beside it; titles written in
capitals fell from 14 of the 124 readings to 10, those of five documents that write their heading only in capitals,
whose title goes back once and stands as given again, as only the document could say its small letters; and a reference
described by the field's name printed beside it is its number ("póliza 061-2026-1596647" is "061-2026-1596647"). Type
fell from 88% to 84% in pass 1, a French tax notice read as a `tax-return` and a Russian land register extract as an
`id-document`, and read as version 11 did in pass 2. References found fell from 86% to 71% in pass 2: an invoice whose
number Fast describes in the document's own Polish words, which the document runs into the number ("Faktura VAT nr
F/11104/06/2026"), goes back once, and Fast, asked again, gave the same reference in pass 1 and left it out in pass 2.
A booking confirmation got its sender, its title and its language right in pass 1, which version 11 had not. The
medians, measured while the server read for other clients too, are not compared.

### Smart

Smart reads with the strongest model, by its benchmarks, that a 16 GB Mac holds whole, however long it takes. It was
first measured on 2026-10-07 and
2026-10-08, on the same server, a Mac mini (M5, 16 GB) through Ollama 0.34.4, with prompt version 12 and the `smart`
profile: `qwen3.5:9b`, the model it came with, whose weights are stored in about 4 bits each (`Q4_K_M`), and
`qwen3.5:9b-q8_0`, the same model in 8 bits, which it reads with since.

| model | pass | status | type | sender | date | title | language | labels each | expected labels | median |
|---|---|---|---|---|---|---|---|---|---|---|
| qwen3.5:9b-q8_0 | 1 | 100% | 93% | 91% | 96% | 95% | 100% | 13.6 | 94% | 28.9 s |
| qwen3.5:9b-q8_0 | 2 | 100% | 95% | 88% | 98% | 95% | 100% | 13.6 | 93% | 29.3 s |
| qwen3.5:9b | 1 | 100% | 88% | 95% | 100% | 93% | 100% | 14.5 | 92% | 22.1 s |
| qwen3.5:9b | 2 | 100% | 89% | 95% | 100% | 95% | 100% | 14.6 | 91% | 23.0 s |

No model larger than Standard's fits such a Mac: Ollama gives a model about 10 GB of its memory to run on, and
`ministral-3:14b` already runs 0.8 GB of its 10.6 GB on the processor. Of the models with vision and thinking that fit,
one pass over the 21 international documents on 2026-10-07 (while the server also read for another client, so the
medians are not compared) read so, with the memory Ollama gave each with the app's context and how much of it ran on
the graphics processor (`/api/ps`), which counts the context too, so Standard's 10.6 GB is the ~10 GB measured
[below](#earlier-measurements-filing-into-folders) with its context:

| model | type | sender | date | title | expected labels | memory, all on the GPU |
|---|---|---|---|---|---|---|
| qwen3.5:9b-q8_0 | 95% | 95% | 100% | 100% | 93% | 10.4 GB, yes |
| ministral-3:14b (Standard) | 90% | 95% | 100% | 100% | 96% | 10.6 GB, 9.8 GB of it |
| gemma4:12b | 90% | 100% | 100% | 100% | 92% | 8.1 GB, yes |
| qwen3.5:9b | 95% | 100% | 100% | 100% | 90% | not read |

Qwen3.5 9B is the strongest of these on the benchmarks its makers and others report, GPQA Diamond 81.7 and MMLU-Pro
82.5, against 78.8 and 77.2 for Gemma 4 12B and 71.2 on GPQA Diamond for Ministral 3 14B reasoning
([XDA](https://www.xda-developers.com/qwen-3-5-9b-tops-ai-benchmarks-not-how-pick-model/),
[LLM Stats](https://llm-stats.com/models/compare/gemma-4-12b-it-vs-qwen3.5-9b),
[Ministral 3](https://arxiv.org/pdf/2601.08584)), and 8-bit weights (`Q8_0`) are the quantization closest to the
model's own, far closer than 4 bits ([llama.cpp perplexity](https://qwen.readthedocs.io/en/stable/quantization/llama.cpp.html)).
On the corpus, the two read alike within a few documents: in 8 bits, type rose from 88% and 89% to 93% and 95%, the
expected labels from 92% and 91% to 94% and 93%, periods from 69% to 81%, with a quarter fewer objects and a tenth
fewer references written; sender fell from 95% to 91% and 88%, date from 100% to 96% and 98%, and one sender was
written two ways (1.12 writings each, from 1.00), as Standard writes one. Against Standard it reads type as well,
sender and date within two documents, and finds a little fewer of the expected labels, 94% and 93% against 96% and 94%.
The medians, measured while the server may also have read for other clients, are not compared. How well it reads a
search task's request, which it thinks before answering, the corpus does not measure.

## Image descriptions and the model's context

Every image is described by the vision model, however much text OCR finds in it, since each document's sidecar says
what an image shows ([what is kept beside a document](how-it-works.md#what-is-kept-beside-a-document)). Earlier
versions described one only when OCR found too little text to tell what it was, so a screenshot or a photographed
receipt was read by its text alone; describing it costs one request to the vision model more for each such image, as
long as a photo without text took already. Image descriptions used to be requested without a context size, so Ollama
applied its own default. Measured on the server with `gemma4:e2b`, a
description request without `num_ctx` reloaded the model at 131,072 tokens (1.9 s). The next request to read a
document, asked with 12,288, reloaded it again (1.4 s). That is about 3 s spent on reloading per described image,
and more for larger models. Every vision request now sends the context documents are read with, `analysis.numCtx`
(12,288), so a model that reads documents and describes images stays loaded once.

Until every image was described, the corpora did not show this: OCR found enough text in each of their images, so no
run described one.

## What the model says a document is

Each reading ends with what the model says the document is, its interpretation, which its sidecar holds beside it, and
every image is described by the vision model, not only one whose text is too sparse to tell what it is
([what is kept beside a document](how-it-works.md#what-is-kept-beside-a-document)). Measured on 2026-10-08 with
`arrumatorcli eval Tests/Fixtures --passes 2 --model gemma4:latest`, as the server at hand had none of the profiles'
models, against the same command on `main` before the change (cca2dc2), with `--model` describing images too, as it
now does. The run after the change was made on the branch that also carries the editing of labels and documents, which
changes no prompt the reading uses.

| | Before, pass 1 / 2 | After, pass 1 / 2 |
|---|---|---|
| Type | 81% / 84% | 86% / 86% |
| Sender | 88% / 88% | 86% / 86% |
| Date | 96% / 96% | 98% / 98% |
| Title | 93% / 91% | 93% / 91% |
| Language label | 100% / 100% | 100% / 98% |
| Type, sender, date and title together | 89.5% / 90.0% | 90.8% / 90.4% |
| Expected labels found | 93% / 93% | 93% / 91% |
| Labels per document | 14.1 / 14.3 | 13.7 / 13.9 |
| Said what it is | — | 100% / 100% |
| … in the document's own language | — | 95% / 98% |

Every document to be filed was given an interpretation, in its own language but for three of the first pass and one of
the second, whose interpretation was in no language the corpus gives them: a photo of a Russian pension certificate,
said in English, an appointment e-mail written in Portuguese and English, and a Korean hospital receipt, in both passes.
The images described now that were not before read better: the photo of a residence permit got its type and its date,
and the photo of the pension certificate its type, in both passes. What read worse is one document each: a contract of
sale gave its seller as a party rather than as its sender in both passes, so its name lost its sender; and in the second
pass alone, a passport scan was dated by its expiry, and one period, one deadline and one language label were missed, as
two passes of one build differ by (type 81% and 84% before). The medians, measured while the Mac also built and tested,
are not compared; describing every image costs one request to the vision model more for each image with text.

## Search

Search lists the documents that contain the query's words first, then documents found by meaning alone, most similar
first. Cosine similarity gives every query nearest neighbours, so without a floor every search returned the whole
archive. `search.semanticMinSimilarity` is that floor. It was calibrated, before documents had labels, on the 36 fixture
documents filed into a scratch archive, with 51 queries in English, Portuguese and Russian: kinds of document
("electricity bill", "extrato bancário", "налоговая декларация"), senders, and six with no relevant document ("banana",
"wedding"). A document was relevant when the corpus then gave it the queried category (the corpus labelled which
documents belong together) or sender. Only documents without the query's words count, because the floor decides only
about those. Query vectors are from `bge-m3`, the embedding model of every profile the app comes with.

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

Fast and Standard were chosen when Arrumator filed documents into folders the archive's logic described. Those runs
scored how consistently documents of one kind were grouped into one folder (F1), on a Mac mini (M5, 16 GB) through
Ollama 0.34.4, over three-instance corpora rendered with several seeds. They no longer measure what the app does, and
are kept only because those two profiles still follow them. `ministral-3:8b` was a profile of its own then
(`balanced`); the app no longer comes with it, and its row is kept only as a measurement, for a profile of your own.
Smart came after these runs: it is measured [above](#smart).

| profile | model | F1 three-instance / standard pass 1 | P three-instance / standard | s/doc three-instance / standard pass 1 | memory |
|---|---|---|---|---|---|
| Standard | ministral-3:14b | **0.71 / 0.55** | 0.90 / **0.89** | 25 / 39 | ~10 GB |
| none (`balanced` before) | ministral-3:8b | 0.65 / 0.46 | **0.92** / 0.86 | 16 / 29 | ~7 GB |
| Fast | gemma4:e2b-it-qat | 0.66 / 0.53 | 0.76 / 0.82 | **6 / 8.5** | ~5.5 GB |

`ministral-3:14b` grouped best at about 25 s per document, `ministral-3:8b` as precisely at 16 s, and
`gemma4:e2b-it-qat` fastest at 6 s with more mixing. Larger models do not fit such a Mac's memory. Reading a document
now takes one model call instead of up to several, so these times are upper bounds.

## Limits of these results

- **Synthetic documents.** The corpus is synthetic: 57 documents of 21 kinds in 18 languages and 8 scripts, and five
  edge cases. Real archives have more kinds and longer histories.
- **Not every prompt with every profile.** Standard is measured with every prompt version, Fast with versions 11 and
  12, Smart with version 12 alone.
- **Expected labels on a third of the corpus.** Parties, objects, references, periods, deadlines, amounts and
  jurisdictions are checked on the 21 international documents only; on the rest they are measured by coverage.
- **No image descriptions.** Every image in the corpus has enough text for OCR, so the corpus never tests how well a
  model describes a photo without text.

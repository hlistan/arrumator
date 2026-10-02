# How Arrumator works

This is how Arrumator reads a document, labels it, names it and files it. [Using Arrumator](using-arrumator.md)
covers the app and its settings. [Storage](storage.md) covers where everything is kept, and
[Evaluation](evaluation.md) the measurements behind these choices.

## How a file is handled

```text
new file in Incoming ──► wait until it stops changing ──► tagged by the folder in Incoming it is in, if any
   ──► hash (an exact copy of a document in the archive has that document read again instead: below)
   ──► extract: PDFKit text, Apple Vision OCR, textutil (doc/docx/rtf/odt/html), CoreXLSX, PPTX, e-mail,
       archives, media metadata, Quick Look previews, local vision model for photos; language, dates, identifiers
   ──► analyse: the local model reads it once, with the app's own prompt and the archive's labels, picks out its
       signals, which become its labels, and names the file; your rules and the archive's vocabulary tidy the labels
   ──► file it at the top of the archive under that name, keeping the original name in an extended attribute, and
       add it to the search index (its words, its labels and its meaning)
```

Files are handled one at a time, in the order they arrived. Each stage's result is kept as soon as the stage is done,
so a file stopped part way, because you quit Arrumator, the Mac shut down or the app crashed, carries on from its last
finished stage at the next start, before any file that arrived after it. Quitting first stops the stage in hand, waiting
for it at most `ingest.quitTimeout` seconds; a file being moved into the archive is always moved and recorded together.
A file whose stage failed is tried again after `ingest.retryDelays`, holding up none of the files behind it meanwhile,
and then takes its place by when it arrived. Documents read again after a rebuild of the index wait until no new file
does; one you have the model read meanwhile, with **Read Again** or a copy of it in Incoming, is read by the model in
its turn instead, which reads its text too.

A document is described by its labels and nothing else: who sent it, what type it is, its date, whom and what it
concerns, and the rest are all labels of one kind or another. The archive has no folders of the app's making. Every
document is filed at its top and found again by its labels, its words or its meaning. A folder you make yourself is
yours: the app reads files you put in it where they are, and never moves them out. A folder you put into Incoming is
yours too, and gives what is in it a label of yours, a tag ([below](#folders-in-incoming-and-tags)).

### Documents in any language

Nothing in reading a document is tied to a language. The extractor tells the language of the text among all that
Apple's NaturalLanguage knows. Its dates are found with month names in every language the system has a calendar for,
in each form it writes them (`15 мая 2024`, `3. März 2025`, `2025年3月5日`), and in numeric forms from day first to
year first. OCR asks Vision for the document's own language first, then the hints in `extraction.ocrLanguages`, and
lets Vision detect any other it reads. A script Vision does not read in images is still read from a PDF's text layer,
an e-mail or a text file. The model reads the document as written and describes it in labels that do not depend on its
language: names and numbers as the document writes them, topics, objects and jurisdictions in English, dates, amounts
and
languages in ISO forms. Documents in different languages are therefore found by the same labels. The file name's
description is in the document's own language.

OCR runs on Vision's default device, the Neural Engine or GPU. When that fails, as it can when the Neural Engine's
model does not compile, the page is read again on the CPU, and so is every later page until the app restarts. The
document's trace records which device read each page.

## Reading a document

The model reads each document once: the reading model of the profile Settings uses
([profile and effort](#profile-and-effort)), with a prompt of the app's own (`labels-system.md`), which you do not
edit. A model that can stop thinking is told not to think first (`analysis.think`), as the one that describes images
is, and it reads with a context of `analysis.numCtx` tokens, the one images are described with too, so a model that
does both stays loaded once. It is
given the document's text (an excerpt of `analysis.excerptChars` characters) and the dates and identifiers the
extractor found, after what the archive's labels say ([below](#keeping-labels-one-vocabulary)), and it answers in a
fixed schema: one list of signals for each kind of label, then the file name.
Under constrained decoding the model writes the lists in the schema's order, so the facts a file name is made of come
first (the sender, the type, the date) and the name last, built from them as `YYYY-MM-DD Sender - Description`, in the
document's language.

The answer is untrusted input. It is decoded into typed values and checked, each label as described below; an answer
that cannot be read, or leaves a list out, goes back to the model with what was wrong (`analysis.repairAttempts` times),
and one cut off at its length limit (`analysis.llmOptions.numPredict` tokens) goes back saying so. No other model is
asked after it: a document it never answers validly waits for you ([below](#documents-that-wait-for-you)). The file name
goes through the same cleaning every file name does: no path separators or other characters `naming.forbiddenCharacters`
lists (one between words, as in "Fatura: julho", becomes " - ", one inside a word or number a "-"), bounded length,
and, when Settings says so, transliterated.

## Labels

The model picks out the document's *signals*, the facts someone looking for it later would search by, and each one
becomes a label of one of the first twelve of these kinds. The last, `tag`, is yours: the model is never asked for one.

| Kind | What it holds | Value |
|---|---|---|
| `sender` | Who issued or sent the document: the company, authority, institution or person on its letterhead or signature. | As the document writes it. |
| `party` | Another person or organisation it concerns: whom it is addressed to, whose it is, whom it is about. | As the document writes it, without titles. |
| `type` | The form of the document. At most one. | One of invoice, receipt, statement, contract, tax-return, tax-assessment, payslip, certificate, attestation, id-document, letter, application, policy, medical-report, prescription, ticket, license, manual, quote, legal. A document none fits has none. |
| `topic` | A subject area it belongs to, from broad to specific: utilities, electricity; taxes, income tax. | One to three lowercase English words. |
| `object` | A specific thing it concerns, with what identifies it: an apartment and its address, a car and its plate, a supply point, an account, a policy. | A short English noun phrase and the identifier as written. |
| `reference` | A number that identifies the document or the matter it belongs to: an invoice, contract, case, customer or order number. | What it is and the number: `invoice FT 2026/926804564`. |
| `date` | When it was issued. At most one. | `YYYY-MM-DD`. |
| `period` | The period it covers: a billing month, a tax year, a statement period, a policy term. | `YYYY`, `YYYY-MM` or a day, or two of them as `start/end`. |
| `deadline` | A date by which something must be done, or on which something ends: payment due, expiry, renewal, an appointment. | `YYYY-MM-DD`. |
| `amount` | A total it asks for or records: the total due or paid, a net salary, a premium. | A number and an ISO 4217 currency: `54.21 EUR`. |
| `jurisdiction` | A country, region or city whose law, authority or administration it falls under: where a tax is due, a contract is governed, an ID was issued. | In English: `Portugal`. |
| `language` | A language it is written in, the main one first. | An ISO 639-1 code: `pt`. |
| `tag` | Your own label: the name of the folder in Incoming it was put in ([below](#folders-in-incoming-and-tags)), or one you give it. Never the model's. | As you write it, case and all: `Taxes 2024`. |

The kinds follow the metadata archival description keeps for a record (DCMI's creator, subject, coverage, issued,
temporal, valid, type, identifier and language; ISO 23081's agents), the facets of faceted classification, and the
fields document managers and key-information extraction read from personal paperwork; a tag is a label you give, as
the tags of a personal collection are ([sources](organizing-principles-sources.md#sources-for-labels)).

Every label is kept on one line, cut to `labels.maxValueChars` after the last whole word, and kept once however it is
written. Each kind keeps its first `labels.maxPerKind` labels, the most significant first; a document has at most one
type and one date. A value that is no label of its kind is dropped rather than sent back: a date or deadline that is no
calendar day (day-first dates such as `31.07.2026` become ISO), a period of another shape, an amount or a reference
without a number, a language that is none (one written `pt`, `por` or `Portuguese` becomes `pt`). An amount written
with its currency code first or after a colon (`EUR 54.21`, `54.21: EUR`) becomes `54.21 EUR`. Topics are lowercase.

Labels are the document's. They sit in its entry in `_documents.md` and survive a rebuild, and each kind is a field of
the search: `sender:edp`, `party:"maria silva"`, `type:invoice`, `object:AA-12-BB`, `reference:926804564`,
`deadline:2026-07`, `amount:54.21`, `jurisdiction:portugal`, `language:portuguese` (a language is found by its code and
by its English name), `tag:"taxes 2024"`. A plain search finds labels too. A document's card lists them by kind. The
app's sidebar lists them too: choosing labels there narrows the documents to those that have every one, and the labels
offered to those the documents left have ([using Arrumator](using-arrumator.md#what-the-app-shows-you)). A chosen label
is matched however it is cased, accented or punctuated. The documents chosen are listed by their own date, the `date`
label of the day they were issued, not by when they were added or filed: the newest first, those of one day by name, and
those without a date last.

When the model finds nothing worth a label, the document is labelled with nothing, which is not the same as not
labelled. A document the model has not labelled has no labels, or only its tags, which label nothing; it is labelled
when it is read again: `arrumatorcli review retry <document>` for one, `arrumatorcli labels unlabelled` for all of them.

### Correcting labels

Every label can be changed. On a document's card, a label is taken off with its ×, and one is added by choosing its kind
and writing its value; from a terminal, `arrumatorcli labels <document> --add sender=EDP --remove topic=energy`, or
`--add tag="Taxes 2024"`. Your labels are kept as the model's are: a date must be a date and a type one of the list. A
label of a kind the model gives labels a document the model has not labelled, so `labels unlabelled` no longer reads it;
a tag does not. A document keeps one type and one
date: on the card a new one replaces the old; from a terminal, remove the old one in the same command (`--remove
type=invoice --add type=receipt`). Each correction is recorded in History. Renaming the document (on its card, or
`review rename`) renames the file where it is.

## Keeping labels one vocabulary

Labels are only as good as they are consistent: a document labelled `EDP Comercial` is not found under `EDP`, and a
topic written two ways splits what belongs together. This is the synonymy problem of every tagging system
([sources](organizing-principles-sources.md#sources-for-keeping-labels-one-vocabulary)). Arrumator keeps the archive's
labels one vocabulary in three ways, and learns from you as it goes.

**The model is shown the archive's labels.** Every document is read with a section of the prompt
(`archive-labels.md`) that lists the labels the archive already uses, the most used first, for the kinds
`labels.vocabulary.kinds` names (`promptLimit` of each), how you asked labels to be written (your merges, the newest
`labels.vocabulary.promptPreferred`) and the labels you do not want (the newest `labels.vocabulary.promptUnwanted`). The
lists never decide what the model labels, only how: when the document's sender, a party, a topic or a jurisdiction is
one the archive has a label for, the model gives that label as listed rather than another writing of the same name.
Objects and references are not listed, as nearly every document has its own, and neither are your tags nor your rules
about them, as the model never gives a tag. That is how your decisions teach the model: by showing it examples in its
prompt, without retraining it, so what it learns stays in your archive and follows you to another model.

**Every label the model gives is tidied.** Your rules come first: a label you merged is written as you want it,
following one merge into the next, and one you do not want is dropped. Then a label of a kind the vocabulary keeps
(sender, party, topic, object, reference, jurisdiction) becomes the label the archive already uses when the two are
written alike enough: `labels.vocabulary.kinds.<kind>.mergeSimilarity`. At 1, the default for names, objects and
references, only labels written the same way but for case, accents, punctuation, spacing and word order are one
(`EDP-Comercial, S.A.` is `EDP Comercial SA`); for topics and jurisdictions a typo is forgiven too (`electricty`). How
alike two labels are written is their Jaro-Winkler similarity, the measure record linkage uses for names, over their
words in sorted order; labels whose numbers differ are never alike. A label the archive already uses stays itself,
unless more documents have it written another way. Only writing is compared, never meaning: that one label means
another in other words is the model's judgment, or yours. What was changed, and by which rule, is in the document's
trace (the `consolidate` step) and its History entry.

**Your tags are your words.** A tag is never made another because one in use is written alike, nor offered under Look
Alike: `Taxes-2024` stays `Taxes-2024` beside a `Taxes 2024` more documents have, until you merge the two. Only your
rules apply to a tag, when its folder gives it (the `tag` step of the trace) and from then on, as to any label. So the
vocabulary keeps no tags: the app refuses to start with a `tag` entry under `labels.vocabulary.kinds`, or among an
effort's `promptLabels`, saying so.

**What is merely alike waits for you.** Labels in use written alike enough to be one
(`labels.vocabulary.kinds.<kind>.suggestSimilarity`), but not enough to merge without asking, such as two names a
letter apart, are listed under **Look Alike** on the Labels page, the most alike first, at most
`labels.vocabulary.suggestionLimit`. The sidebar shows how many wait.

What you decide becomes a rule, recorded in History and kept in the archive (`System/_labels.md`,
[Storage](storage.md)):

- **Merge** a label into another: every document that has it, written however, gets the other instead, and so does
  every document read from then on. Merging back the other way replaces the first merge, and labels merged into the one
  you merge follow it.
- **Remove everywhere** (ignore) a label: it is taken off every document, and the model's answers lose it from then on.
- **Keep apart** two alike labels: they are never merged and never offered to merge again.
- **Forget** a rule: documents read from then on no longer follow it. Documents it already changed keep their labels.

On the Labels page, open a label to merge it or remove it everywhere, open a pair under Look Alike to merge it either
way or keep it apart, and forget a rule under What You Decided. A label's menu on a document's card opens it there, or
removes it everywhere. From a terminal: `arrumatorcli labels merge`, `ignore`, `keep-apart`, `similar`, `rules` and
`forget` ([command line](cli.md)). Rules are about writing, so they apply to labels of every kind; the page lists the
kinds the vocabulary keeps, and your tags, as the others have one form each.

## Folders in Incoming and tags

Put a folder into Incoming, such as `Taxes 2024` with a year's tax papers in it, and every document in it, at any
depth, is filed with the folder's name as a label of yours, a **tag**, beside the labels the model gives it. The name
is kept as the folder is named on disk, on one line, cut at `labels.maxValueChars` as every label is, and is never
lowercased or translated. The model is never asked for a tag and never shown one, so how it reads a document does not
change.

- **What names a tag**: only the folder at the top of Incoming. Folders inside it give nothing, so
  `Incoming/Taxes 2024/Q1/receipt.pdf` is tagged `Taxes 2024` alone, and a file directly in Incoming gets no tag. A
  package, a folder macOS shows as one document (an `.rtfd`, a Pages document), is a document and names nothing, and
  so does a folder the watcher ignores, such as a hidden one. A folder you make inside the archive is no folder in
  Incoming: a file you put there is read where it is, without a tag ([your own changes](#your-own-changes)).
- **When**: the tag is decided when the file is queued, from where it is in Incoming then, and kept with it in the
  queue, so Incoming shows it under the file's name before the file is read, and a stop or a restart keeps it. A folder
  moved into Incoming whole is looked through, and each file in it is queued once it stops changing.
- **The folder stays.** Its files are filed into the archive as any are, and the folder is left where it is, even
  empty. The app never moves, renames or removes it, so it is a place to drop files into: what you put there later is
  tagged too.
- **The document has the tag at once**, before the model reads it, as the trace's `tag` step says, with the folder
  that gave it; your rules apply to it then. The arrival in History and the reading's entry say it too (`tagged “Taxes
  2024” by its folder in Incoming`).
- **A document the model cannot read** keeps its tag and waits for you in Needs You all the same. It counts as not
  labelled, as a tag labels nothing: `arrumatorcli labels unlabelled` and Statistics count it so, and reading it again
  labels it, keeping the tag. `arrumatorcli ingest <file> --tag <tag>` gives a file a tag of your choosing too, besides
  its folder's.
- **Reading a document again keeps its tags**, the folder's and those you gave it, while what the model gives replaces
  what it gave before (and the labels of other kinds you gave it by hand with them).
- **An exact copy** of a document in the archive, put into the folder, gives that document the folder's tag and has it
  read again ([exact copies](#exact-copies)), so the document itself is found under the tag, by the sidebar, a search
  task and its exports alike. The copy goes to the Trash.

A tag is found as any label: in the sidebar, kind by kind under **Tags** in grey, by `tag:"taxes 2024"` from a
terminal, and as a level a search task's set is arranged and exported by (`arrumatorcli tasks update <task> --group-by
tag`), a folder per tag. A task's request is never read as asking for one: add the documents with a tag to its set
(`tasks add <task> --label tag="Taxes 2024"`).

## Documents that wait for you

A document is filed however it was read, but some wait for you in **Needs You**, in the archive, with the reason on
their card:

- the model gave no valid answer, even after being told what was wrong (the document has no labels but its tags);
- the file is encrypted or damaged;
- no text could be read from it, and no image description either, as with a blank scan.

A document that waits keeps its own name: what the model read of it is in doubt. Confirm one as it is
(**Looks Right**), correct its name or labels, or have it read again. A file that keeps failing to be processed at all
(`ingest.maxAttempts`) is parked in the archive the same way, with status failed, so Incoming stays clean and nothing
is lost.

While Ollama cannot be reached a document waits where it stopped, and a missing model holds it until the model is
downloaded; neither costs it an attempt.

## Exact copies

A file in Incoming with the same bytes as a document in the archive (filed, waiting for you, parked after failing or
left for later), by its SHA-256 and by that document's file as it is on disk now, is no second document: it asks for
that document to be read again. This is how you have documents read with another profile
([profile and effort](#profile-and-effort)): choose it, and put the documents into Incoming again, as they are.

- **The document is read again from the start**, with the profile in use: its text is read from its file again, images
  described by the profile's vision model, then the model reads it, it is renamed where it is under the name it gives,
  and the search index takes what it reads now, its words, labels and meaning. It is queued behind the files already
  waiting, and shows in Incoming while it waits. Reading with the model takes the place of having only its text read
  again after a rebuild of the index.
- **It keeps its tags**, the folders' and those you gave it, and a copy put into a folder in Incoming, or given `--tag`,
  gives it those tags at once, before it is read; what the model gives replaces what it gave before.
- **The copy goes to the Trash**, never deleted, as the archive holds the same bytes; take it back from there. A copy
  the
  Trash will not take, as on a volume without one, stays in Incoming, and the document is not read again: the copy is
  tried again (`ingest.maxAttempts`) and then recorded as failed, saying why.
- **History records it once, under the document**: `bill.pdf is a copy of 2026-07-05 EDP Comercial - Fatura.pdf, which
  is read again; the copy is in the Trash; tagged “Taxes 2024” by its folder in Incoming`, with where the copy was and
  went. The trace of the copy's arrival (`hash`, `dedupe` with the document it copies, `tag`) is the event's; the
  reading that follows is the document's own.

A file whose bytes the archive no longer holds, because the document's file was changed or removed since it was filed,
is a new document, and so is a file you put into the archive yourself, even a copy: it is yours, read where it is.
A copy that earlier versions filed beside its original, marked as a copy, stays as it is; a new copy reads the
original again, not it.

## Your own changes

Moving or renaming a document in Finder is followed: the app finds the file by the identifier it stores on it and
records the move in History. A file you put into the archive yourself, at the top or in a folder of yours, is read and
labelled where it is, under its own name. A file removed from the archive is marked missing. Nothing you do in Finder
is undone by the app.

Reading a document again (`review retry`, **Read Again**) labels and names it again where it is, from the text read of
it
before, keeping its tags; putting an exact copy of it into Incoming does the same, reading its text from its file again
too ([exact copies](#exact-copies)). A document you undid is back in Incoming, held; read again, it is filed at the top
of the archive.

## Search tasks

Rather than choosing labels one at a time, you can ask for the documents you need in your own words, in any language:
"electricity and water bills from 2025, by sender", "everything the tax authority sent about last year's return". The
request becomes a **task**, which joins a queue of its own; the tasks in it are read one at a time, the oldest first (a
task whose request was being read when you quit is read first at the next start), by the reading model of the task's
profile, with a prompt of the app's own (`search-system.md`) and the task's effort
([below](#profile-and-effort)). The model is shown the labels the archive already uses of the kinds the effort's
`promptLabels` names, the most used first, so it asks for them as the archive writes them, and today's date, so "last
year" and "this month" mean something. It answers in a fixed schema:
the labels of each kind to look for, each with the words of the request that ask for it, words the text must contain
for what no label says, the kinds to arrange what is found by, and a name for the task. The answer is untrusted input,
checked as a document's answer is: each label must be a label of its kind (a date, period or deadline may be a year, a
month, a day or a span of them), at most `tasks.maxValuesPerKind` of a kind and `tasks.maxWords` words. Every kind a
task asks for leaves documents out, so a label nobody asked for, such as the country all your documents are from,
would silently hide what you wanted: a label is kept only when every word the model quotes for it is a word of your
request, but not when every one of them is already quoted by a label of another kind, as "Portugal" in "invoices from
Portugal" asks for a country, not for documents written in Portuguese; and a word only when it is in your request and
no label already asks for it. What is dropped, and why, is in
the task's trace. An answer that cannot be read, or is left asking for nothing at all, goes back to the model with what
was wrong, as often as the effort's `repairAttempts` says; no other model is asked in its place. A request the model
never answers validly fails the task, with the reason, and so does an answer that takes longer than the effort's
`timeout` ([below](#profile-and-effort)). While Ollama cannot be reached a task waits in the queue, as a
document does. A task whose reading model is not installed fails, naming the model, until it is downloaded and the
task's documents are found again (**Find Again**), and one given a profile the settings no longer list fails saying so
until it is given another.

**What a task finds.** The documents in the archive (filed, waiting for you, parked after failing, or left for later;
not the copies earlier versions filed beside other documents, nor those undone or missing) that have, for every kind of
label the task asks for, one of the labels it gives: the labels of one kind are alternatives, and the kinds narrow each
other down, as the facets of faceted search do ([sources](organizing-principles-sources.md#sources-for-search-tasks)). A
label is matched by its words, whatever their case, accents or punctuation, so `EDP` finds `EDP Comercial` and
`tax return` the type `tax-return`; a date, period or deadline is matched by the time it covers, so `2025` finds the
date `2025-03-05` and the period `2024-07/2025-06`. Every word asked for must be in the document's text, file name or
labels. A task finds at most `tasks.maxDocuments` documents: when more have what it asks for, it keeps the newest by
their own date, those without a date last, whenever they were filed.

**How they are arranged.** By the kinds the request asked for, otherwise by `tasks.defaultGrouping` (type, then sender),
a level for each kind, at most `tasks.maxGroupingDepth` deep. At each level a document goes with its first label of the
kind, the most significant, and by a date, period or deadline with its year. Groups follow alphabetically, years newest
first, and the documents without a label of the kind come last. Within a group, and in a set listed without arranging
it, documents follow their own date, the newest first and those without a date last, and those of one day their name;
an export copies them in that order.

**Changing a task and its set.** Take any document out of the set, or add one: by its number, or, as the sidebar
narrows documents down, every document that has all the labels chosen, at most `tasks.maxDocuments` of them, the newest
by their own date, as a task finds them. Rename the task, arrange its set otherwise, or list it without arranging it.
Give it another request and it finds its documents again; so does **Find Again**, such as after new documents were
filed. Finding them again keeps the documents you added and leaves out those you took out.

**Exporting.** A task's set is copied into a new folder named after the task, in a folder you choose outside the
archive and Incoming, with a folder for each group of the first kind it is arranged by, a folder inside it for each
group of the next, and the documents at the bottom under their own names; or into a ZIP archive of that folder, whose
names are written with composed accents ("João", not "Joa" and an accent), as other systems expect.
Documents are copied, never moved, and nothing already there is written over: a name that is taken gets the collision
suffix (`naming.collisionFormat`). A folder is named after its label as a file name is cleaned, so a label can never
place a file anywhere else, and the documents without a label of the level's kind go into `tasks.withoutLabelFolder`
(`No sender`). Each export is kept with its task: when, as what, where, and where each document went inside it; a
document whose file is not where the archive has it is left out, with the reason.

Every task, its set as you left it and its exports are kept in the archive (`System/_tasks.md`, [Storage](storage.md)),
so a rebuild brings them back. Asking, what was found, each change, each export and removing a task are recorded in
History, and each reading of a request is traced, its prompts and the model's answers included (the `interpret` and
`match` steps; `arrumatorcli tasks show <task> --full`). That a request is being read, and by which model, is no
decision, so History does not record it: the queue says it while it lasts, and the app shows it on the task
([Tasks](using-arrumator.md#what-the-app-shows-you)). Removing a task leaves what it exported where it was put.

## Talking with a task's documents

Once a task has found its documents, ask about them on its card, under **Conversation**, in your own words and in any
language: "summarize these invoices", "what do they come to in all?", "translate the contract into English", "write a
short e-mail to my accountant listing them", "which of them have a deadline in July?". A question joins a queue of its
own, and the questions in it are answered one at a time, the first asked first (one being answered when you quit is
answered first at the next start), by the reading model of the task's profile at the task's effort
([below](#profile-and-effort)), with a prompt of the app's own (`conversation-system.md`). A conversation reads as it
was held, the first question first.

**What an answer draws on.** The task's set as it is when the question is answered: add documents to the task or take
them out, and the next answer draws on the set as it is then, while the answers before stay as they were. Between two
questions, the conversation shows each change made to the set, and to how the task is read, as History recorded it. A
local model's context holds the text of a few documents, not of a thousand, so an answer is shown what its question
needs, as retrieval-augmented generation does ([sources](organizing-principles-sources.md#sources-for-conversations)):
first the documents the last answer drew on, which a question such as "translate it" goes on about; then those the
question concerns, those holding any of its words, the rarer a word the more it counts, fused with those alike to it in
meaning, as search finds them; then the rest by their own date, the newest first. In that order each is shown with its
text, its start and its end cut to `conversation.documentChars` as a document is read, while the text fits in
`conversation.contextChars`; a document whose text does not fit, or has not been read yet, is listed by its name, date
and labels, at most `conversation.maxListed`, and the answer is told how many more there are. A set the context holds
is shown whole. The answer is also shown the conversation so far, the latest questions and answers up to
`conversation.historyChars`, the latest cut to fit when it alone is longer, and today's date. It is never shown your
tags. A question is at most `conversation.maxQuestionChars` long.

**The answer** comes in a fixed schema: the answer, in Markdown, in the language of the question unless it asks for
another, naming documents by their names, working out a total or a comparison the question asks for, and saying when
documents disagree; the documents it draws on, by their numbers, which it is shown only for this; and, when you asked
for more documents, a request for them, which it says it is looking for. It is
untrusted input: a document it says it draws on is kept only when it is one it was shown, as a citation is checked
against its sources, a number it writes in the answer for a document it was shown is given as that document's name, and
an answer without words, or that cannot be read, goes back to the model with what was wrong, as often as the effort's
`repairAttempts` says. It is shown as it is written: the card shows the answer as the model writes it, its paragraphs,
headings, lists, quotes and code as such, **Thinking…** while a model that thinks has written nothing yet, that it waits
for the model to begin while the model loads or reads documents first, and how long it has taken once that is more than
a moment. Nothing in an answer can act: a link shows as its words followed by its address, and an image as its words,
so a document that asks the model to end its answer with a link that would carry the document's data elsewhere gets
nothing clickable. An answer cut off at its length limit, the effort's `numPredict`, is kept as far as it came, saying
it was cut off: ask for less, or ask again at a lower effort, which thinks less and so leaves more of the limit to the
answer. An answer that takes longer than the effort's `timeout` fails the question, keeping what came of it. While
Ollama cannot be
reached a question waits in the queue, as a document does, saying so and when it is tried again, the last of
`ingest.retryDelays` later, rather than being asked again meanwhile; a reading model that is not installed, or a profile
the settings no longer list, fails it with the reason.

**Finding more.** Ask for documents beyond the set, such as "find the contract these invoices are billed under", and the
answer writes a request for them in your words, with what the documents told it: a sender, a reference, a period. That
request is read as a task's request is, at the task's effort, and the documents it finds that are not in the set, nor
taken out of it, are listed under the answer, the newest by their own date first, at most `conversation.maxSuggested`.
Nothing joins the set unless you add it, one by one or with **Add All**, as an addition to the set; the next answer then
sees it. A request that cannot be read says why, and the answer is kept all the same.

**Stopping, asking again and clearing.** **Stop** ends an answer as it is written, keeping what came of it, or takes a
question out of the queue. **Ask Again** answers a question again in its place, from the set as it is then; answered
again after questions below it, it says that they followed its earlier answer. **Copy** puts an answer on the clipboard,
to paste into an e-mail. **Clear Conversation…** removes every question and answer of the task, one being answered too;
the documents stay in the task.

Every conversation is kept in the archive beside its task (`System/Conversations/_<task>.md`, [Storage](storage.md)),
with the questions and answers written out below its data for people to read, so a rebuild brings it back; removing a
task removes its conversation. Clearing a conversation is recorded in History. A question and its answer are kept in the
conversation, and each answer is traced: what it was shown (the `context` step), its prompts and the model's answers
(`answer`), and a request for more documents as it was read and matched (`interpret` and `match`;
`arrumatorcli tasks conversation <task> --full`). That a question is being answered, and by which model, is no
decision, so History does not record it: the queue says it while it lasts, and the app shows it.

## Profile and effort

Two choices decide how a search task's request is read, and how what is asked about its documents is answered: which
models read it, the **profile**, and how much the reading model thinks before it answers, the **effort**. A document is
read with the profile alone.

A **model profile** is a name and three models: one that reads documents and search requests and names files
(`chatModel`), one that describes images (`visionModel`) and one that finds documents by meaning (`embedModel`).
Arrumator comes with Fast, Standard and Smart ([requirements](../README.md#requirements)); Settings › Models chooses the
one documents are read with, gives any profile other models and adds your own ([using
Arrumator](using-arrumator.md#models-and-profiles)). Documents already read keep their labels when the reading model
changes, and those embedded by another model are found by meaning again only once they are read again: put them into
Incoming again, as they are, to have them read with the profile now in use ([exact copies](#exact-copies)). A task is
read by the reading model of the profile you gave it, or else of the one Settings uses when the request is read, so a
task without a profile of its own follows a change of profile. A profile search tasks of the archive that is open read
with is not removed until they are given another. Profiles are yours and tasks each archive's, so a task of another
archive may name a profile you removed: it fails saying so until it is given another.

The **effort**, Low, Medium or High, is how much the reading model thinks before it answers a task's request, each a
preset in `tasks.efforts` with the budget thinking needs. An answer improves with the computation spent on it when it
is written: thinking before answering, and a wrong answer sent back with what was wrong, both read a request more
carefully, and take longer ([sources](organizing-principles-sources.md#sources-for-search-tasks)). A preset says

- what a model that can think is told about thinking, `think`: `false`, `true` or the name of a level;
- how often an invalid answer goes back to the model, `repairAttempts`;
- how long an answer may be, in tokens and its thinking included, `numPredict`, and how many seconds it may take,
  `timeout`, in place of `ollama.timeouts.chat`. A model that thinks spends thousands of tokens before it writes its
  answer: measured live, `qwen3.5:9b` thought through all of 4,096 and answered nothing, and with 8,192 answered in
  about 300 s, against 61 s without thinking. One that thinks until the tokens run out stops before it has written its
  answer, which goes back to it saying it was cut off. An answer that takes longer than `timeout` fails the task,
  saying so, and is not asked for again, which would hold the model as long again while no document is read: ask
  again with a lower effort, which thinks less. A document's answer has no `timeout` of its own, and one that takes
  longer than `ollama.timeouts.chat` is asked for again after `ollama.retryDelays`, as a server that is away is;
- how many labels in use of each kind the model is shown, `promptLabels`.

| Effort | Thinks (`think`) | Sent back | An answer may take | Shown of the archive's labels |
|---|---|---|---|---|
| Low | no (`false`) | once | 600 tokens, 180 s | the fewest |
| Medium | yes (`"medium"`) | once | 8,192 tokens, 900 s | more |
| High | the most (`"high"`) | twice | 8,192 tokens, 900 s | the most |

A model is told only what its `/api/show` says it takes (`thinking.values`), and otherwise nothing, so it thinks as it
does by default ([Ollama: thinking](https://docs.ollama.com/capabilities/thinking)). A server that lists no values, as
older ones do, or values the app cannot read, which it logs, leaves it to the model's `thinking` capability: such a
model is switched on and off. `arrumatorcli models list` shows how each installed model thinks:

- a model that names levels, such as gpt-oss (low, medium, high), is told the effort's level at Medium and High. It
  cannot stop thinking, so at Low it is told nothing and thinks at its own default;
- a model that only switches thinking on and off thinks alike at Medium and High, and not at Low;
- a model that cannot think, such as Standard's `ministral-3:14b`, is told nothing, so for it the efforts differ only
  by how often a wrong answer goes back and how many of the archive's labels it is shown.

Effort is for search tasks and the questions about their documents only: a model reading a document or describing an
image is told not to think
(`analysis.think`), as thinking multiplies the time every document takes. A new task gets the effort Settings gives
new tasks (`taskEffort`, Medium as the app comes), which the Tasks page's effort picker sets.

A question about a task's documents is answered with the task's profile and at its effort too, each effort a preset in
`conversation.efforts` that says, as a task's does, `think`, `repairAttempts`, `numPredict` and `timeout`; what an
answer is shown is chosen by `conversation.contextChars` and the keys beside it
([above](#talking-with-a-tasks-documents)),
not by the effort. An answer is a text to write rather than a list of labels to fill, so it gets more room, and it is
sampled as writing is (`conversation.sampling`, a temperature above 0), not decoded greedily as a document is read,
which repeats itself over a long text ([sources](organizing-principles-sources.md#sources-for-conversations)). It is
asked in a context of its own, `conversation.numCtx`, larger than `analysis.numCtx`, so a few documents' text, the
conversation and the answer fit: Ollama loads the model again whenever it goes from reading documents to answering, and
the larger context takes more memory while it is loaded.

| Effort | Thinks (`think`) | Sent back | An answer may take |
|---|---|---|---|
| Low | no (`false`) | once | 2,048 tokens, 300 s |
| Medium | yes (`"medium"`) | once | 6,144 tokens, 900 s |
| High | the most (`"high"`) | once | 6,144 tokens, 900 s |

Giving a task another effort or profile sends it back into the queue, to be read again and find its documents again,
as another request does, and the next question about its documents is answered with them. Both are kept with the task,
in History and in the archive. The task's trace is stamped with
the profile's models, and its `interpret` step records the effort, the model that read and what the effort wanted it
told about thinking, and with each call to the model what it was sent (`think`, absent when nothing was); the task
keeps which model read it last.

## Archives from earlier versions

Earlier versions filed documents into a tree of folders the archive's logic described, and learned senders. Those
documents stay where they are and are still indexed and searchable. What they were known by becomes their labels:
their sender, type, date, reporting year, topic tags and language, as `sender`, `type`, `date`, `period`, `topic` and
`language` labels; the name the model gave them, the model and what they waited for you about become how they were
read. Titles are not kept. The folders, their `_about.md` files, the logic, what was learned about folders (rules,
filing memories, corrections) and the senders are no longer used. To give such documents the full set of labels, read
them again (`review retry`). Everything new is filed at the top of the archive.

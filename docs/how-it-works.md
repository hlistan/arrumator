# How Arrumator works

This is how Arrumator reads a document, labels it, names it and files it, and what it learns about who documents
come from. [Using Arrumator](using-arrumator.md) covers the app and its settings. [Storage](storage.md) covers where
everything is kept, and [Evaluation](evaluation.md) the measurements behind these choices.

## How a file is handled

```text
new file in Incoming ──► wait until it stops changing ──► hash (an exact copy of a filed document is a duplicate)
   ──► extract: PDFKit text, Apple Vision OCR (en/ru/pt), textutil (doc/docx/rtf/odt/html), CoreXLSX, PPTX, e-mail,
       archives, media metadata, Quick Look previews, local vision model for photos; language, dates, identifiers
   ──► understand: the senders the app knows are recognised in it, by identifiers, e-mail and web domains, names
   ──► analyse: the local model reads it once, with the app's own prompt, and says what it is (sender, type, date,
       title), picks out its signals, which become its labels, and names the file
   ──► file it at the top of the archive under that name, keeping the original name in an extended attribute, and
       add it to the search index (its words and its meaning)
   ──► learn: the document is linked to its sender, and what identifies the sender is learned
```

The archive has no folders of the app's making. Every document is filed at its top, and found again by its labels,
sender, words or meaning. A folder you make yourself is yours: the app reads files you put in it where they are, and
never moves them out.

OCR runs on Vision's default device, the Neural Engine or GPU. When that fails, as it can when the Neural Engine's
model does not compile, the page is read again on the CPU, and so is every later page until the app restarts. The
document's trace records which device read each page.

## Reading a document

The model reads each document once, with a prompt of the app's own (`labels-system.md`), which you do not edit. It is
given the document's text (an excerpt of `analysis.excerptChars` characters), the dates and identifiers the extractor
found, and the senders the app recognised in it, and it answers in a fixed schema:

- **What the document is**: its sender, as the document writes it or as the app already knows the sender; its type,
  from a fixed list (invoice, receipt, statement, contract, tax return, payslip, certificate, ID document, letter, …);
  its issue date, and the year it reports on when that differs; a short title in the document's own language.
- **Its signals**, which become its labels (below).
- **Its file name**, as `YYYY-MM-DD Sender - Description`, in the document's language.

The answer is untrusted input. It is decoded into typed values and checked: the type must be one of the list, the date
becomes ISO, labels are tidied as described below, and an answer that cannot be read, or leaves a list out, goes back
to the model with what was wrong (`analysis.repairAttempts` times). The profile's decision model is asked first and its
other model after it, if the profile has two. The file name goes through the same cleaning every file name does: no
path separators, bounded length, and, when Settings says so, transliterated.

## Labels: what a document is about

Folders hold a document in one place; labels let it be found from every side. The model picks out the document's
*signals*, the few facts someone looking for it later would search by, and each one becomes a label of one of four
kinds:

- **Subject**: a person or organisation the document concerns: whom it is addressed to, whose it is, or whom it is
  about (a customer, a patient, a taxpayer, a company), named as the document names them.
- **Object**: a specific thing it concerns, with what identifies it: an apartment and its address, a car and its
  plate, a supply point, an account, a policy.
- **Jurisdiction**: the countries, and regions or cities where they matter, whose law, authority or administration the
  document falls under: where a tax is due, a contract is governed, an ID was issued.
- **Language**: the languages it is written in, as ISO 639-1 codes (`pt`, `ru`, `en`).

The kinds follow the metadata records keep in archival practice: the parties a record concerns, its coverage in the
sense of the jurisdiction it belongs to, and its language ([sources](organizing-principles-sources.md#sources-for-labels)).

A label is kept on one line and cut to `labels.maxValueChars`, repeats are dropped however they are written, each kind
keeps its first `labels.maxPerKind`, and a language becomes its ISO 639-1 code, whether the model wrote `pt`, `por` or
`Portuguese`. A language that is none is dropped rather than sent back.

Labels are the document's. They sit in its entry in `_documents.md` and survive a rebuild, and each kind is a field of
the search: `jurisdiction:portugal`, `subject:"maria silva"`, `object:AA-12-BB`, `language:portuguese` (a language is
found by its code and by its English name). A plain search finds labels too. A document's card lists them.

When the model finds nothing worth a label, the document is labelled with nothing, which is not the same as not
labelled. A document without labels, such as one filed by an earlier version of the app, is labelled when it is read
again: `arrumatorcli review retry <document>` for one, `arrumatorcli labels --unlabelled` for all of them.

## Documents that wait for you

A document is filed however it was read, but some wait for you in **Needs You**, in the archive, with the reason on
their card:

- the model gave no valid answer, even after being told what was wrong (the document keeps its own name and has no
  labels);
- the file is encrypted or damaged;
- no text could be read from it, and no image description either, as with a blank scan.

Confirm one as it is (**Looks Right**), correct its name or details, or have it read again. A file that keeps failing
to be processed at all (`ingest.maxAttempts`) is parked in the archive the same way, with status failed, so Incoming
stays clean and nothing is lost.

While Ollama cannot be reached a document waits where it stopped, and a missing model holds it until the model is
downloaded; neither costs it an attempt.

An exact copy of a document already filed is a **duplicate**. It is not read again: it is filed at the top of the
archive under its own name, marked as the copy it is, or left in Incoming, as Settings › General says
(`duplicateAction`).

## Senders

A sender is whoever a document comes from (EDP, the tax authority, a bank, a landlord). Every filed document is linked
to its sender, a known one or a new one, and a sender collects:

- its other names;
- the identifiers that are only ever on its documents: a tax number, IBAN or account number seen on at least
  `senders.stableKeyMinFilings` of its filed documents and on no other sender's;
- its e-mail and web domains.

Before the model reads a document, the senders the app knows are recognised in it: by an identifier first, then a
domain, then a name. The model is told whom the app recognised, so it names the sender as its earlier documents were
named, and a sender the model writes another way (its full legal name, its brand) is still the known one. An
identifier that turns up on two senders' documents, such as your own tax number printed on every bill, identifies
neither, and both lose it.

When you correct a document's sender, the name the model read becomes another name for the sender you chose, so the
next document it reads that way is named as you did. Undoing a filing counts it no longer for its sender.

### Forgetting

Anything learned can be forgotten, from the Senders page or `arrumatorcli forget`:

- **Another name for a sender.** The name is no longer matched to that sender.
- **A whole sender.** Its names and identifiers are forgotten; its documents keep the name they were filed under.

Each time the app forgets something, it is recorded in History.

## Your own changes

Moving or renaming a document in Finder is followed: the app finds the file by the identifier it stores on it and
records the move in History. A file you put into the archive yourself, at the top or in a folder of yours, is read and
labelled where it is, under its own name. A file removed from the archive is marked missing. Nothing you do in Finder
is undone by the app.

Reading a document again (`review retry`, **Read Again**) names it again where it is. A document you undid is back in
Incoming, held; read again, it is filed at the top of the archive.

## Archives from earlier versions

Earlier versions filed documents into a tree of folders the archive's logic described. Those documents stay where they
are and are still indexed and searchable; the folders, their `_about.md` files, the logic and what was learned about
folders (rules, filing memories, corrections) are no longer used. Documents keep their sender, type, date and title,
and what the model decided becomes what it read; they have no labels until they are read again. Everything new is filed
at the top of the archive.

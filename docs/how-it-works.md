# How Arrumator works

This is how Arrumator reads a document, labels it, names it and files it. [Using Arrumator](using-arrumator.md)
covers the app and its settings. [Storage](storage.md) covers where everything is kept, and
[Evaluation](evaluation.md) the measurements behind these choices.

## How a file is handled

```text
new file in Incoming ──► wait until it stops changing ──► hash (an exact copy of a filed document is a duplicate)
   ──► extract: PDFKit text, Apple Vision OCR, textutil (doc/docx/rtf/odt/html), CoreXLSX, PPTX, e-mail,
       archives, media metadata, Quick Look previews, local vision model for photos; language, dates, identifiers
   ──► analyse: the local model reads it once, with the app's own prompt, picks out its signals, which become its
       labels, and names the file
   ──► file it at the top of the archive under that name, keeping the original name in an extended attribute, and
       add it to the search index (its words, its labels and its meaning)
```

A document is described by its labels and nothing else: who sent it, what type it is, its date, whom and what it
concerns, and the rest are all labels of one kind or another. The archive has no folders of the app's making. Every
document is filed at its top and found again by its labels, its words or its meaning. A folder you make yourself is
yours: the app reads files you put in it where they are, and never moves them out.

### Documents in any language

Nothing in reading a document is tied to a language. The extractor tells the language of the text among all that
Apple's NaturalLanguage knows. Its dates are found with month names in every language the system has a calendar for,
in each form it writes them (`15 мая 2024`, `3. März 2025`, `2025年3月5日`), and in numeric forms from day first to
year first. OCR asks Vision for the document's own language first, then the hints in `extraction.ocrLanguages`, and
lets Vision detect any other it reads. A script Vision does not read in images is still read from a PDF's text layer,
an e-mail or a text file. The model reads the document as written and describes it in labels that do not depend on its
language: names and numbers as the document writes them, topics, objects and jurisdictions in English, dates, amounts and
languages in ISO forms. Documents in different languages are therefore found by the same labels. The file name's
description is in the document's own language.

OCR runs on Vision's default device, the Neural Engine or GPU. When that fails, as it can when the Neural Engine's
model does not compile, the page is read again on the CPU, and so is every later page until the app restarts. The
document's trace records which device read each page.

## Reading a document

The model reads each document once, with a prompt of the app's own (`labels-system.md`), which you do not edit. It is
given the document's text (an excerpt of `analysis.excerptChars` characters) and the dates and identifiers the
extractor found, and it answers in a fixed schema: one list of signals for each kind of label, then the file name.
Under constrained decoding the model writes the lists in the schema's order, so the facts a file name is made of come
first (the sender, the type, the date) and the name last, built from them as `YYYY-MM-DD Sender - Description`, in the
document's language.

The answer is untrusted input. It is decoded into typed values and checked, each label as described below; an answer
that cannot be read, or leaves a list out, goes back to the model with what was wrong (`analysis.repairAttempts`
times). The profile's decision model is asked first and its other model after it, if the profile has two. The file
name goes through the same cleaning every file name does: no path separators, bounded length, and, when Settings says
so, transliterated.

## Labels

The model picks out the document's *signals*, the facts someone looking for it later would search by, and each one
becomes a label of one of these kinds:

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

The kinds follow the metadata archival description keeps for a record (DCMI's creator, subject, coverage, issued,
temporal, valid, type, identifier and language; ISO 23081's agents), the facets of faceted classification, and the
fields document managers and key-information extraction read from personal paperwork
([sources](organizing-principles-sources.md#sources-for-labels)).

Every label is kept on one line, cut to `labels.maxValueChars` after the last whole word, and kept once however it is
written. Each kind keeps its first `labels.maxPerKind` labels, the most significant first; a document has at most one
type and one date. A value that is no label of its kind is dropped rather than sent back: a date or deadline that is no
calendar day (day-first dates such as `31.07.2026` become ISO), a period of another shape, an amount or a reference
without a number, a language that is none (one written `pt`, `por` or `Portuguese` becomes `pt`). An amount written
with its currency code first or after a colon (`EUR 54.21`, `54.21: EUR`) becomes `54.21 EUR`. Topics are lowercase.

Labels are the document's. They sit in its entry in `_documents.md` and survive a rebuild, and each kind is a field of
the search: `sender:edp`, `party:"maria silva"`, `type:invoice`, `object:AA-12-BB`, `reference:926804564`,
`deadline:2026-07`, `amount:54.21`, `jurisdiction:portugal`, `language:portuguese` (a language is found by its code and
by its English name). A plain search finds labels too. A document's card lists them by kind.

When the model finds nothing worth a label, the document is labelled with nothing, which is not the same as not
labelled. A document without labels is labelled when it is read again: `arrumatorcli review retry <document>` for one,
`arrumatorcli labels --unlabelled` for all of them.

### Correcting labels

Every label can be changed. On a document's card, a label is taken off with its ×, and one is added by choosing its kind
and writing its value; from a terminal, `arrumatorcli labels <document> --add sender=EDP --remove topic=energy`. Your
labels are kept as the model's are: a date must be a date and a type one of the list. A document keeps one type and one
date: on the card a new one replaces the old; from a terminal, remove the old one in the same command (`--remove
type=invoice --add type=receipt`). Each correction is recorded in History. Renaming the document (on its card, or
`review rename`) renames the file where it is.

## Documents that wait for you

A document is filed however it was read, but some wait for you in **Needs You**, in the archive, with the reason on
their card:

- the model gave no valid answer, even after being told what was wrong (the document has no labels);
- the file is encrypted or damaged;
- no text could be read from it, and no image description either, as with a blank scan.

A document that waits keeps its own name: what the model read of it is in doubt. Confirm one as it is
(**Looks Right**), correct its name or labels, or have it read again. A file that keeps failing to be processed at all
(`ingest.maxAttempts`) is parked in the archive the same way, with status failed, so Incoming stays clean and nothing
is lost.

While Ollama cannot be reached a document waits where it stopped, and a missing model holds it until the model is
downloaded; neither costs it an attempt.

An exact copy of a document already filed is a **duplicate**. It is not read again: it is filed at the top of the
archive under its own name, marked as the copy it is, or left in Incoming, as Settings › General says
(`duplicateAction`).

## Your own changes

Moving or renaming a document in Finder is followed: the app finds the file by the identifier it stores on it and
records the move in History. A file you put into the archive yourself, at the top or in a folder of yours, is read and
labelled where it is, under its own name. A file removed from the archive is marked missing. Nothing you do in Finder
is undone by the app.

Reading a document again (`review retry`, **Read Again**) labels and names it again where it is. A document you undid
is back in Incoming, held; read again, it is filed at the top of the archive.

## Archives from earlier versions

Earlier versions filed documents into a tree of folders the archive's logic described, and learned senders. Those
documents stay where they are and are still indexed and searchable. What they were known by becomes their labels:
their sender, type, date, reporting year, topic tags and language, as `sender`, `type`, `date`, `period`, `topic` and
`language` labels; the name the model gave them, the model and what they waited for you about become how they were
read. Titles are not kept. The folders, their `_about.md` files, the logic, what was learned about folders (rules,
filing memories, corrections) and the senders are no longer used. To give such documents the full set of labels, read
them again (`review retry`). Everything new is filed at the top of the archive.

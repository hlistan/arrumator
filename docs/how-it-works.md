# How Arrumator works

This is how Arrumator reads a document, labels it, names it and files it. [Using Arrumator](using-arrumator.md)
covers the app and its settings. [Storage](storage.md) covers where everything is kept, and
[Evaluation](evaluation.md) the measurements behind these choices.

## How a file is handled

```text
new file in Incoming ──► wait until it stops changing ──► tagged by the folder in Incoming it is in, if any
   ──► hash (an exact copy of a document in the archive has that document read again instead: below)
   ──► extract: PDFKit text, Apple Vision OCR, textutil (doc/docx/rtf/odt/html), XLSX, PPTX, e-mail,
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
and then takes its place by when it arrived. Documents read again after a rebuild of the index, and those read again
all at once ([reading documents again](#reading-documents-again)), wait until no new file does; one you have the model
read meanwhile, with **Read Again** or a copy of it in Incoming, is read by the model in its turn instead, which reads
its text too.

A document is described by its labels and nothing else: who sent it, what type it is, its date, whom and what it
concerns, and the rest are all labels of one kind or another. The archive has no folders of the app's making. Every
document is filed at its top and found again by its labels, its words or its meaning. A folder you make yourself is
yours: the app reads files you put in it where they are, and never moves them out. A folder you put into Incoming is
yours too, and gives what is in it a label of yours, a tag ([below](#folders-in-incoming-and-tags)).

### What Incoming takes in

A file is taken once it has stopped changing: unchanged for `watcher.stabilityRequiredPolls` looks
`watcher.stabilityPollInterval` seconds apart, and one it can open, so a copy in progress is never read half (an empty
file after `watcher.zeroByteWaitSeconds`). Hidden files, downloads in progress, Office's lock files and the app's own
files are never taken (`watcher.ignoredNamePrefixes` and the keys beside it), and nothing in the archive is, when you
keep the archive inside Incoming, nor anything that is no file, such as a named pipe. Incoming is watched as the disk
spells it, and a file in it is known by its path as the disk spells it, whoever names it, so a path to it through a
link, or written in another case than the disk's, names the same file: the watcher and `arrumatorcli ingest` queue it
once, and a document undone into it is left there by the next rescan. `arrumatorcli ingest` refuses, saying why, what
the watcher never takes: a link, which would file what it points to, wherever that is, and a hidden, temporary or
app-managed file.

- **A package**, a folder macOS shows as one document (an `.rtfd`, a Pages document), is one document, never the files
  it holds one by one; `arrumatorcli ingest` given a file inside one takes the package. It is taken whole once nothing
  in it has changed, its size is that of the files it holds, and it is known by a SHA-256 over everything it holds,
  each item's path in it and its bytes, so a copy of it, under whatever name, is an [exact copy](#exact-copies). It is
  moved whole. One that holds more than `watcher.maxPackageItems` items, as a photo library does, is no document: it is
  walked no further, left where it is, and History says so, and `arrumatorcli ingest` refuses it, saying so.
- **A file that cannot be opened**, as when its permissions do not let Arrumator read it, is waited for
  `watcher.unopenableWaitSeconds` once it has stopped changing, then left where it is, and History says so. It is
  taken once it can be opened or it changes, and said again at the next start while it still cannot be opened.
- **Into an archive on another volume**, a file is copied, the copy checked against the file's SHA-256 and given its
  dates, and only then does the file go to the Trash. One the Trash will not take, as on a volume without one, is not
  tried again: it stays in Incoming, waiting for you in Needs You as not filed, with why, and its copy goes to the
  Trash instead, so there is never a second one. When that Trash will not take the copy either, History and the
  document say where the copy is. Its card offers **Read Again** and **Leave for Later**, never **Looks Right**, as it
  is in no archive. A rescan leaves the file alone while it is that file, by its size, date and identity on the disk;
  saved again, it is the same document arriving again. **Read Again** reads it as an arrival, from its file.
  It is no document of the archive meanwhile: no copy is taken for one of it, and no search task finds it. Whether a
  document is in the archive is told by where its file is, however the archive's folder is named, through a link or in
  another case.
- **A file changed after it was read**, between its hashing and its filing, is not filed as what was read of it: it is
  read again from the start, as a new arrival, and History says it changed. What was read of it, its labels but its
  tags, its text and its place in the search, goes; a file gone meanwhile ends its document as missing, and one that
  changed into an exact copy of a document in the archive ends it as a copy does. That counts as one of its attempts
  (`ingest.maxAttempts`), so a file that changes at every reading ends as any file that keeps failing does.
- **When the archive's folder is not there**, as when it was renamed away or its disk is not attached, a file waits
  to be filed, spending no attempt, and History says so once. The app never makes the archive's folder again where it
  is gone; the file is filed once the folder is back.

### Documents in any language

Nothing in reading a document is tied to a language. The extractor tells the language of the text among all that
Apple's NaturalLanguage knows. Its dates are found with month names in every language the system has a calendar for,
in each form it writes them (`15 мая 2024`, `3. März 2025`, `2025年3月5日`), and in numeric forms from day first to
year first, in the digits of any script (`٢٠/٠٥/٢٠٢٦`), each end of a range such as `01/03/2024-31/03/2024` too, and
day first with spaces, as an identity card prints it (`01 02 2025`). Every
date is a day of the Gregorian calendar, as ISO dates are, whatever calendar the Mac is set to (Buddhist, Japanese,
Persian). A file's own dates, which have no zone, are the day they were in the Mac's time zone; a PDF's creation date,
a recording's capture date and an e-mail's Date header are the day they write, in the zone they are written in, which
is the day the writer's clock showed. Account and customer numbers, and
policy and contract numbers, are those after the words `entities.accountLabels` and `entities.policyLabels` list, in
each way they are written ([Configuration](using-arrumator.md#configuration)), which you can add to for another
language. OCR asks Vision for the document's own language first, then the hints in
`extraction.ocrLanguages`, and lets Vision detect any other it reads. A script Vision does not read in images is still
read from a PDF's text layer, an e-mail or a text file. What a PDF page sets apart on one line, as two address blocks
side by side or a value beside its label, is read with a tab between, as OCR reads a table's cells, so the model never
reads two of them as one name: a gap wider than `extraction.pdf.columnGap` times the height of the letters either side
parts them. The model reads the document as written and describes it in
labels that do not depend on its language: names and numbers as the document writes them, topics, objects and
jurisdictions in English, dates, amounts and languages in ISO forms. Documents in different languages are therefore
found by the same labels. The file name's description is in the document's own language.

OCR runs on Vision's default device, the Neural Engine or GPU. When that fails, as it can when the Neural Engine's
model does not compile, the page is read again on the CPU; once the CPU has read a page the default device could not,
so is every later page until the app restarts, while a page neither reads leaves the default device in use. The
document's trace records which device read each page.

## Reading a document

The model reads each document once: the reading model of the profile Settings uses
([profile and effort](#profile-and-effort)), with a prompt of the app's own (`labels-system.md`), which you do not
edit. A model that can stop thinking is told not to think first (`analysis.think`), as the one that describes images
is, and it reads with a context of `analysis.numCtx` tokens, the one images are described with too, so a model that
does both stays loaded once. It is
given the document's text (an excerpt of `analysis.excerptChars` characters) and the dates and identifiers the
extractor found, after what the archive's labels say ([below](#keeping-labels-one-vocabulary)), and it answers in a
fixed schema: one list of signals for each kind of label, then the document's title, what it is, in the document's
language. Under constrained decoding the model writes the lists in the schema's order, the facts first and the title
last. The prompt asks for labels only of what the document's own text states: never a sender, a party, a date or an
amount taken from the archive's labels, the file's name or what the model knows of the world, and never a date it
would have to complete, such as a day and a month without a year; the sender of a contract or a lease is the party that
issues it, the landlord, the seller or the employer, whom it names. The prompt shows each kind by values in its form
(`54.21 EUR`, `2026-06`), never by a pattern the model would copy, and the title by examples in several languages, as
the title is in the language of the document's own text.

The answer is untrusted input. It is decoded into typed values and checked, each label as described below; an answer
that cannot be read, or leaves a list out, goes back to the model with what was wrong (`analysis.repairAttempts` times),
and one cut off at its length limit (`analysis.llmOptions.numPredict` tokens) goes back saying so. No other model is
asked after it: a document it never answers validly waits for you ([below](#documents-that-wait-for-you)).

The app, not the model, makes the file name, of the labels it kept and the title: `YYYY-MM-DD Sender - Title`, as
`2026-07-05 EDP Comercial - Fatura eletricidade julho` (the parts and their order are `naming.parts`, and what follows
each `naming.separators`). The date is the document's `date` label, the day it was issued, never a period or a
deadline, and the sender its first `sender` label, both as your rules keep them
([below](#keeping-labels-one-vocabulary)): after "merge EDP Comercial into EDP" the bill is named `2026-07-05 EDP -
Fatura eletricidade julho`, and a sender you do not want names nothing. What a document lacks is left out with
what separates it: `2025-08-20 Contrat de location` without a sender, `EDP Comercial - Fatura` without a date, the title
alone without either. A title that begins with the date or the sender, as a whole name would, does not repeat them. A
document with neither a sender nor a title keeps its own name. The file name goes through the same cleaning every file
name does: no path separators or other characters `naming.forbiddenCharacters` lists (one between words, as in "Fatura:
julho", becomes " - ", one inside a word or number a "-"), no invisible characters but the joiners some scripts and
emoji are written with, bounded length, and, when Settings says so, transliterated. A name cleaning leaves nothing
of, as one of dots and dashes, is no name, and nor is one of the app's own files or one Incoming never takes in (a
record file's `_….md`, a lock file's `~$…`): the document then keeps the name it has, the one it arrived with, or, read
again in the archive, the one it has there.

## Labels

The model picks out the document's *signals*, the facts someone looking for it later would search by, and each one
becomes a label of one of the first twelve of these kinds. The last, `tag`, is yours: the model is never asked for one.

| Kind | What it holds | Value |
|---|---|---|
| `sender` | Who issued or sent the document: the company, authority, institution or person on its letterhead or signature. | As the document writes it: a name, with a letter in it. |
| `party` | Another person or organisation it concerns: whom it is addressed to, whose it is, whom it is about. | As the document writes it, without titles: a name, never a number alone. |
| `type` | The form of the document. At most one. | One of invoice, receipt, statement, contract, tax-return, tax-assessment, payslip, certificate, attestation, id-document, letter, application, policy, medical-report, prescription, ticket, license, manual, quote, legal. A document none fits has none. |
| `topic` | A subject area it belongs to, from broad to specific: utilities, electricity; taxes, income tax. | One to three lowercase English words. |
| `object` | A specific thing it concerns, with what identifies it: an apartment and its address, a car and its plate, a supply point, an account, a policy. Never a fact about a person, such as a birth date or a job title. | A short English noun phrase and the identifier as written: `car AA-12-BB`, `savings account 0012345678`. |
| `reference` | A number that identifies the document or the matter it belongs to: an invoice, contract, case, customer or order number. Never a year or a period. | What it is and the number: `invoice FT 2026/926804564`. |
| `date` | When it was issued. At most one. | `YYYY-MM-DD`. |
| `period` | The period it covers: a billing month, a tax year, a statement period, a policy term. | `YYYY`, `YYYY-MM` or a day, or two of them as `start/end`. |
| `deadline` | A date by which something must be done, or on which something ends: payment due, expiry, renewal, an appointment. | `YYYY-MM-DD`. |
| `amount` | A total of money it asks for or records: the total due or paid, a net salary, a premium. Never a percentage. | A number and an ISO 4217 currency: `54.21 EUR`. |
| `jurisdiction` | A country, region or city whose law, authority or administration it falls under: where a tax is due, a contract is governed, an ID was issued. | In English: `Portugal`. |
| `language` | A language it is written in, the main one first. | An ISO 639-1 code: `pt`. |
| `tag` | Your own label: the name of the folder in Incoming it was put in ([below](#folders-in-incoming-and-tags)), or one you give it. Never the model's. | As you write it, case and all: `Taxes 2024`. |

The kinds follow the metadata archival description keeps for a record (DCMI's creator, subject, coverage, issued,
temporal, valid, type, identifier and language; ISO 23081's agents), the facets of faceted classification, and the
fields document managers and key-information extraction read from personal paperwork; a tag is a label you give, as
the tags of a personal collection are ([sources](organizing-principles-sources.md#sources-for-labels)).

Every label is kept on one line, cut to `labels.maxValueChars` after the last whole word, and kept once however it is
written. Each kind keeps its first `labels.maxPerKind` labels, the most significant first; a document has at most one
type and one date. The model gives one label per entry: an entry holding a semicolon, as `banking; account statement`
does, is the labels it separates, so no label of a kind the model gives holds one, yours included; only a tag may. One
an older version kept joined is the labels it holds once the index is opened, or rebuilt from a record file that holds
it. A value that is no label of its kind is dropped rather than sent back, and the document's trace says so: a date or
deadline that is no calendar day (day-first dates such as `31.07.2026` become ISO), a period of another shape, a
reference without a number, a sender, party, topic, object or jurisdiction without a letter (a tax number given as a
party), a language that is none (one written `pt`, `por` or `Portuguese` becomes `pt`), and an amount that is not a
number and its currency: a percentage, a currency left out, or one written by a symbol several currencies share, such as
`$` or `£`. An amount becomes a number with a dot for decimals, no grouping, and its ISO 4217 code, however it was
written: `EUR 54.21`, `54.21: EUR` and `54,21 €` are `54.21 EUR`, `1.234,56 €` and `1 234,56 €` are `1234.56 EUR` (of a
dot and a comma, the last is the decimal point, and either alone, once, is one); a symbol only one currency is written
with, as `€` or `₽`, is that currency's code. An object or a reference written as a field and its value, `invoice: FT
1`, becomes what it is and what identifies it, `invoice FT 1`. Topics are lowercase. A sender or a party is a name the
document itself writes, in its text, its e-mail's sender and subject, or what was seen in it: each of the name's words
of `labels.groundingLetters` letters or more (all of them, when it has none that long) is a word of the document or
inside one, as a name declined or written without spaces is, so "EDP Comercial" is not written by "Banco Comercial
Português". Words are told apart as NaturalLanguage tells them, in any script, and never joined across the spaces
between them, so "EDP" is not found in "Estimated payment". A name of several words is also written by its initials in
capitals as a word of their own, `СФР` for "Социальный фонд России" or `HMPO` for "HM Passport Office"; initials
shorter than `labels.groundingLetters`, as so many words and legal forms in capitals are, only where they begin a line,
as a letterhead writes `AT` for "Autoridade Tributária", never `SA` after "EDP Comercial" for "Sónia Almeida". A name
not written so is dropped, unless it is how one of your merges, however old, asks a name the document writes to be
written ([below](#keeping-labels-one-vocabulary)). The words are compared however they are cased (the Turkish `I`, `İ`
and `ı` alike), accented or written in width (`ＮＴＴ` is `NTT`), and however the document spaces or breaks them: `E D P  C
O M E R C I A L`, a soft hyphen or a word broken at the end of a line with a hyphen still write `EDP Comercial`. So a
note that names no one is not given the archive's most used sender. This is a check of the answer, not of the prompt,
which is unchanged (`analysis.promptVersion` stays).

The title is made of the document's own words, in its own language, as the prompt asks, and that is checked the same
way: when the document writes fewer than `analysis.titleGroundedShare` of the title's words of `labels.groundingLetters`
letters or more (numbers and short words, which say nothing of a language, are not counted), as of a Portuguese title,
"Fatura serviços cloud", for an English invoice, the answer goes back to the model once, naming the words the document
does not write. An object is a thing the document identifies by a number, a plate, an address or a name, so an object
with no word of `labels.objectIdentifierDigits` digits or more, nor a number standing alone beside a name as a house
number after its street, as a job title ("job title Senior Software Engineer") or a product on a receipt ("milk 1L x6"),
goes back with it, named, for the model to keep only what one of those identifies. So does a date given to a document
that writes no date and not its year either, as a note: one in which the extractor found no date with its year, the
vision model saw none, that is no e-mail, and that writes the year neither in four digits nor in two. Only that is
checked, never which day, as a date written month first or in another calendar may be read as another. And a reading
with no sender that names `analysis.partiesWithoutSender` parties or more, as a lease naming both its sides as parties,
goes back asking who issued it. Each of these is told once in an exchange, when a repair tells the model of it; what the
model gives then stands, whatever it is, and the trace says so. So does an answer whose only fault is such a guess when
no repair is left, or none comes of it: a document is never failed for its title, its objects, its date, its parties,
its references or its sender. What is written otherwise than the prompt asks, told by its form alone, is written as the
document itself tells, at once, with a note in the trace, as telling the model would cost a call and a weak one gives
again what it is told of; what the document tells is read from its own text and an e-mail's sender and subject, never
from what the vision model wrote of it, nor from the letters of a run of characters between spaces that holds an "@", a
dot before two letters, an underscore, a backslash or a slash before a letter, as web and e-mail addresses, users' names
and paths do (but "Arquivo/2026" is read as a word and a number, and `http://10.0.0.1` as a word and numbers). A party
that joins two neighbouring cells of one line, one of them a sender's name or its start in more than one word, as a
reading that copies the line two columns stand on does ("EDP Comercial Maria Exemplo", where the invoice prints "EDP
Comercial" beside "Maria Exemplo"), is the other cell as printed ("Maria Exemplo"), never cut to one word. A title of
more than one word with a letter that has a case, every such letter a capital ("TÍTULO DE RESIDÊNCIA TEMPORÁRIO"), is
written as the document writes it in a sentence, letter for letter: where the document writes the title's words in a
row, within one cell, beginning with a capital, as a sentence or a name does, with a small letter among them and each
word in capitals beside a word of the sentence, of small letters or a capital and small letters, as an abbreviation
stands, never beside only an abbreviation's letters, a unit or a word a number follows (after a dot or a degree sign,
what runs up to the next space with a digit in it, as "No. ABC123" does; after a space or a colon, what begins with a
digit or holds more digits than letters, as "INV-2026-118" does and "COVID-19" does not; so "No: ABC123", "No. FT
2026/1" and "No FT 2026/1" are read as words, as "Relatório: Q3 2025", "maio. IMI 2025" and "Relatório IRS 2025" are),
as a number's name or a month before its year, as a heading's words stand ("Título de residência temporário", "Fatura da
EDP"; not "FATURA n.º", "INVOICE No. 4711" nor "CONSUMO kWh"), and the title is those words in capitals, as the
document's language writes its capitals or as any does ("DOĞALGAZ FATURASI" of "Doğalgaz faturası"), or, in a title that
bears no accents, as capitals in some scripts leave them out, but for its accents ("TAXE FONCIERE A PAYER" of "Taxe
foncière à payer"). A title of no more than `naming.maxChars` characters is looked for, as no file name holds a longer
one. A title whose every word the document writes in capitals beside a word of a sentence, as abbreviations are ("IMI
AT"), is as asked. A reference whose words for what it is, those before its first word that holds a digit, is in
capitals, as "NIF", "FT" or a series' letter are, or is of another script, are not English, and which the document
prints as the name of the field the reference is the value of, beside it or above it, is its number ("Fatura n.º FT
EDPC2026/926804564" is "FT EDPC2026/926804564"). Words are not English that are of another script than the Latin one
("お客さま番号 03-3542-5545-25"), or, when one of them is no English word the Mac knows, more likely of the document's
language than of English, or of another language as surely as a short text's language is told
(`extraction.languageShortTextMinConfidence`: "Zählernummer 1ESY 1160 4478 21"); words English shares with the
document's language ("Client", "Contract") and a number's own letters, in any script ("Plate ΙΚΤ 1234", "Licence plate
品川 300 あ 12-34"), are as asked. Where the document does not tell, it goes back once, as the guesses above do: a title
whose words the document writes in no such sentence, as a card printed in capitals alone, a heading, or a sentence that
begins them with a small letter, which the app writes no capital for, or whose words it spells more ways than one, as
only the document could say its small letters; and a reference whose words it runs into the number.

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
`--add tag="Taxes 2024"`. Your labels are kept as the model's are: a date must be a date, a type one of the list, and
an amount a number and its currency, so `12,50 €` is kept as `12.50 EUR`. One that is not, such as the type `fatura`
or the date `2026-13-45`, is refused, saying what its kind takes, and nothing of that correction is made: the card says
so under the field as you write, and keeps what you wrote to correct. A label an earlier reading gave in a form its kind
no longer keeps, such as `5.00% GBP`, is still taken off, merged or removed everywhere as it is written. A
label of a kind the model gives labels a document the model has not labelled, so `labels unlabelled` no longer reads it;
a tag does not. A document keeps one type and one
date: a new one replaces the old, on the card and from a terminal alike (`--add type=receipt`). A correction is made to
the labels the document has when it is made, so two made one after the other, such as two labels taken off in quick
succession, both hold. Each correction is recorded in History. Renaming the document (on its card, or
`review rename`) renames the file where it is.

## Keeping labels one vocabulary

Labels are only as good as they are consistent: a document labelled `EDP Comercial` is not found under `EDP`, and a
topic written two ways splits what belongs together. This is the synonymy problem of every tagging system
([sources](organizing-principles-sources.md#sources-for-keeping-labels-one-vocabulary)). Arrumator keeps the archive's
labels one vocabulary in three ways, and learns from you as it goes.

**The model is shown the archive's labels.** Every document is read with a section of the prompt
(`archive-labels.md`) that lists the labels the archive already uses, each in quotes so a label holding a comma or a
semicolon reads as one, the most used first, for the kinds
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
written alike enough: `labels.vocabulary.kinds.<kind>.mergeSimilarity`. Labels whose numbers differ are never alike:
numbers are compared first, each as it is written and in the order they are written, so `FT 1/23` is not `FT 12/3`,
nor `Rua das Flores 12, 3` the same address as `Rua das Flores 3, 12`. A number is a run of digits that only spaces
break: an identifier printed in groups is the one typed without them, so the IBAN `PT50 0002 0123 1234 5678 9015 4` is
`PT50000201231234567890154` and the tax number `123 456 789` is `123456789`, while punctuation and letters end a
number. The same digits in the same order, where one label's numbers end only where the other's do, and the other's
end at more places, set by punctuation (`V/2026/532774` and `V2026532774`, `123.456.789` and `123456789`, `FT 1/23`
and `FT 123`), may be one number written two ways, or two numbers: that is no degree of likeness but a relation of its
own, so such labels are never merged on their own, whatever `mergeSimilarity`, and are offered under Look Alike for
every kind, whatever its `suggestSimilarity`, as below. Numbers that end in different places, each where the other's
does not (`FT 1/23` and `FT 12/3`), are neither merged nor offered. At 1, the default for names,
objects and references, only labels written the same way but for case, accents, punctuation, spacing and word order
are one (`EDP-Comercial, S.A.` is `EDP Comercial SA`); for topics and jurisdictions a typo is forgiven too
(`electricty`). Words may change places, but only between two numbers, or between a number and the
label's end, never across a number, nor may the letters and digits within a word: `EDP Comercial 12` is
`Comercial EDP 12`, but `car AB12CD` is not `car CD12AB`, `car AA-12-BB` not `car BB-12-AA`, and `12 Rua das Flores`
not the same writing as `Rua das Flores 12`, though it may look alike enough to be offered. A label without numbers
keeps its words in any order. These come together: `account Santander PT50 0002 0123` is
`Santander account PT5000020123`. How alike two labels are written is their Jaro-Winkler similarity, the measure record
linkage uses for names, over their words so ordered. A label the archive already uses stays itself, unless more
documents have it written another way. Only writing is compared, never meaning: that one label means another in other
words is the model's judgment, or yours. What was changed, and by which rule, is in the document's trace (the
`consolidate` step) and its History entry.

**Your tags are your words.** A tag is never made another because one in use is written alike, nor offered under Look
Alike: `Taxes-2024` stays `Taxes-2024` beside a `Taxes 2024` more documents have, until you merge the two. Only your
rules apply to a tag, when its folder gives it (the `tag` step of the trace) and from then on, as to any label. So the
vocabulary keeps no tags: the app refuses to start with a `tag` entry under `labels.vocabulary.kinds`, or among an
effort's `promptLabels`, saying so.

**What is merely alike waits for you.** Labels in use written alike enough to be one
(`labels.vocabulary.kinds.<kind>.suggestSimilarity`), but not enough to merge without asking, such as two names a
letter apart, are listed under **Look Alike** on the Labels page, and so are labels with the same digits grouped
otherwise, for every kind and whatever its `suggestSimilarity`, references included. They come the most alike first,
those with the same digits grouped otherwise as alike as their writing but for where their numbers end, at most
`labels.vocabulary.suggestionLimit`; `arrumatorcli labels similar` says which are which. The sidebar shows how many
wait.

What you decide becomes a rule, recorded in History and kept in the archive (`System/_labels.md`,
[Storage](storage.md)):

- **Merge** a label into another: every document that has it, written however, gets the other instead, and so does
  every document read from then on. Merging back the other way replaces the first merge, and labels merged into the one
  you merge follow it.
- **Remove everywhere** (ignore) a label: it is taken off every document, and the model's answers lose it from then on.
- **Keep apart** two alike labels: they are never merged and never offered to merge again.
- **Forget** a rule: documents read from then on no longer follow it. Documents it already changed keep their labels.

A rule is about a label however it is written, as above, so a rule made by an earlier version follows today's rule of
sameness: one about `NIF 123 456 789` also covers `NIF 123456789`, and one about `car AA-12-BB` no longer covers
`car BB-12-AA`, nor one about `V/2026/532774` the reference `V2026532774`.

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
  what it gave before (and the labels of other kinds you gave it by hand with them) once it is read ([reading documents
  again](#reading-documents-again)).
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
- it is a kind of file Arrumator cannot read, as one of a format no extractor and no Quick Look preview reads, so the
  model saw only its name: reading it again cannot change that, and its card says to save or export it as a PDF and put
  that in Incoming, or to confirm it as it is;
- no text could be read from it, and no image description either, as with a blank scan.

A document that waits keeps its own name: what the model read of it is in doubt. Its trace says why it waits, in a step
of its own marked as a warning (`review`), and History says so with its reading: one of which nothing could be read is
never said to have had nothing worth a label, and one that stays where it is is said to wait there, never to have moved.
Confirm one as it is (**Looks Right**), correct its name or labels, or have it read again. Confirming a filed document
that is already confirmed, with nothing read, corrected, renamed or moved since (in the app or in Finder), changes
nothing and records nothing again. A file that keeps failing to be processed at all (`ingest.maxAttempts`) is parked in
the archive the same way, with status failed, so Incoming stays clean and nothing is lost; one that cannot be moved into
the archive either stays in Incoming, failed, saying why, and one that cannot be moved there because the archive's
folder is not there waits for it to be.

While Ollama cannot be reached a document waits where it stopped, an image whose text is too sparse to tell what it is
included, which is described when Ollama is back rather than filed without its description, and no other file is read
for its text until it is tried again, as each would only wait for Ollama too: a file that comes meanwhile is still
looked at, so an exact copy goes to its original and a file gone is recorded, and then waits unread, and a document read
again waits as it is; a document whose model is not installed waits in the Incoming queue, saying which model to
download and how, and looks every `ingest.modelRecheckSeconds` whether Ollama lists it, until the model is downloaded,
History saying it once; neither costs it an attempt. A server that answers, but with a failure (an error of its own or
an empty reply) each time it is asked, as a model may for one image, costs an attempt each time, and so does a request
that times out while the server still answers when asked for its version; a timeout while it answers nothing is Ollama
away. Such a document is parked as failed after `ingest.maxAttempts`, with the reason, for you to read again, rather
than tried again for ever. A description the vision model fails to give, an answer that is not one or an image the
server refuses, is noted with the document, which is read without it.

## Exact copies

A file in Incoming with the same bytes as a document in the archive (filed, waiting for you, parked after failing, left
for later, or being read, as one you put into the archive), by its SHA-256 and by that document's file as it is on disk
now, is no second document: it asks for that document to be read again. This is how you have some documents read with
another profile ([profile and effort](#profile-and-effort)): choose it, and put them into Incoming again, as they are.

- **The document is read again from the start**, with the profile in use, as [reading documents
  again](#reading-documents-again) says: from its file, found as it was until it is read, and then renamed where it is
  under the name the model gives, everything the earlier reading gave it, its labels, text and meaning, replaced at
  once. It is queued behind the files already waiting, and shows in Incoming while it waits. Reading with the model takes
  the place of having only its text read again after a rebuild of the index. A file you put into the archive whose first
  reading has not ended is left to that reading, and History says it is being read in.
- **It keeps its tags**, the folders' and those you gave it, and a copy put into a folder in Incoming, or given `--tag`,
  gives it those tags at once, before it is read; what the model gives replaces what it gave before.
- **The copy goes to the Trash**, never deleted, as the archive holds the same bytes; take it back from there. A copy
  the Trash will not take, as on a volume without one, is not tried again: it stays in Incoming, waiting for you in
  Needs You as not filed, saying why, a rescan leaves it alone, and the document is not read again. **Read Again** on
  it, once the Trash takes it, hands it over as any copy: it becomes no second document. A copy of a document you undo,
  or that leaves the archive, before the copy is found one is a document of its own; a copy still in Incoming when the
  app stops is looked at again at the next start. Once it is found one, it is handed over whatever you do to the
  document meanwhile, as though you did it after: it goes to the Trash and stays there, and a document no longer in the
  archive is not read again; a file put where the copy was is never taken for it.
- **A file in the archive**, given to `arrumatorcli ingest`, is not queued: a document's own file is that document,
  never a second one of it, and **Read Again** reads it again; one you put there is read where it is.
- **History records it once, under the document**: `bill.pdf is a copy of 2026-07-05 EDP Comercial - Fatura.pdf, which
  is read again; the copy is in the Trash; tagged “Taxes 2024” by its folder in Incoming`, with where the copy was and
  went. The reading that follows is recorded as any: renamed from the name the document has, never the one it arrived
  under. The trace of the copy's arrival (`hash`, `dedupe` with the document it copies, `tag`) is the event's; the
  reading that follows is the document's own.

A file whose bytes the archive no longer holds, because the document's file was changed or removed since it was filed,
is a new document, and so is a file you put into the archive yourself, even a copy: it is yours, read where it is.
A copy that earlier versions filed beside its original, marked as a copy, stays as it is; a new copy reads the
original again, not it.

## Reading documents again

A document of the archive is read again from the start, as a file that arrives is: for an exact copy of it put into
Incoming ([exact copies](#exact-copies)), for **Read Again** on its card (`arrumatorcli review retry <document>`), for
one the model has not labelled yet (`arrumatorcli labels unlabelled`), and for every document at once, with **Read All
Documents Again** (`arrumatorcli review retry --all`). Choose another profile, or install a better Arrumator, and this is
how the archive is read with it. A document with no file to read where the archive records it, as one missing, or a copy
an earlier version filed, cannot be read again, which is said at once.

- **From its file**, where it is when its turn comes, also when you moved or renamed it in Finder while it waited. Its
  file is hashed and its text read from it again, images described by the profile's vision model; then the model reads
  it and names it, as it would a file that arrives.
- **Found as it was until it is read.** Nothing of the document changes while it waits or is read but the tags it is
  given, and what is recorded of its file, should the file have changed: its labels, its name, its text and its meaning
  stay as they were, and search, the sidebar and search tasks find it by them.
- **Then replaced at once.** Once it is read, its file is renamed where it is, under the name the model gives, and with
  the record of that, in one step, what it reads takes the place of everything it had: its labels, those the model
  gave and those you corrected alike, but its tags; its text in the index; its meaning, every embedding it had, of
  whatever model, replaced by the profile's, or, when the reading makes none, as when the embedding model fails, those
  it had kept. Nothing of the earlier reading is left beside the new one, and a stop or a failure before that step
  leaves the document as it was, to be recorded whole at the next attempt. Its trace's `index` step says so, naming the
  embedding model, or that the earlier embeddings were kept.
- **What you do after asking wins.** A label you change once it is asked for, while it waits or is read, stays as you
  left it, and so does a name you give it ([your own changes](#your-own-changes)); leave it for later or undo it
  meanwhile, and the reading is dropped, changing nothing of it but, should you do so in the instant its file is
  renamed, the name it gave the file, which History records as set aside, and which no notification announces as
  filed.
- **A reading that gives no labels**, as when the model gives no valid answer, made none to put in their place: the
  document keeps the labels it had and its name, and waits for you in Needs You, saying why. One that keeps failing
  (`ingest.maxAttempts`) leaves its labels, text and meaning as they were, and it waits for you in Needs You as failed,
  saying why.
- **Read All Documents Again**, under Settings › Filing, asks first, naming the profile, then queues every document in
  the archive that is filed, waiting for you or set aside after failing; those you left for later stay as they are, and
  one a reading in has filed where it is, as a file you put into the archive, whose reading has not ended, is left to it.
  They give way to every file that arrives, so new files are filed first, and Incoming counts them in a line of their
  own rather than listing each; the app, or `arrumatorcli run`, reads them, and no other command does. One already
  waiting to be read is read once, and asked for again, as with **Read Again** on its card or a copy of it in Incoming,
  it is read in its turn. History records the request once, naming the profile
  and the documents, and asked again while every one of them waits, nothing; each reading is recorded under its
  document, before its filing. **Read Again** on one document is recorded so too, under it, as `Read again: <name>`,
  when it queues the reading, as it does in place of its turn in reading every document again, or of reading its text
  again after a rebuild of the index. Asked while another reading of it waits or is under way at its file, an earlier
  Read Again's, an exact copy's, or its reading in before that has filed it (as it came into Incoming, as its file was
  saved again there, or as a file you put into the archive yourself), it is read with that one, and nothing more is
  recorded. Asked once its reading in has filed it, before that reading ends, it is recorded and read once that reading
  has ended; but where that reading is at the document's file, as for a file you put into the archive, filed where it
  is, Read Again is refused until then.

## Your own changes

Moving or renaming a document in Finder is followed: the app finds the file by the identifier it stores on it, and by
the file itself, and records the move in History. A rename that changes only the case of a name, or of a folder's, is
one too: on a volume that ignores case, as the Mac's does unless formatted otherwise, the old name still finds the file,
which is the same file. It is a move only when the document's old place no longer holds that file: a copy made in Finder
keeps the identifier, and is a document of its own, as is a file another archive filed, even when the original is moved
at the same time, as the original keeps what tells a file on disk apart, its inode, and a copy has its own. A file you
put into the archive yourself, at the top or in a folder of yours, is read and labelled where it is, under its own name,
once it has stopped changing (`watcher.stabilityPollInterval`, `watcher.stabilityRequiredPolls`), as Incoming waits for
one; it is given an identifier of its own. A folder of yours renamed or moved in the archive moves the documents in it,
and History records each one's move, as it records a document you moved on its own. One that has not stopped changing
after `watcher.stabilityMaxWaitSeconds`, such as a file copied slowly or a library an app keeps open, is said once in
History to be taking long, is looked at every `watcher.awayPollSeconds` from then on, and is taken once it stops, also
after the app was stopped and started again meanwhile; so is one in Incoming, but for a stop, after which it is taken at
its next change. A folder you rename, or move or copy into the archive, is looked through, and a package, a folder macOS
shows as one document (an `.rtfd`, a Pages document), is one document. A file removed from the archive, or in a folder
removed, is marked missing; put back, anywhere in the archive, it is as it was, waiting for you or left for later if it
was. Nothing you do in Finder is undone by the app.

The app sees these changes as macOS reports them. A change it had not finished taking in when it quit, or crashed, is
seen again at the next start, and so is one it could not take in, up to `ingest.maxAttempts` starts, after which it is
given up; History says so when it first fails and when it is given up, naming where. When macOS says it lost track of
changes in a folder, the app looks at that folder again. The archive's own folder renamed, removed or on a disk that
went is away: nothing in it is marked missing, nothing is filed into it and nothing is made again where it was. Once it
is back, the same folder, also on a disk attached again, the work goes on by itself, and the app looks at the whole
archive again. Another folder put at its path is taken as the archive, which History says once, and is looked at whole:
a document whose file is not in it is missing, and one recorded where another document's file now is, too. The earlier
folder back is said to be back. Either way, what its record files hold is merged with what was kept meanwhile, never
taken over it.

Reading a document again (`review retry`, **Read Again**, **Read All Documents Again**, an exact copy of it put into
Incoming) labels and names it again where it is, from its file, keeping its tags ([reading documents
again](#reading-documents-again)). You win over a reading under way: a label you change until it is filed, from when
the model begins to read a file, or from when you asked for a document to be read again, of any kind, as a sender
corrected or a tag given or taken away, stays as you left it, and the reading fills in only the kinds you did not
touch. A reading that gives no name leaves it
the name it has, and one that names it as it is named, but for case or the collision suffix (`naming.collisionFormat`) a
taken name gave it, moves nothing. Only a document in the archive can be undone: one already undone, or left in
Incoming, is refused, and its file keeps its name. A document you undid is back in Incoming, held, and a rescan leaves
it there while the file is that document; read again, it is filed at the top of the archive. History records where its
file was and went as the disk spells both paths. Another file put in its place, as a scanner saving under the same name,
is taken as a new arrival, and the one undone is missing. This is unlike a document left in Incoming as failed, whose
file saved again is that document arriving again: a failed one is the app's attempt at the file there, which a new save
of it takes up again, while one you undid or left for later is your decision about the file it was, which a file put in
its place does not inherit, with its tags and its History.

## Search tasks

Rather than choosing labels one at a time, you can ask for the documents you need in your own words, in any language:
"electricity and water bills from 2025, by sender", "everything the tax authority sent about last year's return". The
request becomes a **task**, which joins a queue of its own; the tasks in it are read one at a time, the oldest first (a
task whose request was being read when you quit, or when a command reading it was killed, is read first at the next
start, or once the app next looks), by the reading model of the task's profile, with a prompt of the app's own
(`search-system.md`) and the task's effort ([below](#profile-and-effort)). The model is shown the labels the archive
already uses of the kinds the effort's `promptLabels` names, the most used first, so it asks for them as the archive
writes them, today's date, so "last year" and "this month" mean something, and the language your request is written in,
as Apple's NaturalLanguage tells it when it is sure of one (`extraction.languageMinConfidence`; for a request of
fewer than `extraction.languageShortTextWords` words, which looks like several languages, as "Seguro auto" does,
`extraction.languageShortTextMinConfidence`), so the task is named in it; a name it is just as sure is in another
language goes back to the model once, named, and stands when given again. The prompt must fit the model's context
(`analysis.numCtx`) beside the answer's length, the effort's `numPredict`, as a longer one is not read whole: its length
in tokens is estimated at `ollama.charsPerToken` characters a token, an estimate that fits text in Latin script and may
not others. When it would not fit, the least used labels are left out first, and the trace says how many; it also keeps
how many tokens Ollama counted the prompt took. When Ollama counts it filling the context, as when the estimate was
wrong for text in another script, it is fitted again at the characters a token Ollama's count shows it held and asked
again, as often as `ollama.refitAttempts` says, and the trace says so, with every call; it says too when the context was
still full. It
answers in a fixed schema: the labels of each kind to look for, each with the words of the request that ask for it,
words the text must contain for what no label says, the kinds to arrange what is found by, each with the words that ask
for that, and a name for the task. The
answer is untrusted input, checked as a document's answer is: each label must be a label of its kind (a date, period or
deadline may be a year, a month, a day or a span of them, and an amount a number alone, `54.21`), at most
`tasks.maxValuesPerKind` of a kind and
`tasks.maxWords` words. Every kind a task asks for leaves documents out, so a label nobody asked for, such as the
country all your documents are from, would silently hide what you wanted: a label is kept only when every word the model
quotes for it is a word of your request (words as NaturalLanguage tells them apart, so a request in Chinese or Thai,
written without spaces, is read word by word too), but not when every one of them is already quoted by a label of another
kind, as "Portugal" in "invoices from Portugal" asks for a country, not for documents written in Portuguese, nor, for a
label of a kind the documents are arranged by, when they are only the words that ask to arrange them, as "по
отправителю" ("by sender") arranges them by sender and asks for none, while "invoices" in "invoices by sender" still
asks for invoices. A label whose words hold what labels of other kinds ask for, two things or more, as a sender quoted
by "квитанции за электричество" holds the type's "квитанции" and the topic's "электричество", goes back to the model,
named with what it holds, and is kept only when the model gives it again. A word is kept only when it is in your
request, no label already asks for it and it is not just the words that ask to arrange the documents; a word inside
those words that is not all of them, as "Lisbon" when the model quotes all of "contracts mentioning Lisbon by sender"
as asking to arrange them, goes back to the model, named, and is kept when given as a word again. Each time a prompt
is fitted again to the context, the model is asked afresh, so what was sent back before goes back again. A document
needs one label of a kind but every word, so "insurance" in "bills for electricity, water,
insurance or rent" is one more alternative, not a word every bill must hold: a word your request writes between the
words two labels of one kind quote, or that carries their list on, within `tasks.alternativesGap` words of one of them
or of another such word, goes back to the model, named, to be given as a label of that kind; given as a word again, it
is kept, as the model's answer to being told. Where a label's words stand is told by those your request writes once, so
"da" in "faturas da EDP e da Galp que falam da multa" places nothing, and "multa" is asked of every document. What is
dropped, and why, is in the task's trace. An answer that
cannot be read, gives an alternative as a word, a label whose words hold other labels', a word inside the words that
arrange the documents, or is left asking for nothing at all, goes back to the model with what was wrong, as often as the
effort's `repairAttempts` says; no other model is asked in its place. A request the model never answers validly fails
the task, with the reason, and so does an answer that takes longer than the effort's `timeout`
([below](#profile-and-effort)). While Ollama cannot be reached, or does not answer in time and answers no probe either,
a task waits in the queue, as a document does, spending nothing, its one trace taken up again by each attempt, and the
tasks behind it with it, until it is tried again; a server
that answers with a failure, or answers a probe but not the request in time, fails the task with the reason. A task
whose reading model is not installed fails, naming the model, until it is downloaded and the task's documents are found
again (**Find Again**), and one given a profile the settings no longer list fails saying so until it is given another.

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
filed. Finding them again keeps the documents you added and leaves out those you took out. A change to its request,
effort or profile while it is read, and removing it, stop that reading at once, and removing it stops the answer to its
question too.

**Exporting.** A task's set is copied into a new folder named after the task, in a folder you choose outside the
archive and Incoming, with a folder for each group of the first kind it is arranged by, a folder inside it for each
group of the next, and the documents at the bottom under their own names; or into a ZIP archive of that folder, whose
names are written with composed accents ("João", not "Joa" and an accent) and marked as UTF-8 (the ZIP format's language
encoding flag), so `unzip`, Python and Windows show "João" and "ФКП Росреестра" as Finder does, rather than reading them
in an old DOS code page. The archive is packed elsewhere and put in your folder only once it is whole, so an export that
fails, a disk full or a file that cannot be read, leaves nothing there.
Documents are copied, never moved, and nothing already there is written over: a name that is taken gets the collision
suffix (`naming.collisionFormat`). A folder is named after its label as a file name is cleaned, so a label can never
place a file anywhere else, and the documents without a label of the level's kind go into `tasks.withoutLabelFolder`
(`No sender`); two groups whose folders would be named alike, however cased, each get a folder of their own, the second
with the collision suffix. Each export is kept with its task: when, as what, where, and where each document went inside
it; a document whose file is not where the archive has it, or that could not be copied or given its folder, is left
out, with the reason, and the rest of the export is still kept.

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
meaning, as search finds them, in the app and from a terminal alike; then the rest by their own date, the newest first.
In that order each is shown with its text, its start and its end cut to `conversation.documentChars` as a document is
read, while the text fits in `conversation.contextChars`; a document whose text does not fit, or has not been read
yet, is listed by its name, date and labels, at most `conversation.maxListed`. Once that many are listed, a document
not read yet is passed over, and the first whose text is too long for the room left ends the choice; the answer is told
how many more there are. The text of no more documents is read than are shown or listed, and one more, however large
the set: which have a text is told without reading it. A set the context holds is shown whole. The answer is also shown
how many documents the set holds, every one of them part of the question when it asks about "these" documents, the
conversation so far, the latest questions and answers up to `conversation.historyChars`, the latest cut to fit when it
alone is longer, today's date, and the language the question is written in, as a request's is told (above), which it
answers in whatever language the conversation before was in. It is never shown your tags. A question is at most
`conversation.maxQuestionChars` long. The whole prompt must fit the model's context (`conversation.numCtx`) beside the
answer's length, the effort's `numPredict`, estimated as a request's is (above): when it would not, the exchanges
before the latest are left out, then the last documents shown with their text are listed by name instead, then the
latest exchange is left out, then the last names, and the trace says what was, with how many tokens the prompt took; a
question that would not fit even then fails, saying so. A prompt Ollama counts filling the context is fitted again at
what it counted and asked again, as a request's is (above), and the trace says so; an answer to one that still filled
it says, beside it, that the model may not have read all it was shown. A repair, which sends back the
answer that was not valid, sends back as much of it as fits, and the trace says how much was left out.

**The answer** comes in a fixed schema: the answer, in Markdown, in the language of the question unless it asks for
another, naming documents by their names, working out a total or a comparison the question asks for over every document
of the set it is about, amounts in several currencies totalled each currency apart, saying when documents disagree, and
stating nothing the documents do not, such as that a
contract complies with a law; the documents it draws on, by their numbers, which it is shown only for this; and, when
you asked for more documents, a request for them, which it says it is looking for. It is untrusted input: a document it
says it draws on is kept only when it is one it was shown, as a citation is checked against its sources, a number it
writes in the answer for a document it was shown is given as that document's name, in an answer cut off too, unless
Markdown makes it a link, a reference or code of its own, and an answer without words, one that only begins an answer,
or one that cannot be read, goes back to the model with what was wrong, as often as the effort's `repairAttempts` says.
Its request for more documents is read as a task's request is, and names a kind of document only when your questions
do: a kind it names that neither this question nor an earlier one of the conversation writes, in any inflection, as
attestations for "anything about the dentist", goes back to the model, named, and is kept when given again.
An answer only begins one when its Markdown says so, in any language: nothing but headings and rules (a paragraph all in
bold with a rule after it is a heading too), unless a heading carries a figure ("# 340 € in total"), or one paragraph or
list item, alone or under headings, ending with a colon, announcing what never follows. An answer that gives something
before a last line ending with a colon, as a document's field ("Assinatura:") or a total ("合计：") can end it, is an
answer. It is shown as it is written: the card shows the answer as the model writes it, its paragraphs, headings,
lists, quotes, code and rules as such, a table as its rows of plain text with the columns aligned, emphasis the model
opened and never closed as its words without the asterisks (two or three that open emphasis and are not closed, never
those of a masked number, "****1234" or "***1234", or a power, "2**10": a run before a digit always stays),
**Thinking…** while a model that thinks has written nothing yet, that it waits for the model to begin while the model
loads or reads documents first, and how long it has taken once
that is more than a moment. Nothing in an answer can act: a link shows as its words followed by its address, and an
image as its words, so a document that asks the model to end its answer with a link that would carry the document's data
elsewhere gets nothing clickable. An answer cut off at its length limit, the effort's `numPredict`, is kept as far as it
came, saying it was cut off: ask for less, or ask again at a lower effort, which thinks less and so leaves more of the
limit to the answer. An answer that takes longer than the effort's `timeout` fails the question, keeping what came of
it. While Ollama cannot be reached, or does not answer in time and answers no probe either, a question waits in the
queue, as a document does, with the questions behind it, saying so and when it is tried again, the last of
`ingest.retryDelays` later, on its card,
its task's row and from a terminal, rather than being asked again meanwhile, by the answer or by what it is shown, which
looks for the documents alike to the question in meaning, its one trace taken up again by each attempt; a server that
answers with a failure or answers a probe but not the request in time, a reading model that is not installed, or a
profile the settings no longer list, fails it with the reason. A question being answered when a command answering it was
killed is answered again in its place.

**Finding more.** Ask for documents beyond the set, such as "find the contract these invoices are billed under", and the
answer writes a request for them in your words, with what the documents told it: a sender, a reference, a period, and a
kind of document only when you named one. It looks only when you ask it to. That
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
conversation, and each answer is traced: what it was shown, and whether the question's meaning ordered the documents as
well as its words or, when it could not, why (the `context` step), its prompts and the model's answers
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
changes, and those embedded by another model are found by meaning again only once they are read again: **Read All
Documents Again**, under Settings › Filing, reads them with the profile now in use, as putting one into Incoming again,
as it is, does ([reading documents again](#reading-documents-again)). A task is
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

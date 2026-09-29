# How Arrumator works

This is how Arrumator decides where a document belongs, what it learns from you, and how the folder tree takes
shape. [Using Arrumator](using-arrumator.md) covers the app and its settings. [Storage](storage.md) covers where
everything is kept, and [Evaluation](evaluation.md) the measurements behind these choices.

## How a file is handled

```text
new file in Incoming ──► wait until it stops changing ──► hash (exact duplicates → Duplicates)
   ──► extract: PDFKit text, Apple Vision OCR (en/ru/pt), textutil (doc/docx/rtf/odt/html), CoreXLSX, PPTX, e-mail,
       archives, media metadata, Quick Look previews, local vision model for photos; language, dates, identifiers
   ──► label: the local model picks out the document's signals (whom and what it concerns, its jurisdictions and
       languages) with a prompt of its own; they become the document's searchable labels (below)
   ──► learned evidence: known senders (by learned identifiers, e-mail/web domains, names),
       similar past filings (bge-m3 embeddings), rules formed from usage
   ──► confident?  ── yes ─► place directly; the model is only asked for the file name, as the logic says
                   └─ no ──► the local model identifies the document and decides from the archive's logic (your
                             prompt) and the document alone: who it is from and whom it is about; the path, as many
                             levels as the logic describes, each named and described; whether it goes in a year
                             folder; the file name. It is shown no folders: shown any, even broad ones, a model
                             copies them whether they fit or not (an older arrangement's, another sender's that looks
                             alike, one area for everything). The app then resolves the path by identity (below),
                             creates the rest and calibrates confidence.
   ──► file it (create folders on demand, name it, keep the original name in an extended attribute); when the
       chosen folder was removed while the model decided, decide again against the tree as it is now
   ──► learn: every placement becomes a memory; confirmed/confident ones form rules; folder context is refreshed
```

OCR runs on Vision's default device, the Neural Engine or GPU. When that fails, as it can when the Neural Engine's
model does not compile, the page is read again on the CPU, and so is every later page until the app restarts. The document's
trace records which device read each page.

Uncertain documents wait in **Needs review** (created only when first needed). Moving a file in Finder, choosing a
folder in the app, renaming, undoing: all are recorded as corrections and change future decisions. Senders gain
other names, and folders' learned context updates.

## Labels: what a document is about

Folders hold a document in one place; labels let it be found from every side. Every document that arrives is read by
the local model a first time, before anything is decided about it, with a prompt written for this alone
(`labels-system.md`). The model picks out the document's *signals*, the few facts someone looking for it later would
search by, and each one becomes a label of one of four kinds:

- **Subject**: a person or organisation the document concerns: whom it is addressed to, whose it is, or whom it is
  about (a customer, a patient, a taxpayer, a company), named as the document names them.
- **Object**: a specific thing it concerns, with what identifies it: an apartment and its address, a car and its
  plate, a supply point, an account, a policy.
- **Jurisdiction**: the countries, and regions or cities where they matter, whose law, authority or administration the
  document falls under: where a tax is due, a contract is governed, an ID was issued.
- **Language**: the languages it is written in, as ISO 639-1 codes (`pt`, `ru`, `en`).

The kinds follow the metadata records keep in archival practice: the parties a record concerns, its coverage in the
sense of the jurisdiction it belongs to, and its language ([sources](organizing-principles-sources.md#sources-for-labels)).

The model answers in a fixed schema; the app checks the answer the way it checks every model answer. A label is kept on
one line and cut to `labels.maxValueChars`, repeats are dropped however they are written, each kind keeps its first
`labels.maxPerKind`, and a language becomes its ISO 639-1 code, whether the model wrote `pt`, `por` or `Portuguese`.
An answer that cannot be read goes back to the model once, as for decisions. The archive's logic plays no part:
labels say what a document is about, however the archive is arranged, so changing the logic never changes them.

Labels are the document's. They sit in its entry in `_documents.md` and survive a rebuild, and each kind is a field of
the search: `jurisdiction:portugal`, `subject:"maria silva"`, `object:AA-12-BB`, `language:portuguese` (a language is
found by its code and by its English name). A plain search finds labels too. A document's card lists them.

When the model gives no valid answer, the document is filed anyway, without labels, and the history says so; when it
finds nothing worth a label, the document is labelled with nothing, which is not the same thing. While Ollama cannot
be reached the document waits at this step, and a missing model holds it, as for deciding. An exact copy of a filed
document is not read again, so it is not labelled either. A document without labels (one filed before documents were
labelled, or one the model gave no answer for) is labelled when it is decided again (`arrumatorcli review retry`), or
with `arrumatorcli labels <document> --again`; `arrumatorcli labels --unlabelled` labels all of them.

## Senders and rules

**Senders are what rules are built on.** A sender is whoever a document comes from (EDP, the tax authority, a bank, a
landlord). The model names the sender of each document, and filing it links the document to a sender the app knows, or
to a new one. A sender collects:

- its other names;
- the identifiers that are only ever on its documents: a tax number, IBAN or account number seen in at least
  `learning.stableKeyMinFilings` trusted filings;
- its e-mail and web domains;
- its usual folder.

Rules form from a sender's trusted filings: ones you confirmed or corrected, or filed with high confidence.
`learning.ruleMinSupport` of one document type in one folder make "EDP · invoice → Home / Utilities", and
`learning.correspondentRuleMinSupport` in one folder with none elsewhere make "EDP → Home / Utilities". A rule applies
to a new document only when its sender is recognised there: by an identifier first, then a domain, then a name. A
reliable rule then files it without the model deciding. Otherwise the model decides by the logic alone. Where the
logic gives senders folders of their own, a known sender's document still joins its sender's folder (see
[the folder tree](#the-folder-tree-grows-with-your-documents)), and rules and similar past filings weigh in on how sure
the decision is.

A document almost identical to one filed with confidence before (`learning.directPlacement.knnMinSimilarity`), such as
next month's bill, joins it without the model deciding where it goes. A model names a recurring document differently
from one month to the next, and following its predecessor keeps the two together.

Rules keep learning after they form. Each filing that agrees with a rule raises its support, so it becomes more
trusted. Filing a document somewhere other than where a rule points counts against it, and two disagreements switch it
off. Approving what the app proposed is agreement, not disagreement. A rule the app switched off comes back on its own
once fresh filings restore its reliability; one you switched off by hand stays off.

Every file is named by the model, following the logic: the naming style is part of the logic, and there is no name
template to set. A document that learned rules place without asking the model where it goes is still named that way,
with a short request for the name alone. If the model gives no usable name, the file keeps the name it arrived with.

### Forgetting

Anything learned can be forgotten, from the Learned page, a document's card or `arrumatorcli forget`:

- **A document as an example of its folder.** It stops counting as evidence for future decisions.
- **A rule.** It stops placing documents, and the same filings never form it again.
- **Another name for a sender.** The name is no longer matched to that sender.
- **A whole sender.** Its names, identifiers and usual folder are forgotten, together with the rules about it.

Forgetting something takes it off the Learned page, and on a document's card the lesson is struck through. Each time the
app forgets something, whether you asked or you undid a filing, it is recorded in History, not among the lessons.

## Logic: you decide how the archive is organised

**Logic** is the prompt the model follows when it decides where a document goes and what it is called. Each archive
has exactly one, kept in the archive itself as `System/Logic/_logic.md`. It comes first in every decision, and
learned rules, past filings and corrections only advise it: when they disagree, the logic wins. A new archive starts
with the built-in logic, *Organizing principles*, which condenses established records-management practice (NIST,
university research-data guides, paperless-ngx; sources in [organizing-principles-sources.md](organizing-principles-sources.md)).
Until you change it, it is kept up to date with each new version of the app. You can edit it and reset it to the
original.

Edit the logic in place on the Logic page, or open `_logic.md` in any editor: the text after its front matter is the
prompt, and a file holding nothing but a prompt works too. The app reads an edit made in the file straight away. New
documents follow the logic from then on. Then:

1. **Try it on a few documents.** The app asks the logic where documents from across the archive belong and
   shows each decision on the Logic page as it is made, the newest first; click one to see why the logic chose it.
   You do not have to wait for the end:
   - **Stop Here** interrupts the document being decided and makes what has been decided so far the plan; the
     documents not reached stay where they are.
   - **Discard** throws the trial away, so the logic can be changed straight away.

   Nothing moves unless you apply the plan. Documents the logic would move are ticked; untick any that should stay.
   When the logic was unsure but still suggested a place, the document is listed unticked: tick it to take the
   suggestion, and the move is recorded as your decision. When nothing would change, the plan closes on its own and
   says so, so the logic is never left locked by a plan with nothing in it.
2. **Reprocess everything.** Every processed document is decided again with the logic. Learned rules no longer
   short-cut the decision here, and a document's own past filing is not offered as evidence. Documents you placed or
   confirmed yourself are left out unless you include them. You review the plan (which documents move where, and
   which folders appear; documents keep their names) and leave out anything you want to stay put. Applying it moves
   the files, creates the folders, removes every folder left empty and lets rules follow their documents to their
   new folders.

A topic's home is where the logic puts it: when the logic puts payslips under "Work", a "Payslips" folder under
"Home" is not their home, and reprocessing moves them. Nothing is moved while a plan is being made, and the logic
cannot be changed until the plan is applied or discarded, so one plan never mixes two kinds of logic. Every decision
records which logic made it.

### Each archive is organised its own way

Because the logic belongs to the archive, two archives can be arranged in two different ways. Choose another archive
under Settings › General, with **Switch Archive…** in the menu at the foot of the sidebar, or with
`arrumatorcli archive switch <folder>`. From then on documents are filed there, following that archive's logic, folders
and rules, and files still waiting in Incoming go there too. A folder never used as an archive starts with the
built-in logic; switching back to an archive brings back everything it had. Each archive has an index of its own, so
nothing learned from filing into one ever advises the other. A running app keeps its archive when the command line
switches, until it is started again.

A folder is removed as soon as it holds no documents, whether after a rethink or after you move or undo the last
document in it. Only the app's own `_about.md` and system leftovers such as `.DS_Store` may remain in it. The folder's
description stays in the database, and a folder that still holds any file is never touched.

## The folder tree grows with your documents

Nothing is pre-created. The first document creates the first folders. The tree takes the shape the archive's logic
describes, as many levels deep as it asks for (up to `taxonomy.maxDepth` in `pipeline.json`), with folders named as
the logic names them. The built-in logic keeps to two levels, `Money & Taxes/Taxes (Portugal)/2025/…`, and a logic of
your own can ask for `Portugal/Acme Lda/Banking/Santander/2025/…`.

For every document the model identifies who it is from (its sender) and whom it is about (its subject), and describes
its home as a path from the top of the archive. It is shown no folders, so a folder is never taken because its name
looks right, and a logic you change really changes the arrangement. The app works out which level of the path stands
for which party: the level named like the sender, the one named like the subject, as written or across languages
(`classification.placementGuard.partyAbove`). It does not ask the model, whose labels for its levels proved
unreliable. The app puts the path onto the tree, keeping misfilings down:

- **A sender's folder is recognised by its sender, not its name.** Senders are recognised by what identifies them (a
  tax number, an IBAN, an e-mail or web domain) before their name. A known sender's documents join the folder its
  documents are in (one the current logic made), however the model words or arranges the path this time, but only
  under the subject the document is about: a bank serving your company and you has a folder under each, and a document
  that does not say whom it concerns is not assumed to be either's. Inside a sender's folder, a document joins the
  folder holding the sender's documents of the same type. A folder holding another sender's documents is never reused,
  and a document whose path would put it there waits in Needs review.
- **When the document and the model disagree about the sender** (an identifier in it belongs to one known sender, and
  the model names another that nothing in it shows), the document waits in Needs review. A document that lists other
  parties' identifiers, such as a statement's debits, is no disagreement when the sender the model names shows too.
- **A topic** is an existing folder of the same name there, or of a name so close it would be a duplicate. Otherwise
  the name the model chose freely is mapped onto the folders already there. The few most alike beside it are offered
  to the model in one question, each described with a few of its documents, and it picks the one that already holds
  what this folder would, or none. They are found by name, which finds "Finanças" for "Finance", and by name with
  description, which finds "Household Expenses" for "Utilities" (`classification.placementGuard.offerAbove`,
  `classification.placementGuard.choices`, `classification.placementGuard.rankFusionK`). It is asked a few times per
  document at most (`classification.placementGuard.maxJudgements`); "unsure" keeps it apart, since a second folder is
  easier to put right than a misfiled document. Names whose qualifiers differ ("Taxes (Portugal)", "Taxes (Russia)")
  are never the same folder.

Each folder the model makes records in its `_about.md` what it stands for and which logic made it. The model also says
whether the document goes in a year folder, so a bank's statements can be kept by year while its account agreement
sits in the bank's folder. A logic that spells the year out as its last level ("… / Institution / [YYYY Year]") gets
exactly that: a year at the end of a path is its year folder. Folder names are cleaned the way file names are, so a
name such as "Global / Cross-Border" becomes "Global - Cross-Border".

Each folder has an `_about.md` whose description the model reads when deciding; a machine-maintained block at its end
lists what actually lives there (recent file names, usual senders). Edit descriptions freely: your text is never
overwritten. `_INDEX.md` at the archive root lists the whole tree. Folders made by earlier versions keep their numbered
names until reprocessing moves their documents into the tree the logic describes.

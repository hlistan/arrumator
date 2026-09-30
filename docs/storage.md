# Storage: the archive is the record, SQLite is the index

Everything Arrumator knows that it could not work out again lives in Markdown files inside the archive. Each archive
has a SQLite database of its own, an index over those files plus caches of things that can be recomputed. Losing or
corrupting an index costs time, never information: the app rebuilds it from the archive.

This is the pattern of plain-text vaults such as Obsidian, whose notes are the source of truth and whose metadata cache
is disposable and rebuilt from the files ([Obsidian help: how Obsidian stores data](https://help.obsidian.md/Files+and+folders/How+Obsidian+stores+data)).
Documents are filed at the top of the archive, each directory holding documents lists them beside them, and the
history and your rules for labels sit in one `System` folder at the top of the archive. The app makes no other folders.

## What lives where

| What | File | Contents |
|---|---|---|
| The documents in a directory | `<directory>/_documents.md` | One entry per file in that directory: identity, original name, checksum, size, content type, pages, status, the labels that describe it (each a kind and a value; absent until the model has labelled it), and how it was read: the file name the model gave it, the model, and why it waits for you, if it does. The table below the data shows each file's date, sender, type and other labels. |
| History | `System/History/_<year>-<month>.md` | One line per event, newest last. |
| Rules for labels | `System/_labels.md` | Your decisions about labels ([how](how-it-works.md#keeping-labels-one-vocabulary)): each rule's number, kind, label, what it decides (`merge`, `ignore` or `keepApart`), the other label of a merge or of a pair kept apart, and when it was made. There is no file while there are no rules. |

Every file starts with YAML front matter holding the exact data, followed by a Markdown rendering for people. The front
matter is what the app reads; the rendering is regenerated on every write.

A document's entry sits next to the document: `_documents.md` lists the files in its own directory by name. Renaming or
moving a directory of yours therefore never touches a record, and a file moved in Finder is found again by the
identifier Arrumator stores on it as an extended attribute.

Identifiers in the records are the database's own: document and event numbers are written into the files and restored
exactly on a rebuild, so references between records keep working.

## One index per archive

The index of an archive is `~/Library/Application Support/Arrumator/Indexes/<name>.sqlite`, named after the first bytes
of the SHA-256 of the archive's path. Switching archives stops everything working on the one in use, writes its record
files, and opens the other archive's index in its place: its documents and history. Files waiting in Incoming are taken
off the old archive's queue and filed into the new one.

A folder that has never been an archive gets a new index. If it already holds record files, such as a `System` folder
or a `_documents.md` at its top, the index is rebuilt from them; otherwise it starts empty. An archive moved to another
path is the same case: its new index is rebuilt from its records.

Earlier versions kept one index, `arrumator.sqlite`, for whichever archive the settings named. The first start of this
version moves it into place as that archive's index, so nothing it held is lost.

## What the database only indexes or caches

- **Text and search**: extracted text and the full-text index are extracted again from the documents; the labels'
  columns of the full-text index are filled from the entries, without asking the model again.
- **Embeddings** of documents are computed again with the embedding model.
- **The job queue** is rebuilt by looking at the Incoming folder.
- **Positions in the file-system event stream** and similar bookkeeping.

Some working state is deliberately not kept in files and does not survive a rebuild:

- **Traces**, the full exchange with the model for each document. What the model read the document as, and its
  labels, are in the document's entry.

## Keeping files and index together

1. A change is made in the database. Triggers on every recorded table mark the record files the change touches, in the
   same transaction, so no code path can forget one and a mark survives a crash.
2. As soon as the transaction commits, the app writes each marked file from the index, atomically: to a temporary file
   in the same directory, then renamed over the old one, which APFS guarantees is all or nothing. The file's SHA-256 is
   kept in the index. A file changed again while it was being written stays marked and is written again.
3. When the app starts, and whenever the archive watcher sees a record file change that the app did not make, every
   record file whose checksum differs from the one the index holds is read back. That covers edits made by hand,
   files synchronised from another Mac, and anything else that changed the files behind the app's back.
4. A file edited by hand is never overwritten. If the index has changes of its own for the same file, the edit is merged
   in: what the file changes wins, and what the index added is kept. Otherwise the file replaces what the index held
   for it. Removing a document's entry never removes the document; its entry is written back. A rule for labels
   changed by hand is followed by readings from then on; the documents it concerns keep the labels they have.

The window in which a change exists only in the database is the time it takes to write one file, and a mark left by a
crash in that window is written at the next start.

## Rebuilding

The app rebuilds the index when the database is missing, cannot be opened or cannot be migrated, and on request
(`arrumatorcli rebuild`, or Settings › Advanced). A database that cannot be opened is moved aside, never deleted, as
`<name>.sqlite.unreadable-<date>`. That only happens when the archive has record files to rebuild from; otherwise
the app stops and says why, rather than starting with an empty index. A rebuild on request first writes every change
not yet in the files. Documents are then updated in place from their entries and keep their numbers, so their cached
text, embeddings and traces stay attached; everything else recorded in files is replaced by what the files say.

A rebuild reads every `_documents.md`, the history and the rules for labels. Documents whose file is not where their
entry says are looked up by the identifier on the file. Files that have no entry, at the top of the archive or in a
folder of yours at any depth, are taken in where they are and read by the model; the `System` folder and an Incoming
folder kept inside the archive are left out. Then, in the background and giving way to new arrivals, each document's
text is extracted again and its embedding recomputed. The model is not asked again: labels come back from the entries.
Search by words and by meaning fills in as that proceeds; filing works from the start.

## Archives from earlier versions

Earlier versions filed documents into folders, kept a `_about.md` in each and an `_INDEX.md` at the top, and kept the
archive's logic, rules, corrections, filing memories and senders in the `System` folder. The first start of this
version migrates the index: documents stay where they are, and what the decision recorded for each said of it becomes
its labels (its sender, type, date, reporting year, topic tags and language as `sender`, `type`, `date`, `period`,
`topic` and `language`) while the name the model gave it, the model and why it waited for you become how it was read.
Titles are not kept. The tables of folders, rules, filing memories, corrections, proposals, logic, rethink plans and
senders are dropped, as are history events of kinds that no longer exist. Every record file is written again in the new
shape. Those older files, `_senders.md` among them, are left alone in the archive and no longer read. A `_documents.md`
entry written by an earlier version that a rebuild reads without that migration (on another Mac, say) comes back
without labels; its document is labelled when it is read again (`arrumatorcli labels --unlabelled`, once its text has
been read again). Read any document again (`arrumatorcli review retry`) to give it the full set of labels.

# Storage: the archive is the record, SQLite is the index

Everything Arrumator knows that it could not work out again lives in Markdown files inside the archive. Each archive
has a SQLite database of its own, an index over those files plus caches of things that can be recomputed. Losing or
corrupting an index costs time, never information: the app rebuilds it from the archive.

This is the pattern of plain-text vaults such as Obsidian, whose notes are the source of truth and whose metadata cache
is disposable and rebuilt from the files ([Obsidian help: how Obsidian stores data](https://help.obsidian.md/Files+and+folders/How+Obsidian+stores+data)).
The app's own files sit together in one `System` folder at the top of the archive, apart from the user's folders.
It is known by its `_about.md`, whatever it is called: archives started by earlier versions have it as `00-09 System`,
with `05 Learned`, `06 Logic` and `07 History` inside.

## What lives where

| What | File | Contents |
|---|---|---|
| A folder | `<folder>/_about.md` | Code, name, description, year folders, what it stands for in the logic that made it (`kind`: sender, subject or topic) and which logic that was (`logic`), what the app learned about it. |
| The documents in a directory | `<directory>/_documents.md` | One entry per file in that directory: identity, original name, checksum, sender, type, date, title, language, tags, status, and the decision (who decided, how sure, why, with which logic). |
| Senders | `System/Learned/_senders.md` | Names, other names, identifiers, e-mail and web domains, usual folder. |
| Rules | `System/Learned/_rules.md` | Conditions, target folder, evidence, whether on, confirmed or forgotten. |
| Corrections | `System/Learned/_corrections.md` | Every time you moved, renamed, approved or confirmed a document. |
| Filing memories | `System/Learned/_memories.md` | Which document taught what about which folder, and how much it counts. |
| Logic | `System/Logic/_logic.md` | The archive's one logic. The prompt is the file's body, so it can be edited in any editor. The front matter holds the checksum of the built-in text the logic follows, if it follows one. |
| History | `System/History/_<year>-<month>.md` | One line per event, newest last. |

Every file starts with YAML front matter holding the exact data, followed by a Markdown rendering for people. The front
matter is what the app reads; the rendering is regenerated on every write. The logic file is the exception: its body is
the prompt itself. A logic file with no front matter at all is read as a prompt the user wrote.

Logic that still has the checksum of the built-in text it was set from follows that text: each new version of the app
brings its own. Any edit, in the app or in the file, changes the checksum, so the app never writes over it; editing it
back to the text it came from, or resetting it, makes it follow the app again.

A document's entry sits next to the document: `_documents.md` lists the files in its own directory by name. Renaming or
moving a folder therefore never touches a record, and a file moved in Finder is found again by the identifier Arrumator
stores on it as an extended attribute.

Identifiers in the records are the database's own: document, sender, rule and memory numbers are written into the
files and restored exactly on a rebuild, so references between records keep working.

## One index per archive

The index of an archive is `~/Library/Application Support/Arrumator/Indexes/<name>.sqlite`, named after the first
bytes of
the SHA-256 of the archive's path. Switching archives stops everything working on the one in use, writes its record
files, and opens the other archive's index in its place: its folders, documents, logic, what was learned and its
history. Nothing learned from filing into one archive ever advises another, as rules and filing memories name folders
that only exist in their own archive. Files waiting in Incoming are taken off the old archive's queue and filed into
the new one.

A folder that has never been an archive gets a new index. If it already holds record files, such as a `_logic.md`, the
index is rebuilt from them; otherwise it starts with the built-in logic. An archive moved to another path is the same
case: its new index is rebuilt from its records.

Earlier versions kept one index, `arrumator.sqlite`, for whichever archive the settings named. The first start of this
version moves it into place as that archive's index, so nothing it held is lost.

## What the database only indexes or caches

- **Text and search**: extracted text and the full-text index are extracted again from the documents.
- **Embeddings** of documents, memories and folder descriptions are computed again with the embedding model.
- **The job queue** is rebuilt by looking at the Incoming folder.
- **Positions in the file-system event stream** and similar bookkeeping.

Some working state is deliberately not kept in files and does not survive a rebuild:

- **Traces**, the full exchange with the model for each decision. The decision itself, with who made it, how sure it
  was and why, is in the document's entry.
- **An open rethink plan.** Nothing has moved while a plan is open; start the trial again.
- **Pending suggestions**, which the app makes again as it learns.

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
   for it. Removing a document's entry never removes the document; its entry is written back.

The window in which a change exists only in the database is the time it takes to write one file, and a mark left by a
crash in that window is written at the next start.

## Rebuilding

The app rebuilds the index when the database is missing, cannot be opened or cannot be migrated, and on request
(`arrumatorcli rebuild`, or Settings › Advanced). A database that cannot be opened is moved aside, never deleted, as
`<name>.sqlite.unreadable-<date>`. That only happens when the archive has record files to rebuild from; otherwise
the app stops and says why, rather than starting with an empty index. A rebuild on request first writes every change
not yet in the files. Documents are then updated in place from their entries and keep their numbers, so their cached
text, embeddings and traces stay attached; everything else recorded in files is replaced by what the files say.

A rebuild reads every folder's `_about.md`, every `_documents.md`, the learned files, the logic file and the history.
Documents whose file is not where their entry says are looked up by the identifier on the file; files that have no entry,
in any of your folders at any depth, are taken in as adopted documents of the folder they are in. Then, in the
background and giving way to new arrivals, each document's text is extracted again and its embedding recomputed.
Search by words and by meaning fills in as that proceeds; filing works from the start.

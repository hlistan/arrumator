# Storage: the archive is the record, SQLite is the index

Everything Arrumator knows that it could not work out again lives in Markdown files inside the archive. Each archive
has a SQLite database of its own, an index over those files plus caches of things that can be recomputed. Losing or
corrupting an index costs time, never information: the app rebuilds it from the archive.

This is the pattern of plain-text vaults such as Obsidian, whose notes are the source of truth and whose metadata cache
is disposable and rebuilt from the files ([Obsidian help: how Obsidian stores data](https://help.obsidian.md/Files+and+folders/How+Obsidian+stores+data)).
Documents are filed at the top of the archive, each directory holding documents lists them beside them, and the
history, your rules for labels, your search tasks and the conversations about their documents sit in one `System`
folder at the top of the archive. The app makes
no other folders in the archive.

## What lives where

| What | File | Contents |
|---|---|---|
| The documents in a directory | `<directory>/_documents.md` | One entry per file in that directory: identity, original name, checksum, size, content type, pages, status, the labels that describe it (each a kind and a value, your tags among them; absent while it has none and the model has not labelled it), `tags_only: true` while those labels are only its tags because the model has not labelled it yet, and how it was read: the file name its reading gave it, the model, and why it waits for you, if it does. The table below the data shows each file's date, sender, type and other labels. |
| History | `System/History/_<year>-<month>.md` | One line per event, newest last. |
| Rules for labels | `System/_labels.md` | Your decisions about labels ([how](how-it-works.md#keeping-labels-one-vocabulary)): each rule's number, kind, label, what it decides (`merge`, `ignore` or `keepApart`), the other label of a merge or of a pair kept apart, and when it was made. There is no file while there are no rules. |
| Conversations | `System/Conversations/_<task>.md` | The questions about one search task's documents ([how](how-it-works.md#talking-with-a-tasks-documents)), by the task's number: each question's number, when it was asked, the question, its state (`queued`, `answered` or `failed`; one being answered is written as `answering` and waits again after a rebuild), the model that answered, why the answer is incomplete or missing, when it was answered, the answer, the documents it draws on by number, and what it found outside the set when asked for more: the request it wrote, what that was read as, the documents found and why none could be, if so. Below the data, each question with its answer and the documents by name, for people. There is no file while the task has no questions; removing the task removes it. |
| Search tasks | `System/_tasks.md` | Your search tasks ([how](how-it-works.md#search-tasks)): each task's number, what you asked, the name and arrangement you gave it, its state, the effort it is read with and the model profile you gave it, by its id (none when it follows the one Settings uses), what the model read the request as and which model, why it failed if it did, the documents of its set by number, each `matched`, `added` or `removed` (taken out by you), and every export: its number, when, as a `folder` or a `zip`, where it was put, where each document went inside it and which could not be copied and why. There is no file while there are no tasks. |

Every file starts with YAML front matter holding the exact data, followed by a Markdown rendering for people. The front
matter is what the app reads; the rendering is regenerated on every write. The rendering gives times as the Mac shows
them, with their offset from UTC (`2026-10-02T11:40:58+01:00`). The front matter starts with the version of its format,
`arrumator: 1`; a file of a later format, which a newer version of Arrumator wrote, is not read and not written over.

A document's entry sits next to the document: `_documents.md` lists the files in its own directory by name. Renaming or
moving a directory of yours therefore never touches a record, and a file moved in Finder is found again by the
identifier Arrumator stores on it as an extended attribute. A copy made in Finder keeps that attribute; it is a document
of its own, given an identifier of its own, as long as its original is still in the archive, where its entry says or
moved at the same time, which keeps the inode the copy does not have.

Identifiers in the records are the database's own: document and event numbers are written into the files and restored
exactly on a rebuild, so references between records keep working. A document is the one its identity (`uid`) names: an
entry whose number the index gives another document, as in a folder copied in from another archive whose numbers also
start at 1, is taken in under a number of its own, and its list is written again with it. A copy whose original the
archive does not have (`duplicate_of`) is read as a copy of nothing, as an event about a document gone is. An entry's
`file` is the name of a file in its folder, never a path: a list with an entry that holds a path, such as
`../../x.pdf`, is not read.

## One index per archive

The index of an archive is `~/Library/Application Support/Arrumator/Indexes/<name>.sqlite`, named after the first bytes
of the SHA-256 of the archive's path as the file system spells it, or of where it would be when its folder is not
there. Switching archives opens the other archive's index, stops everything working on
the one in use, records the switch in its history and writes its record files; only then do the settings name the
other archive, whose documents and history take its place, and the files waiting in Incoming leave the queue of the
one left, to be filed into the new one. A switch that fails on the way changes nothing: the app goes on with the
archive it had, its queue as it was and its work started again, and a switch it had recorded is followed in History by
`Stayed on the archive at …` with the reason.
An archive whose record files cannot be written then, as on a disk that is gone, does not keep you from switching away:
its index keeps what they lack, they are written when it is next opened, and the app, or `arrumatorcli archive switch`,
says so, naming the archive.

A folder that has never been an archive gets a new index. If it holds record files when it is opened, anywhere in it,
the index is rebuilt from them; otherwise it starts empty. An archive moved to another path is the same case: its new
index is rebuilt from its records. The app makes an archive's folder only when the user sets an archive up: when
onboarding is finished, or on a switch to a folder that is not there and that no index of the app has held an archive
in. Whether an archive is new is decided by what the user did, never by what its index lacks: a new index looks the same
whether its archive is new or away, as on a new Mac, after the app is installed again or the index lost, or when the
settings spell the path another way. At any other launch, and whenever settings are applied, an archive whose folder is
not there, renamed, moved or on a disk that is not connected, is away, whatever its index holds: nothing is made, read,
written or filed in its place, Incoming waits, and the app says its folder is not there, naming it. The app looks for it
every `watcher.awayPollSeconds`, also while it runs, and once the same folder is back, known by its volume and its own
number however the disk is mounted, the work goes on by itself, the archive looked at whole and its record files
written. Another folder at its path is taken as the archive, which History says, or, when it is the earlier one back,
says it is back: what its record files hold is merged with what the index kept meanwhile, never taken over it, so a
rule, a task or a question made meanwhile is kept and written into it. That they are owed a merge is kept in the index
with the folder it names, until they are read, so an app stopped in between merges them when it next starts. A setting
can still be changed, and the archive left for another, whose History it is recorded in once its folder is back; a
switch to an archive that is away is refused, naming its folder. The command line has no onboarding, and cannot tell a
new archive from one away: none of its commands makes an archive's folder but `arrumatorcli archive switch`.

Earlier versions kept one index, `arrumator.sqlite`, for whichever archive the settings named. The first start of this
version moves it into place as that archive's index, so nothing it held is lost: its write-ahead log is written into it
first, so the database file alone holds everything when it is moved.

## What the database only indexes or caches

- **Text and search**: extracted text and the full-text index are extracted again from the documents; the labels'
  columns of the full-text index, one per kind and the last for tags, are filled from the entries, without asking the
  model again.
- **Which documents have each label**, by its kind and value, kept with each document's labels in the transaction that
  changes them: how many documents have each label, what the sidebar and the model are shown, and which documents a
  chosen label narrows the list to are counted from it, not by reading every document's labels. A rebuild fills it as
  it reads the entries.
- **Embeddings** of documents are computed again with the embedding model.
- **The job queue** is rebuilt by looking at the Incoming folder, so each file waiting there is given the tag of the
  folder it is in again. A tag a document already has is in its entry. Documents of the archive waiting to be read
  again are not: each keeps what it had, its text read again for search, and **Read All Documents Again** asked for
  once more queues them.
- **Positions in the file-system event stream**, each saved once what the events before it reported is applied, and
  none past a change that could not be applied, so a change the app quit or crashed before applying, or could not
  apply, is reported again at the next start, up to `ingest.maxAttempts` times, which the index counts; and similar
  bookkeeping.
- **The inode of each document's file**, by which a copy is told from its original, and the archive's folder the index
  was kept for. A rebuild takes each document's inode from its file as it finds it, and the folder from the archive it
  is rebuilt from.

Some working state is deliberately not kept in files, so a lost index loses it:

- **Traces**, the full exchange with the model for each document and each search task's request. What the model read
  the document as, and its labels, are in the document's entry; what it read a request as is in the task's entry. A
  rebuild on request keeps the traces, and which document and which History event each belongs to, as reading a
  history file back after an edit does; a search task and a question lose the link to theirs until they are next read.
- **When a waiting search task, or question about its documents, is next tried.** A task that was waiting in the
  queue, or whose request was being read, is waiting again after a rebuild, and so is a question waiting or being
  answered. Each answer's trace is the index's own too, and so is which process is reading a task's request or
  answering a question (`worker`), by which another process tells one it still works on from one a process that ended
  left behind.

## Keeping files and index together

1. A change is made in the database. Triggers on every recorded table mark the record files the change touches, in the
   same transaction, so no code path can forget one and a mark survives a crash.
2. As soon as the transaction commits, the app writes each marked file from the index, and a command of `arrumatorcli`
   writes them before it exits, also when it fails part way, atomically: to a hidden temporary file in the same
   directory (`.<UUID>.<name of the record file>`, which a crash may leave, and which is removed when the archive is
   read once it is older than `records.stagedLeftoverMinutes`, as a younger one may be another process's, and never
   taken for a document), outside any transaction of the index, then renamed over the old one, which APFS guarantees is
   all or nothing, in the transaction that keeps the file's SHA-256 in the index. So another process, the app or a
   command, never finds the file replaced and its checksum not kept, and never reads back what the index wrote as an
   edit, which could be older than what was committed since; and a slow disk holds up no other writer of the index for
   longer than a rename. A file changed again while it was being written stays marked and is written again. While the
   archive's folder is not there, renamed or on a disk that went, nothing is written and no folder of it is made again
   where it no longer is: its files stay marked, and are written once it is back.
3. When the app starts, and whenever the archive watcher sees a record file change that the app did not make, every
   record file whose checksum differs from the one the index holds is read back. That covers edits made by hand,
   files synchronised from another Mac, and anything else that changed the files behind the app's back.
4. A file edited by hand is never overwritten. If the index has changes of its own for the same file, the edit is merged
   in: what the file changes wins, and what the index added is kept. Otherwise the file replaces what the index held
   for it. Which of the two is decided in the transaction that applies the file, so a change committed while the file
   was read is merged with it, never replaced. Removing a document's entry never removes the document; its entry is
   written back. An entry in the list of another folder than the one its document is in, while the document's file is
   still where the index has it, is a copy's, as in a folder copied in Finder with its `_documents.md`: it moves no
   document, and the list is written again without it; the copies themselves are taken in as new files. That is so
   only while where the index has the document tells it, which it does not when it was itself read from a list, as
   after the index was lost: see [documents in two places](#documents-in-two-places). A rule for
   labels changed by hand is followed by readings from then on; the documents it concerns keep the labels they have.
   A file is written over or removed only when it holds what the app last wrote or has just read: one the index has
   no checksum for, such as a file another Mac synchronised, is read first.
   A file that is there but cannot be read, such as one edited into broken YAML, saved again as UTF-16 by an editor or
   whose permissions keep the app out, is never taken for a missing or empty one and never written over or removed,
   nor are the files in a folder of the archive whose contents cannot be listed, nor any while the archive's own
   folder is not there, where no folder is made:
   the app logs which file or folder and why (the line and column where the YAML breaks, or the field whose value it
   does not read, never what the file says there), `arrumatorcli doctor` names it, History says so once, whichever
   process finds it, and once more when it reads again (the index keeps which it said, under `records_unreadable` in
   its `meta`), the app says so at the foot of its window while filing goes on, every other file is still read, and
   the index keeps what it holds and writes the file's changes once it reads again. That is so for an index that holds
   the archive; a new one is not rebuilt without the file (see [Rebuilding](#rebuilding)).

The window in which a change exists only in the database is the time it takes to write one file, and a mark left by a
crash in that window is written at the next start. A mark that could not be written as the app switched away from the
archive stays in that archive's index until it is next opened ([One index per archive](#one-index-per-archive)).

## Rebuilding

The app rebuilds the index when the database is missing, damaged or cannot be migrated, and on request (`arrumatorcli
rebuild`, or Settings › Advanced). A new index records in itself that it is to be rebuilt, in the transaction of its
first migration, so a stop at any point while it is made leaves it marked; a rebuild records it too, in the
transaction that replaces the index. Only the rebuild's last step clears it, so a rebuild that never ran, as when the
app quits before onboarding opens the archive, or that was refused or cut short is done the next time the archive is
opened; documents queued to be read again are not queued twice. Until then the app starts no work on the index:
nothing is filed into it, read back into it or written from it, and whatever the user asks to change in what the
record files hold, a label, a rule, a search task or a question, is refused by the index itself, whatever process
asks, with the same reason, naming the record files to correct, rather than kept for the rebuild to drop. A setting
changed meanwhile, as during onboarding, or a switch to another archive, is made all the same, and its History event
is held in the index, apart from what the rebuild replaces, until the rebuild's last step, which records it once,
at its own time, after the archive's own history. Whether the archive holds record files is decided when it is
opened, by walking it whole, never when its index is made, before macOS lets the app read the folder: an archive with
none has nothing to rebuild from, so its new index is then complete as it is, and records what was held. An archive
whose folder is not there when it is opened, as on a disk that is not connected, is not taken for one without
records: its rebuild is refused, naming the folder, nothing is made or written where it was, and it is rebuilt once
the folder is back. A folder that is there but empty cannot be told from an archive
whose records have not arrived yet, so a sync from another Mac that has not delivered them by the time the archive is
opened leaves an index taken for complete; what arrives later is read back as record files changed on disk, which
neither finds their documents nor reads their text again: rebuild the index in Settings › Advanced, or with
`arrumatorcli rebuild`, once the sync is done. An index whose rebuild was refused or cut short is complete only once
it is rebuilt, however the archive looks when it is next opened. A database that is damaged or cannot be migrated is
moved aside, never deleted, as `<name>.sqlite.unreadable-<date>`. That only happens when the archive has record files
to rebuild from; otherwise the app stops and says why, rather than starting with an
empty index. While the archive's folder is not there, it is not known to hold none: the app stops naming the folder,
leaves the database as it is, and moves it aside to be rebuilt once the folder is back. A database that cannot be
opened only for the moment, because another process holds it longer than
`database.busyTimeout`, the disk is full or the file may not be read, is never moved aside: the app stops and says
why, and starts once that has passed. A rebuild of an index that holds the archive, as on request, first writes
every change not yet in the files. Documents are then updated in place from their entries and keep their numbers, so their
cached text, embeddings and traces stay attached; everything else recorded in files is replaced by what the files say.
The index is replaced only if it holds no change the files do not and no file was written while the archive was read,
which the transaction that replaces it checks; a change committed meanwhile, by the app's worker or by a command, is
written into the files and the archive read again, at most three times before the rebuild gives up and says so.

A record file that cannot be read, or a folder of the archive whose contents cannot be listed, stops every rebuild
before anything changes, naming each and why: a rebuild without it would leave the index without what it holds, and
what the app did next would be written over the file once it read again. The index stays to be rebuilt, so the app
starts no work on it, and every `arrumatorcli` command stops with the same message. Correct the file, or move it out of
the archive, then rebuild the index in Settings › Advanced, which starts the work once it succeeds, open Arrumator
again, or run the command again.

A rebuild reads every `_documents.md`, the history, the rules for labels, the search tasks and their conversations; a
task's set keeps only the documents the archive still has entries for, and a conversation of a task `_tasks.md` does not
have is left where it is, unread, and read again until its task is back; no new task is given its number. Lists of a
kind are read shallower folder first, then in the order of their paths. Documents are looked up by the identifier on
their file, a package (such as an `.rtfd`) being one file, and follow it wherever it is in the archive, a file left
where the entry says, as a copy without the identifier, being taken in as a document of its own. Of several files that
carry one document's identifier, as copies made in Finder do, the one where its entry says is its file, then the very
file the index last knew as its own; each other is a copy, taken in as a document of its own, with the identifier taken
off it. When neither tells, the document is in two places ([below](#documents-in-two-places)). A document whose file is
nowhere is marked missing, and one marked missing whose file is found again is where its file is now, with the status it
had when its file went: History says each, as when the app sees it happen. A file without the identifier where an entry
not found elsewhere says its document is, as one a copy or a synchronisation left it off, is that document's. An entry
in the list of another folder than the one its document is in, while the document's file is still there, is a copy's, as
when such a list is read back ([above](#keeping-files-and-index-together)), when the index had the document there before
the rebuild: the document stays with its file, and that list is written again without the entry. Files that have no
entry, at the top of the archive or in a folder of yours at any depth, are taken in where they are and read by the
model; the `System` folder and the folders the watcher ignores, such as a hidden one, are left out, and Incoming is
never inside the archive ([Configuration](using-arrumator.md#configuration)). Then, in the background and giving way to
new arrivals, each document's text is extracted again and its embedding recomputed. The model is not asked again: labels
come back from the entries. Search by words and by meaning fills in as that proceeds; filing works from the start.

### Documents in two places

A folder duplicated in Finder with its `_documents.md` while the index was lost, or a document's file copied while the
index cannot tell its own file by its inode, leaves two places that carry one document, and nothing on disk tells
which is the original: a copy keeps the document's identifier, its list names the same documents, and Finder and
`FileManager.copyItem` keep the original's creation date. Arrumator decides nothing on that guess. The document stays at
the place it was first found in: the folder whose list is read first, the shallower first and then in the order of
their paths, which may be the copy's (`Bills copy` comes before `Bills`). No file loses the identifier, none is taken in
as a new document, and neither list loses the document's entry: the other list keeps it as it is, entry for entry,
while the rest of that list is read and written as any other, so a change to another document of its folder, or a
document filed there, reaches it. History says once, for each document, which places carry it, and `arrumatorcli
doctor` warns of them by folder until one is gone. Remove the copy: when the place the document is kept at is removed,
it follows the file that is left, with the status it had; when the other place is removed, the document is in one
place again, and its entry goes from that place's list.

## Archives from earlier versions

Earlier versions filed documents into folders, kept a `_about.md` in each and an `_INDEX.md` at the top, and kept the
archive's logic, rules, corrections, filing memories and senders in the `System` folder. The first start of this
version migrates the index: documents stay where they are, and what the decision recorded for each said of it becomes
its labels (its sender, type, date, reporting year, topic tags and language as `sender`, `type`, `date`, `period`,
`topic` and `language`) while the name the model gave it, the model and why it waited for you become how it was read.
Titles are not kept. The tables of folders, rules, filing memories, corrections, proposals, logic, rethink plans and
senders are dropped, as are history events of kinds that no longer exist; a history file of those versions read back,
by a rebuild or after an edit, drops them too and reads the rest. Every record file is written again in the new
shape. Those older files, `_senders.md` among them, are left alone in the archive and no longer read. A `_documents.md`
entry written by an earlier version that a rebuild reads without that migration (on another Mac, say) comes back
without labels; its document is labelled when it is read again (`arrumatorcli labels unlabelled`, once its text has
been read again). Read any document again (`arrumatorcli review retry`) to give it the full set of labels.

Search tasks of earlier versions could be given a model of their own, which `_tasks.md` kept as `assignedModel`. A
model is not a profile, so it is not read as one: such a task follows the profile Settings uses, the index forgets the
model when it is migrated, `_tasks.md` is written again without it, and a rebuild that reads an older `_tasks.md`
leaves it out too. Give the task a profile to read it with another model. A task in a `_tasks.md` of the versions before
efforts, which has no `effort`, is read with `medium`, as it was read then and as migrating the index gave it.

Tags came after labels. The first start of the version that brought them makes the full-text index again with a column
for tags, from the text the index already holds, so nothing is read again or lost, and adds to each document whether
its labels are only its tags, which no document's are yet. No record file is written again for it: an entry without
`tags_only` is read as it always was, labelled when it has labels. The `tags` that entries of the versions that filed
into folders hold were topics; a rebuild leaves them unread, as before, and never reads them as tags.

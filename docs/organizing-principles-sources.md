# Sources for how documents are read and found

The research behind how Arrumator labels documents, recognises their senders and searches them. The archive has no
folders of the app's making: documents are found by their labels, senders, words and meaning.

## Document type, sender and date as metadata

| Choice | Sources |
|---|---|
| Document type, correspondent and date as metadata rather than folders | paperless-ngx documentation — <https://docs.paperless-ngx.com/usage/> |
| Identify a document's details first, and learn its sender from the user's own documents | paperless-ngx keeps a classifier per field (correspondent, document type, storage path) trained on the user's own assignments — <https://docs.paperless-ngx.com/usage/> ; <https://deepwiki.com/paperless-ngx/paperless-ngx/4.3-document-classification> |
| Recognise a sender by its identifiers, not its spelling (legal forms, abbreviations and scripts vary) | Entity resolution as the hard half of invoice automation — <https://dev.to/taranpreet_kaur_4b538d878/why-an-llm-alone-cannot-do-invoice-extraction-yet-2mm7> |
| When the model gives no valid answer, the document waits for the user rather than being guessed into shape | Selective prediction with LLMs: Chen et al., *Adaptation with Self-Evaluation to Improve Selective Prediction in LLMs*, 2023 — <https://arxiv.org/pdf/2310.11689> |
| ISO 8601 dates at the start of file names | NIST, *Electronic File Organization Tips* (2016) — <https://www.nist.gov/system/files/documents/2022/03/30/ElectronicFileOrganizationTips-2016-03.pdf> ; UConn *File Naming and Date Formatting* — <https://guides.lib.uconn.edu/c.php?g=832372&p=8226285> |

## Sources for labels

Every document is labelled by the kinds of metadata archival description keeps for a record, whatever its place in a
classification scheme (`labels-system.md`, `LabelKind`).

| Choice | Sources |
|---|---|
| Label a document by the parties it concerns, the jurisdiction it belongs to and its language, apart from where it is filed | DCMI Metadata Terms: *subject*, *coverage* ("the spatial or temporal topic of the resource, spatial applicability of the resource, or jurisdiction under which the resource is relevant") and *language* — <https://www.dublincore.org/specifications/dublin-core/dcmi-terms/> ; ISO 23081-1:2017, *Metadata for records*, which describes records together with the agents and business they relate to — <https://www.iso.org/standard/73172.html> |
| Languages as ISO 639-1 codes | ISO 639 language codes, as DCMI recommends a controlled vocabulary for *language* — <https://www.loc.gov/standards/iso639-2/php/code_list.php> ; `Locale.LanguageCode` — <https://developer.apple.com/documentation/foundation/locale/languagecode> |
| Labels instead of folders, so a document is found from every side | paperless-ngx tags, which a document can carry many of, where a folder holds it in one place — <https://docs.paperless-ngx.com/usage/> |
| The model answers in a fixed JSON schema, checked and repaired like every other answer | Ollama structured outputs — <https://ollama.com/blog/structured-outputs> |

## Sources for search

| Choice | Sources |
|---|---|
| Documents containing the words first, ordered by fusing their rank by words with their rank by meaning | Cormack, Clarke & Büttcher, *Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*, SIGIR 2009 — <https://doi.org/10.1145/1571941.1572114> |

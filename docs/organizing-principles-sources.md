# Sources for how documents are read and found

The research behind how Arrumator labels documents and searches them. The archive has no folders of the app's making,
and a document is described by its labels alone: it is found by them, its words and its meaning.

## Sources for labels

Every document is labelled with the kinds of metadata archival description keeps for a record, the facets of faceted
classification, and the fields document managers and key-information extraction read from personal paperwork
(`labels-system.md`, `LabelKind`). The sources the kinds draw on:

- **DCMI Metadata Terms** — <https://www.dublincore.org/specifications/dublin-core/dcmi-terms/>: *creator* "An entity
  responsible for making the resource" and *publisher*; *subject* "A topic of the resource"; *coverage* "The spatial or
  temporal topic of the resource, spatial applicability of the resource, or jurisdiction under which the resource is
  relevant", with *spatial* and *temporal*; *issued* "Date of formal issuance of the resource"; *valid* "Date (often a
  range) of validity of a resource"; *type* "The nature or genre of the resource", with a controlled vocabulary
  recommended; *language*, with ISO 639 recommended; *identifier* "An unambiguous reference to the resource within a
  given context".
- **ISO 23081-1:2017, *Metadata for records*** — <https://www.iso.org/standard/73172.html>: a multi-entity model that
  describes a record together with the agents, business, mandates and relationships around it.
- **Ranganathan's facets** (personality, matter, energy, space, time): any subject analysed along five fundamental
  categories — <https://en.wikipedia.org/wiki/Faceted_classification> ;
  <https://berkeley.pressbooks.pub/tdo4p/chapter/faceted-classification/>.
- **paperless-ngx**: correspondents, document types and tags, and custom fields including monetary and date fields —
  <https://docs.paperless-ngx.com/usage/>; **paperless-gpt**, where a local or remote LLM suggests a document's title,
  tags, correspondent, document type and created date — <https://github.com/icereed/paperless-gpt>.
- **schema.org**: *Invoice* with *provider*, *customer*, *paymentDueDate*, *totalPaymentDue* and *accountId* —
  <https://schema.org/Invoice>; *temporalCoverage*, the period a work applies to, as an ISO 8601 interval —
  <https://schema.org/temporalCoverage>.
- **Key-information extraction**: the fields benchmark datasets read from receipts and invoices, SROIE (company, date,
  total) and inv-cdip (invoice number, invoice and due dates, amounts due, totals and tax), as summarised in
  *Multi-Modal Vision vs. Text-Based Parsing: Benchmarking LLM Strategies for Invoice Processing*, 2025 —
  <https://arxiv.org/pdf/2509.04469>.

| Kind | Grounded in |
|---|---|
| `sender` | DCMI *creator* and *publisher*; ISO 23081 agent; paperless-ngx correspondent; schema.org Invoice *provider*; SROIE company |
| `party` | ISO 23081 agent; schema.org Invoice *customer*; Ranganathan's personality |
| `type` | DCMI *type*, from a controlled vocabulary (`DocumentType`); paperless-ngx document type |
| `topic` | DCMI *subject*; paperless-ngx tags; Ranganathan's energy (the activity a record documents) and ISO 23081 business |
| `object` | Ranganathan's matter; schema.org Invoice *accountId* |
| `reference` | DCMI *identifier*; inv-cdip invoice number |
| `date` | DCMI *issued*; paperless-ngx created date; SROIE and inv-cdip date |
| `period` | DCMI *temporal*; schema.org *temporalCoverage*; Ranganathan's time |
| `deadline` | DCMI *valid*; schema.org Invoice *paymentDueDate*; inv-cdip due date |
| `amount` | schema.org Invoice *totalPaymentDue*; SROIE total; inv-cdip amount due; paperless-ngx monetary field |
| `jurisdiction` | DCMI *coverage* and *spatial*; Ranganathan's space |
| `language` | DCMI *language*, as ISO 639-1 codes — <https://www.loc.gov/standards/iso639-2/php/code_list.php> ; `Locale.LanguageCode` — <https://developer.apple.com/documentation/foundation/locale/languagecode> |

| Choice | Sources |
|---|---|
| Labels instead of folders, so a document is found from every side | paperless-ngx tags, which a document can carry many of, where a folder holds it in one place — <https://docs.paperless-ngx.com/usage/> |
| The model answers in a fixed JSON schema, checked and repaired like every other answer | Ollama structured outputs — <https://ollama.com/blog/structured-outputs> |
| The schema lists the facts a file name is made of (sender, type, date) first and the name last | Under constrained decoding the schema's property order is the order the model generates, so a field declared before another can inform it and one declared after cannot — <https://dev.to/ji_ai/why-json-schema-field-order-breaks-structured-output-accuracy-2985> |
| `type` is a closed enum, and the other kinds free text normalised by the app | Format restrictions help classification-style answers while hindering free reasoning: Tam et al., *Let Me Speak Freely? A Study on the Impact of Format Restrictions on Performance of Large Language Models*, EMNLP 2024 Industry Track — <https://aclanthology.org/2024.emnlp-industry.91/> |
| When the model gives no valid answer, the document waits for the user rather than being guessed into shape | Selective prediction with LLMs: Chen et al., *Adaptation with Self-Evaluation to Improve Selective Prediction in LLMs*, 2023 — <https://arxiv.org/pdf/2310.11689> |
| ISO 8601 dates at the start of file names | NIST, *Electronic File Organization Tips* (2016) — <https://www.nist.gov/system/files/documents/2022/03/30/ElectronicFileOrganizationTips-2016-03.pdf> ; UConn *File Naming and Date Formatting* — <https://guides.lib.uconn.edu/c.php?g=832372&p=8226285> |

## Sources for search

| Choice | Sources |
|---|---|
| Documents containing the words first, ordered by fusing their rank by words with their rank by meaning | Cormack, Clarke & Büttcher, *Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*, SIGIR 2009 — <https://doi.org/10.1145/1571941.1572114> |

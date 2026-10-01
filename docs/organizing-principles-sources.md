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

## Sources for keeping labels one vocabulary

How the archive's labels are kept consistent, and how the user's decisions about them reach the model
([how it works](how-it-works.md#keeping-labels-one-vocabulary), `LabelConsolidator`, `LabelSimilarity`,
`archive-labels.md`).

| Choice | Sources |
|---|---|
| Labels written two ways, or two labels for one thing, are the problem to solve: they split what belongs together and a search misses part of it | Golder & Huberman, *The Structure of Collaborative Tagging Systems*, 2005: "Synonymy … presents a greater problem for tagging systems because inconsistency among the terms used in tagging can make it very difficult for one to be sure that all the relevant items have been found" — <https://arxiv.org/abs/cs/0508082> |
| Labels are compared by the Jaro-Winkler similarity, with Winkler's prefix bonus (scale 0.1, at most 4 characters), and its published examples are the tests' reference values | Winkler, *String Comparator Metrics and Enhanced Decision Rules in the Fellegi-Sunter Model of Record Linkage*, 1990, which extends Jaro's comparator for typographical variation in names and gives the examples MARTHA/MARHTA, DWAYNE/DUANE and DIXON/DICKSONX — <https://files.eric.ed.gov/fulltext/ED325505.pdf> |
| Jaro-Winkler rather than an edit distance for names | Cohen, Ravikumar & Fienberg, *A Comparison of String Distance Metrics for Name-Matching Tasks*, IIWeb 2003: the Jaro variants are close to the best edit-distance-like method on average, better on several problems, and about ten times faster — <https://www.cs.cmu.edu/~wcohen/postscript/ijcai-ws-2003.pdf> |
| Words are compared in sorted order, so `Silva, Maria` is `Maria Silva`, and labels whose numbers differ are never alike | Token order is a writing variant for names, as token-based comparison in the same study treats it; a number is what tells one account, invoice or address from the next, so no measure of writing may join two of them |
| Only labels written the same way merge without asking for names; merely alike ones wait for the user | Two people or companies can differ by one letter; record linkage sends the uncertain band between match and non-match to clerical review (Winkler 1990, above) |
| The user's decisions teach the model through its prompt, with the archive's labels as examples, rather than by retraining it | In-context learning: a large language model does a task from instructions and demonstrations given "purely via text interaction with the model", "without any gradient updates or fine-tuning" — Brown et al., *Language Models are Few-Shot Learners*, 2020 — <https://arxiv.org/abs/2005.14165> |

## Sources for search tasks

How a request in the user's words becomes a search, and how what it finds is arranged and delivered
([how it works](how-it-works.md#search-tasks), `SearchPlan`, `SearchPromptInterpreter`, `EffortPreset`,
`DocumentGrouping`, `search-system.md`).

| Choice | Sources |
|---|---|
| The labels of one kind are alternatives and the kinds narrow each other down: values within a facet are ORed, facets are ANDed | Hearst, *Design Recommendations for Hierarchical Faceted Search Interfaces*, SIGIR 2006 Workshop on Faceted Search — <https://flamenco.berkeley.edu/papers/faceted-workshop06.pdf> ; Tunkelang, *Faceted Search*, Morgan & Claypool, 2009 — <https://doi.org/10.2200/S00190ED1V01Y200904ICR005> |
| The model turns the request into structured criteria over the archive's own vocabulary, rather than being asked for the documents | Natural-language interfaces translate a question into a structured query against a known schema; the model is given the schema's values in its prompt: Rajkumar, Li & Bahdanau, *Evaluating the Text-to-SQL Capabilities of Large Language Models*, 2022 — <https://arxiv.org/abs/2204.00498> |
| Each label asked for quotes the words of the request that ask for it, and a label whose quote is not in the request is dropped, so the model cannot narrow a search by what nobody asked | Checking generated statements against the sources they cite: Gao, Yen, Yu & Chen, *Enabling Large Language Models to Generate Text with Citations* (ALCE), EMNLP 2023 — <https://arxiv.org/abs/2305.14627> |
| The answer is a fixed JSON schema, checked and repaired like a document's; the arrangement is a closed enum of the kinds | Ollama structured outputs — <https://ollama.com/blog/structured-outputs> ; Tam et al., EMNLP 2024 Industry Track (above) |
| A date, period or deadline asked for is matched by the time it covers, as an interval | ISO 8601 time intervals (`start/end`) and reduced precision (a year, a month), as `schema.org/temporalCoverage` uses them — <https://schema.org/temporalCoverage> |
| What is found is arranged a level per kind, the order of the levels the user's | Hierarchical faceted metadata: a facet's values become the categories a collection is browsed and grouped by, and a person chooses which facet comes first (Hearst 2006, above) |
| A request is read with an effort, Low, Medium or High, that spends more or less computation on it: a larger model, thinking before answering, more chances to repair a wrong answer, more of the archive's vocabulary | Answers improve with the computation spent on them at inference, and how much is worth spending depends on the request: Snell, Lee, Xu & Kumar, *Scaling LLM Test-Time Compute Optimally can be More Effective than Scaling Model Parameters*, 2024 — <https://arxiv.org/abs/2408.03314> ; a model improves its answer when given feedback on it and asked again: Madaan et al., *Self-Refine: Iterative Refinement with Self-Feedback*, NeurIPS 2023 — <https://arxiv.org/abs/2303.17651> ; thinking before answering, separately from the structured answer: Ollama, *Thinking* — <https://docs.ollama.com/capabilities/thinking> |
| The effort is one of three presets rather than a number of tokens or tries | A few named levels of reasoning effort, as model APIs offer them (low, medium, high), which a person can choose between without knowing what each costs: OpenAI, *Reasoning models*, `reasoning.effort` — <https://platform.openai.com/docs/guides/reasoning> |
| A ZIP archive is made by Foundation, reading the folder for uploading, as Finder's Compress does | Apple, `NSFileCoordinator.ReadingOptions.forUploading`, which gives a directory read with it as a ZIP archive of its contents, in a temporary file removed once the reader is done — <https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading> |

## Sources for search

| Choice | Sources |
|---|---|
| Documents containing the words first, ordered by fusing their rank by words with their rank by meaning | Cormack, Clarke & Büttcher, *Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*, SIGIR 2009 — <https://doi.org/10.1145/1571941.1572114> |

# Sources for the placement guidance

The built-in logic, `Sources/ArrumatorClassify/Prompts/organizing-principles.md`, condenses these references. It is only
the logic a new archive starts with: the archive's own logic decides the shape of its tree, and can be edited freely.

| Principle | Sources |
|---|---|
| Findability, one home per record, descriptive folder names, structure by function/subject, keep it simple, Title Case, ISO 8601 dates | NIST, *Electronic File Organization Tips* (2016) — https://www.nist.gov/system/files/documents/2022/03/30/ElectronicFileOrganizationTips-2016-03.pdf |
| Balance breadth vs depth, consistent naming, date formats | UW-Madison Libraries, *File Naming & Organization* — https://learn.library.wisc.edu/research-data-management/lesson-2/ ; UConn *File Naming and Date Formatting* — https://guides.lib.uconn.edu/c.php?g=832372&p=8226285 |
| Short folder names, avoid deep paths, document the structure in a file at the top | NBIS, *Organising files and folders* — https://nbisweden.github.io/module-organising-data-dm-practices/002-files-and-folders/index.html |
| Two levels of few, broad areas and focused topics, one home per kind of document, year folders as the one exception | Stefan Zweifel, *An Opinionated Personal Folder Structure* — https://stefanzweifel.dev/posts/2023/09/16/an-opinionated-personal-folder-structure/ |
| Document type, correspondent and date as metadata rather than folders | paperless-ngx documentation — https://docs.paperless-ngx.com/usage/ |
| Tax records kept together per year (supports retention) | IRS Topic 305, *Recordkeeping* — https://www.irs.gov/taxtopics/tc305 |

## Sources for how the app places a decided path

The model identifies a document and decides its path from the logic; the app, not the model, puts that path onto the
folders that exist (`PlacementGuard`), so that nothing is filed where it does not belong.

| Choice | Sources |
|---|---|
| Identify metadata first, then file by it: a sender's documents are placed by who the sender is | paperless-ngx keeps a classifier per field (correspondent, document type, storage path) trained on the user's own assignments — https://docs.paperless-ngx.com/usage/ ; https://deepwiki.com/paperless-ngx/paperless-ngx/4.3-document-classification |
| Recognise a sender by its identifiers, not its spelling (legal forms, abbreviations and scripts vary) | Entity resolution as the hard half of invoice automation — https://dev.to/taranpreet_kaur_4b538d878/why-an-llm-alone-cannot-do-invoice-extraction-yet-2mm7 |
| Classify consistently into one fixed structure over time | ISO 15489-1:2016 — https://www.iso.org/standard/62542.html ; National Archives of Australia, *Overview of Classification Tools for Records Management* — https://www.naa.gov.au/sites/default/files/2019-10/classifcation-tools.pdf |
| Ask the model one narrow question (are these two described folders the same?) instead of matching a whole tree | Entity matching with foundation models: Narayan et al., *Can Foundation Models Wrangle Your Data?*, VLDB 2022 — https://arxiv.org/abs/2205.09911 |
| Decide level by level against what exists at each level | Chen et al., *Retrieval-style In-context Learning for Few-shot Hierarchical Text Classification*, TACL 2024 — https://aclanthology.org/2024.tacl-1.67/ |
| Hold back what is uncertain rather than guess (coverage for accuracy) | Selective prediction with LLMs: Chen et al., *Adaptation with Self-Evaluation to Improve Selective Prediction in LLMs*, 2023 — https://arxiv.org/pdf/2310.11689 |

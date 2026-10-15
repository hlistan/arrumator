---
paths: ["Sources/ArrumatorClassify/**", "Sources/ArrumatorCore/Resources/Defaults/pipeline.json", "Sources/ArrumatorCore/Contracts/Labels.swift"]
---

# Reading documents

How to change how documents are read, labelled and named: the prompts and
the answer schema in `Sources/ArrumatorClassify/`, the `analysis` and
`labels` keys of `Sources/ArrumatorCore/Resources/Defaults/pipeline.json`,
and `LabelKind` in `Sources/ArrumatorCore/Contracts/Labels.swift`.

- **G46** Such a change ships with the numbers of
  `swift run arrumatorcli eval Tests/Fixtures --passes 2` from before and
  after (AGENTS.md §3, research-grounded decisions; the current ones are in
  `docs/evaluation.md` › Results), and a change to how two labels are judged
  alike with `--pairs` on the `label_pairs` of `Tests/Fixtures/expected.json`.
  `eval` needs an Ollama with the profile's models, named on the command
  with `ARRUMATOR_OLLAMA_URL` and never written into the repository; it
  isolates itself, so it needs no scratch home. A regression that repeats
  across the passes is a cause to find, never chance. Where no Ollama is at
  hand, the spec and the report say that the numbers are owed, and who runs
  them.
- **G47** Reading knowledge never lives in code: no `switch`, keyword list or
  regex maps a document's type, sender, words or language to a label or a
  name. What a document is, and what it is called, is the model's judgment,
  guided by `Sources/ArrumatorClassify/Prompts/labels-system.md` and held to
  each kind's form by `DocumentLabel.normalized` and `AnswerValidator`
  (`Sources/ArrumatorClassify/ClassificationSchema.swift`). The prompt's
  examples are never cases of the corpus that measures it
  (`LabelPairJudgeTests`).

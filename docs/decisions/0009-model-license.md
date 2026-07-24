# 0009: Model license (CC-BY-SA 4.0)

## Fact
`zenz-v3.1-small-gguf` (Miwa Keita / 三輪) is licensed **CC-BY-SA 4.0**, a copyleft
license — distinct from the MIT license used by AzooKeyKanaKanjiConverter, azooKey,
SampleIME, and Ohagey's own code.

## Decision
Treat the model as a separately-licensed asset, not part of Ohagey's own codebase:
- Never committed to this repository
- Downloaded as a standalone file at install time (decision 0008)
- Attribution (author name, license name, link to the model page) shown in the
  settings app's "About" screen
- Ohagey's own source code remains MIT; only the model file itself carries
  CC-BY-SA 4.0 obligations

## Rationale
This mirrors how `unok/myime` and the Android app "Sumire" both treat the model as
an external, separately-licensed asset rather than folding it into their own
code license. Because the model is fetched at runtime rather than statically linked
or embedded, this separation is both technically and legally clean.

## Required attribution text (settings app "About" screen)
> This app uses the "zenz-v3.1-small" neural conversion model by Keita Miwa,
> licensed under CC-BY-SA 4.0.
> https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf

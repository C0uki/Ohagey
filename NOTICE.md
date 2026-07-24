# Third-Party Notices

Ohagey (this repository) is MIT licensed. It depends on, vendors, or downloads the
following third-party components:

## Microsoft SampleIME
- Source: https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME
- License: MIT (repository-level; see upstream LICENSE)
- Usage: Vendored into `tsf/SampleIME/` as the base TSF (Text Services Framework)
  implementation, heavily modified.

## AzooKeyKanaKanjiConverter
- Source: https://github.com/azooKey/AzooKeyKanaKanjiConverter
- License: MIT
- Usage: Swift Package dependency of `engine/`. Provides kana-kanji conversion and
  Zenzai integration.

## azooKey
- Source: https://github.com/azooKey/azooKey
- License: MIT
- Usage: Ohagey is an unofficial, independent Windows port inspired by azooKey. Not
  affiliated with or endorsed by the azooKey project.

## Zenzai model weights (zenz-v3.1-small)
- Source: https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf
- Author: Keita Miwa (三輪)
- License: **CC-BY-SA 4.0** (distinct from the MIT-licensed code above)
- Usage: NOT bundled in this repository or installer. Downloaded directly from
  Hugging Face at first run (see `docs/decisions/0008-model-distribution.md`).
  Attribution is displayed in the settings app's "About" screen.

## Prior art referenced during design (no code reused)
- [azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows) by fkunn1326 — MIT
- [myime](https://github.com/unok/myime) by unok — reference for the Mozc-style
  shared-server architecture and model distribution approach

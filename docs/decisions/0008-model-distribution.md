# 0008: Model distribution

## Decision
The Zenzai model (`zenz-v3.1-small-gguf`) is downloaded directly from Hugging Face
(`https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf`) by the Inno Setup installer
at install time, not bundled inside the installer.

If the download fails (offline install, blocked network — common on school/managed
PCs), installation still succeeds. Ohagey falls back to AzooKeyKanaKanjiConverter's
non-neural dictionary-based conversion (`zenzaiMode: .off`-equivalent) until a model
becomes available. The model can be retried from the settings app at any time.

## Why
- Keeps the installer small and fast to (re)build during development
- Matches prior art (`unok/myime` does the same: downloads `ggml-model-Q5_K_M.gguf`
  from the same Hugging Face repo at install time, continuing on failure)
- Avoids the "installed but can't type at all" failure mode on restricted networks

## Storage location
`%ProgramFiles%\Ohagey\models\ggml-model-Q5_K_M.gguf` (machine-wide, shared across
all users of the PC — the model itself contains no per-user data, unlike learning
data which lives under `%LOCALAPPDATA%`, see decision 0024).

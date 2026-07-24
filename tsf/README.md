# tsf/ — TSF text service (C++)

This directory vendors and heavily modifies Microsoft's official SampleIME
(decision 0002/0003), from:
https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME/cpp/SampleIME

## Vendoring steps (to be run once, recorded here for reproducibility)
```
# From repo root:
git clone --depth 1 --filter=blob:none --sparse https://github.com/microsoft/Windows-classic-samples.git _tmp-wcs
cd _tmp-wcs
git sparse-checkout set Samples/IME/cpp/SampleIME
cp -r Samples/IME/cpp/SampleIME/* ../tsf/SampleIME/
cd ..
rm -rf _tmp-wcs
```
(Sparse checkout avoids cloning the entire Windows-classic-samples monorepo —
decision 0021.)

## Planned modifications from upstream SampleIME
- `CompositionProcessorEngine` / dictionary lookup → replaced with a named-pipe
  client (Protobuf) talking to `engine/` (OhageyEngine), decisions 0004–0007
- `CandidateWindow` → rewritten using DirectWrite/DirectComposition with Fluent
  Design styling, replacing the original `ExtTextOut`-based GDI rendering
  (decisions 0011/0012)
- All entry points wrapped in SEH (`__try`/`__except`) to prevent host-application
  crashes (decision 0017)
- Registration (`Register.cpp`) reviewed for x64-only builds (decision 0018)

## Status
🚧 Not yet vendored. This README documents the planned process; run the steps above
to populate `tsf/SampleIME/` before starting implementation.

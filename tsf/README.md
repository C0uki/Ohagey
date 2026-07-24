# tsf/ — TSFテキストサービス(C++)

このディレクトリには、Microsoft公式のSampleIME(決定0002/0003)をvendoringし、大幅に
改造したものを配置します。取り込み元:
https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME/cpp/SampleIME

## vendoring手順(一度だけ実行、再現性のため記録)
```
# リポジトリのルートから実行:
git clone --depth 1 --filter=blob:none --sparse https://github.com/microsoft/Windows-classic-samples.git _tmp-wcs
cd _tmp-wcs
git sparse-checkout set Samples/IME/cpp/SampleIME
cp -r Samples/IME/cpp/SampleIME/* ../tsf/SampleIME/
cd ..
rm -rf _tmp-wcs
```
(sparse checkoutにより、Windows-classic-samples全体をcloneせずに済みます — 決定0021)

## 本家SampleIMEからの主な改造予定点
- `CompositionProcessorEngine`/辞書検索 → 名前付きパイプ経由のクライアント(Protobuf)に
  置き換え、`engine/`(OhageyEngine)と通信する(決定0004〜0007)
- `CandidateWindow` → 元々の`ExtTextOut`ベースのGDI描画から、DirectWrite/DirectComposition
  + Fluent Designスタイルの描画に書き換える(決定0011/0012)
- 全エントリーポイントをSEH(`__try`/`__except`)で保護し、ホストアプリのクラッシュを防ぐ
  (決定0017)
- `Register.cpp`をx64専用ビルドとして見直す(決定0018)

## ステータス
🚧 まだvendoringしていません。このREADMEは手順の記録です。実装を始める前に上記の
コマンドを実行し、`tsf/SampleIME/`を実際に取り込んでください。

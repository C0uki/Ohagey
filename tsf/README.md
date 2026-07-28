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

## ⚠️ パイプに接続するときの権限指定(決定0031)

**`CreateFileW` を `GENERIC_READ | GENERIC_WRITE` で呼んではいけません。**

パイプにおいて `GENERIC_WRITE` は `FILE_CREATE_PIPE_INSTANCE`(= `FILE_APPEND_DATA`、
ビット `0x4`)まで展開されます。エンジンの ACL は、サンドボックス化されたクライアントに
この権限を**意図的に与えていません** — 持っていると、同じパイプ名のインスタンスを立てて
他のアプリの入力を読めてしまうためです。アクセスチェックは要求した全ビットを要求するので、
`GENERIC_*` で開くと **AppContainer(UWP)アプリから接続できません**。

必要な権限を明示してください:

```cpp
HANDLE pipe = CreateFileW(
    pipeName,
    FILE_READ_DATA | FILE_WRITE_DATA
        | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES
        | SYNCHRONIZE,          // = 0x100183
    0, nullptr, OPEN_EXISTING, 0, nullptr);
```

パイプが埋まっているときは `ERROR_PIPE_BUSY` が返るので、`WaitNamedPipeW` で待って
リトライしてください(サーバーは接続を受けた直後に次のインスタンスを作りますが、
その受け渡しの一瞬だけ空きが無くなります)。

## ステータス
🚧 まだvendoringしていません。このREADMEは手順の記録です。実装を始める前に上記の
コマンドを実行し、`tsf/SampleIME/`を実際に取り込んでください。

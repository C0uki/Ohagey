# tsf/ — TSFテキストサービス(C++)

このディレクトリには、Microsoft公式のSampleIME(決定0002/0003)をvendoringし、大幅に
改造したものを配置します。取り込み元:
https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME/cpp/SampleIME

## vendoring手順(実施済み・再現性のため記録)

**取り込み元コミット: `77f217b3f89d4dac7864a62cc91ff7b569f26a50`**
(microsoft/Windows-classic-samples、MIT License)

```bash
# clone 先は短いパスにすること。ワークツリー配下に置くと、深いパスと相まって
# Windows の 260 文字制限に当たることがある(docs/local-setup.md 参照)。
git clone --depth 1 --filter=blob:none --sparse https://github.com/microsoft/Windows-classic-samples.git C:/swb/wcs
cd C:/swb/wcs
git sparse-checkout set Samples/IME/cpp/SampleIME
cp -r Samples/IME/cpp/SampleIME/* <repo>/tsf/SampleIME/
rm -rf <repo>/tsf/SampleIME/Dictionary      # 下記参照
cp LICENSE <repo>/tsf/SampleIME/LICENSE-Microsoft.txt
```

(sparse checkoutにより、Windows-classic-samples全体をcloneせずに済みます — 決定0021)

### 取り込まなかったもの

- **`Dictionary/SampleIMESimplifiedQuanPin.txt`(1.5MB)** — 簡体字 Pinyin の変換表。
  おはぎーは日本語 IME で、辞書引きは `engine/` 側に置き換える(決定 0004〜0007)ため、
  最初から不要。コミットしてから消すだけの 1.5MB なので取り込んでいない。
  これを読む `TableDictionaryEngine` / `DictionaryParser` 等も置き換え対象。

### ライセンス

Microsoft 版の MIT ライセンス文を `SampleIME/LICENSE-Microsoft.txt` として保持している。
おはぎー自体も MIT(決定 0022)なので条件は満たせるが、**帰属表示は残すこと**。

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

## ビルド

「x64 Native Tools Command Prompt for VS 2022」で:

```bat
cd tsf\SampleIME
msbuild SampleIME.vcxproj /p:Configuration=Release /p:Platform=x64
```

**Debug / Release とも警告ゼロでビルドが通り、`x64\{Debug,Release}\SampleIME.dll` が
生成される**ことを確認済み。COM のエクスポート(`DllGetClassObject` /
`DllCanUnloadNow` / `DllRegisterServer` / `DllUnregisterServer`)も揃っている。

### 本家からのビルド設定の変更点

| 変更 | 理由 |
|---|---|
| `Win32` 構成を削除 | x64 のみ対応(決定 0018)。Debug/Release × x64 の2構成だけにした |
| `PlatformToolset` を `v110` → `v143` | VS2012 のツールセットは入っていない |
| `VCTargetsPath11` フォールバックを削除 | VS2012 の名残。現行 MSBuild を存在しないツールセットに向けてしまう |
| `Windows Kits\8.0` の include/lib 絶対パスを削除 | 2012年の SDK。未インストールで、実効パスの後ろに付いていたため無視されていただけ |
| Release の `OptimizeReferences` / `EnableCOMDATFolding` の `false` を削除 | `/OPT:NOREF` が `WholeProgramOptimization` の LTCG と衝突する(LNK1295) |
| Debug の `DebugInformationFormat` を `ProgramDatabase` に | 既定の /ZI が `/INCREMENTAL:NO` で捨てられ、毎回 LNK4075 が出ていた |

## エンジンとの IPC(`../Ohagey/`)

`tsf/Ohagey/` は vendoring したコードではなく**おはぎー自身のコード**。

| ファイル | 役割 |
|---|---|
| `OhageyProtocol.h` | クライアント API(`EngineClient`)と結果型 |
| `OhageyWire.{h,cpp}` | Protobuf の wire 形式。**`ohagey.proto` の範囲だけ手書き**(決定 0032) |
| `OhageyEngineClient.cpp` | 名前付きパイプ接続、フレーミング、リクエスト/レスポンス |
| `RomajiKana.{h,cpp}` | ローマ字 → かな変換。Windows にも TSF にも依存しない |
| `CandidateTheme.{h,cpp}` | 候補ウィンドウの配色。ライト/ダークとアクセントを system から読む(決定 0012) |
| `CandidateRenderer.{h,cpp}` | Direct2D + DirectWrite による候補ウィンドウ描画(決定 0011/0012) |
| `tools/engine-roundtrip.cpp` | **実エンジンとの往復ハーネス**(ローマ字→かな→変換の通しを含む) |
| `tools/kana-selftest.cpp` | ローマ字 → かな変換のテスト(エンジン不要) |
| `tools/theme-selftest.cpp` | 配色ルールのテスト。**選択行が見えることを保証**(エンジン不要) |
| `tools/candidate-preview.cpp` | 候補ウィンドウを画像に描き出す。TSF 登録なしで見た目を確認する |

`OhageyWire.cpp` は**生成コードではない**。`ohagey.proto` を変更したら手で追随すること。
エンジン側は `swift-protobuf` の生成コードなので、食い違えば往復ハーネスで必ず露見する。

```bat
rem 変換の往復（OhageyEngine.exe を起動しておくこと）
powershell -File tsf\Ohagey\tools\build-and-run.ps1
rem ローマ字→かな（エンジン不要）
powershell -File tsf\Ohagey\tools\build-and-run-kana.ps1
```

## ローマ字 → かな(`RomajiKana`)

エンジンは**ひらがな**の読みを期待している(`ConversionService` は `.direct` 入力方式で
「TSF 層がローマ字をかなに解決済み」を前提にしている)。SampleIME のキーストローク
バッファは中国語 Pinyin 用の ASCII なので、その橋渡しがここ。

かなは**キーストロークバッファから変換時に導出する**。変換器を別の状態として並行して
持たないのは、`RemoveVirtualKey` が添字で途中削除できるため、同期がずれるバグの温床に
なるから。真実の源はバッファ1つに保つ。

**`nn` の扱いに注意**: `nn` は普通ん1文字だが、後ろに母音か `y` が続くときは
2つ目の `n` が次の音節の頭になる。`sannin` は さんにん であって さんいん ではない。
先読みが要るので、1文字ずつ解決するのではなく毎回ローマ字全体を走査している。

## ステータス

- [x] vendoring(上記コミットから取り込み)
- [x] x64 でビルドが通る(決定 0018)
- [x] `CompositionProcessorEngine` の辞書検索 → `EngineClient` に置換
- [x] ローマ字 → かな変換
- [x] 合成中の表示をかなにする
- [x] 確定時の学習フィードバック(`Commit`)の配線 — ただし Zenzai 有効時は順位に効かない(`docs/roadmap.md` 参照)
- [ ] エンジンのオンデマンド起動(決定 0015)— インストール先が未確定(フェーズ3)
- [ ] 候補ウィンドウを DirectWrite/DirectComposition + Fluent Design に書き換え
- [ ] 全エントリポイントを SEH で防御(決定 0017)
- [ ] MSBuild と `swift build` の連携(決定 0020)、CI で有効化

### 読み(`Reading()`)と表示(`Display()`)の違い

エンジンに送る**読み**と、画面に出す**表示**は別物。分けてあるのは意図的。

| 入力 | 表示 | 読み |
|---|---|---|
| `k` | `k` | (無し) |
| `ky` | `ky` | (無し) |
| `henk` | `へんk` | `へん` |
| `hon` | `ほん` | `ほん` |
| `hona` | `ほな` | `ほな` |

未解決のローマ字は**表示には残す**(`ky` と打った人にはそれが見えている必要がある)が、
**読みからは落とす**(`ky` は読みではなく、エンジンに文字を渡すことになる)。
語末の単独 `n` だけは両方でんになる。

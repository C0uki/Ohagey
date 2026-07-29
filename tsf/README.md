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

## ステータス

- [x] vendoring(上記コミットから取り込み)
- [x] x64 でビルドが通る(決定 0018)
- [ ] `CompositionProcessorEngine`/辞書検索 → 名前付きパイプクライアントに置換
- [ ] 候補ウィンドウを DirectWrite/DirectComposition + Fluent Design に書き換え
- [ ] 全エントリポイントを SEH で防御(決定 0017)
- [ ] MSBuild と `swift build` の連携(決定 0020)、CI で有効化

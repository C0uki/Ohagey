# ローカル開発環境の構築(Windows)

おはぎーは Windows x64 専用(決定 0018)。TSF・WinUI 3・インストーラーは
**Windows 実機でしかビルド・検証できない**。エンジン(Swift)も最終ターゲットは Windows。

## 必要なツール

| 対象 | ツール | 備考 |
|---|---|---|
| **最初に入れる** | **Visual Studio 2022(「C++ によるデスクトップ開発」ワークロード)** | **TSF ヘッダ(`msctf.h` 等)に加え、cmake と MSVC コンパイラが同梱される。llama.cpp のビルドにも必要**(決定 0002/0003) |
| `engine/` | [Swift for Windows](https://www.swift.org/install/windows/) | **6.1 以上が必須**(`Package.swift` が package traits を使うため)。6.3.3 で動作確認 |
| `engine/`(proto 生成) | `protoc` + `protoc-gen-swift` | 下記「Protobuf の生成」参照 |
| `settings-app/` | .NET SDK + Windows App SDK(WinUI 3) | 決定 0013 |
| `installer/` | [Inno Setup](https://jrsoftware.org/isinfo.php) | `iscc` でコンパイル |
| 共通 | Git | — |

Zenzai の GPU バックエンドを試す場合のみ追加で:
CUDA なら NVIDIA ドライバ + CUDA Toolkit、Vulkan なら Vulkan SDK(決定 0010/0028)。
**まずは CPU で動かすので必須ではない。**

### Visual Studio のどれを入れるか

- **Visual Studio Professional 2022**(または Enterprise)— 推奨。フェーズ2で TSF DLL を
  ホストアプリのプロセス内でデバッグするため、IDE のデバッガがあると楽。
- **Build Tools for Visual Studio 2022** — IDE 無しでコンパイラ・cmake・Windows SDK だけ。
  軽量で、`engine/` のビルドはこれでも通る。
- 以下は**別物なので選ばない**: Visual C++ Redistributable(実行時ランタイム)、
  Agents、Remote Tools、Intellitrace、Visual Studio for Mac。

エディションよりも重要なのは、インストーラーで「**C++ によるデスクトップ開発**」
ワークロードにチェックを入れること。これを忘れると cmake も MSVC も入らない。

### ⚠️ 「x64 Native Tools Command Prompt for VS 2022」を使うこと

通常のコマンドプロンプトや PowerShell では `cmake` に PATH が通っておらず、
`'cmake' は、内部コマンドまたは外部コマンド…として認識されていません` になる。

スタートメニューで「**x64 Native Tools Command Prompt for VS 2022**」を検索して
起動すること。cmake と MSVC に PATH が通った状態で開く。
**x64 版**を選ぶこと(おはぎーは x64 のみ対応・決定 0018)。

cmake だけなら `winget install Kitware.CMake` でも入るが、**C++ コンパイラは別途必要**
なので結局 Visual Studio が要る。

### 表記について

以下のコマンド例で `C:\path\to\...` と書いてある箇所は**自分の環境の実際のパスに
置き換える**。そのまま入力しても動かない。

## llama.cpp の用意(`swift build` の前提条件・決定 0028)

⚠️ **これを済ませないと `engine/` はビルドできない。**

upstream(AzooKeyKanaKanjiConverter)は Windows / Linux では `llama.cpp` を
**`.systemLibrary` ターゲット**として宣言している。つまり SPM は llama.cpp を
ビルドせず、**こちらが用意したライブラリにリンクする**(Apple プラットフォームのみ
`.binaryTarget` の xcframework を自動取得する)。

ヘッダと module map は upstream が同梱している:

```
module llama [system] {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    link "llama"
    export *
}
```

`link "llama"` があるので、**リンカが `llama.lib` を見つけられる必要がある**。
つまり用意すべきものは:

1. `llama.lib`(インポートライブラリ、リンク時)
2. `llama.dll`(実行時)

### ⚠️ llama.cpp のバージョンは `b4846` に固定すること

**最新の master を使ってはいけない。** AzooKeyKanaKanjiConverter 0.8.5 は
llama.cpp のビルド **`b4846`** を前提にしている(upstream の `Package.swift` が
Apple 向けに参照している xcframework が
`azooKey/llama.cpp` の `b4846` リリース)。

これより新しい llama.cpp では KV キャッシュ API がリネームされて旧名が削除されており、
リンク時に次のエラーになる:

```
lld-link: error: undefined symbol: llama_kv_cache_seq_rm
lld-link: error: undefined symbol: llama_kv_cache_seq_pos_max
```

**AzooKeyKanaKanjiConverter の pin を上げるときは、llama.cpp 側の対応バージョンも
必ず確認し直すこと**(決定 0028 の「ビルド構成を記録する」に該当)。

### 手順(CPU 版・最初の一歩)

**「x64 Native Tools Command Prompt for VS 2022」で実行すること**(上記参照)。

```bat
cd C:\src
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git checkout b4846
cmake -B build-b4846 -DBUILD_SHARED_LIBS=ON
cmake --build build-b4846 --config Release
```

ビルドディレクトリにバージョンを含めておくと、複数バージョンを試すときに
CMake キャッシュの衝突を避けられる。

ビルドが終わったら `llama.lib` の場所を確認する(cmake の設定により出力先が変わるため、
決め打ちにせず探すのが確実):

```bat
dir /s /b build\*.lib
dir /s /b build\*.dll
```

`llama.lib` があるディレクトリを控えて、エンジンのビルド時にリンカへ渡す。
おはぎー本体もローカルに clone されている必要がある:

```bat
cd C:\src
git clone https://github.com/C0uki/Ohagey.git
cd Ohagey\engine
swift build -Xlinker -LC:\src\llama.cpp\build\bin\Release
```

最後の `-L` に続くパスは、上の `dir` で見つけた `llama.lib` の実際の場所に置き換える
(`C:\src\...` は例)。実行時には `llama.dll` にも PATH が通っている必要がある。

CUDA / Vulkan 版は `-DGGML_CUDA=ON` / `-DGGML_VULKAN=ON` を付けて別ディレクトリに
ビルドし、決定 0028 の `backends\{cpu,cuda,vulkan}\` へ配置する。
**バージョンとビルドフラグは再現性のため必ず記録すること**(決定 0028)。

> **リスク**: upstream の README が動作確認対象として挙げているのは
> iOS 16+ / macOS 13+ / visionOS 1+ / Ubuntu 22.04+ のみで、**Windows は含まれていない**。
> Windows でのビルドは前例が乏しい可能性があり、ここが本プロジェクト最大の技術的
> 未知数と考えられる。最初に着手して早期に地雷を踏んでおくのが望ましい。

## Protobuf の生成

`ohagey.proto`(決定 0007)から Swift 型を生成する。生成物 `ohagey.pb.swift` は
コミットする方針なので、通常の `swift build` に protoc は不要。`.proto` を変更したときだけ実行する。

```powershell
# protoc
winget install protobuf

# protoc-gen-swift（Swift ツールチェーン導入後）
git clone https://github.com/apple/swift-protobuf.git
cd swift-protobuf
swift build -c release
# .build\release\protoc-gen-swift を PATH に追加

# 生成
bash engine/Scripts/generate-proto.sh
```

## ビルド

```powershell
# エンジン（llama.lib のあるディレクトリを指定。上記「llama.cpp の用意」参照）
cd engine
swift build -Xlinker -L<llama.lib のあるディレクトリ>

# TSF（tsf/README.md の手順で SampleIME を vendoring した後）
# msbuild tsf\Ohagey.sln /p:Configuration=Release /p:Platform=x64

# インストーラー
# iscc installer\ohagey.iss
```

TSF テキストサービスの登録(`regsvr32` 相当)には**管理者権限**が必要。

## 現状の注意

`engine/Sources/OhageyEngine/` 配下のフェーズ1コードは、Swift ツールチェーンを導入できない
環境(Linux コンテナ、`download.swift.org` が egress ポリシーで遮断)で書かれており、
**一度もコンパイルされていない**。ローカルでの最初の `swift build` では、特に以下で
エラーが出る前提で臨むこと。

- `ConvertRequestOptions` の必須引数(`textReplacer`、`specialCandidateProviders`)。
  コードは upstream `main` の API を参照しているが、`Package.swift` は 0.8.0 系にピン留め。
- `PipeServer.swift` の WinSDK 呼び出し(型・オプショナル性)。
- 生成前の `ohagey.pb.swift` を参照する箇所(先に proto 生成が必要)。

### 実機で遭遇した問題と対処(記録)

| 症状 | 原因 | 対処 |
|---|---|---|
| `'package(url:_:traits:)' is unavailable` / `'Trait' is unavailable` | `Package.swift` の `swift-tools-version` が 5.10 で、`traits:` は PackageDescription 6.1 以降の API | tools-version を **6.1** に引き上げ済み。Swift 6.1 以上のツールチェーンが必要 |
| `'cmake' は…認識されていません` | 通常のコマンドプロンプトでは PATH が通らない | 「x64 Native Tools Command Prompt for VS 2022」を使う |
| `supported platforms can't be empty` | `Package.swift` の `platforms:` が空配列だった | `platforms:` の宣言ごと削除(省略可能。Apple 向けのデプロイターゲット記述用で Windows には不要) |
| `module 'KanaKanjiConverterModule' was built with C++ interoperability enabled, but current compilation does not enable C++ interoperability` | Zenzai trait 有効時、upstream は llama.cpp をラップするため C++ interop 付きでビルドされる。読み込む側も同じ設定が要る | `Package.swift` の `OhageyEngine` に `.interoperabilityMode(.Cxx)` を追加 |
| `'KanaKanjiConverter' has no member 'withDefaultDictionary'` / `cannot find type 'ZenzaiMode'` / `missing argument for parameter 'dictionaryResourceURL'` / `type 'Bool' has no member 'auto'` | コードを upstream `main` の API に対して書いていたが、pin により解決されるのは **0.8.5** で API が異なる | 0.8.5 に合わせて修正(下記) |

| `call to main actor-isolated initializer 'init()' in a synchronous actor-isolated context` | upstream の `KanaKanjiConverter` は `@MainActor` 隔離されたクラスで、別の `actor` からは所有できない | `ConversionService` を `actor` から `@MainActor final class` に変更 |
| `lld-link: error: undefined symbol: llama_kv_cache_seq_rm` / `llama_kv_cache_seq_pos_max` | llama.cpp が新しすぎる。KV キャッシュ API がリネームされ旧名が削除された | llama.cpp を **`b4846`** に checkout して再ビルド(上記「バージョンは `b4846` に固定」参照) |

> **設計上の含意**: 変換器が main actor に固定されているため、**エンジンは main actor
> 実行環境を持ち続ける必要がある**。パイプの accept ループや読み取りは別スレッドで
> よいが、変換呼び出しは必ず main actor にホップする。実装時にこの前提を崩さないこと。

#### 0.8.5 と `main` の API 差分(実装時の注意)

解決されるのは **0.8.5**。`main` のドキュメントや README をそのまま参考にすると食い違う。

| 項目 | 0.8.5 | `main` |
|---|---|---|
| `ZenzaiMode` | **`ConvertRequestOptions` のネスト型** | トップレベル |
| `requireJapanesePrediction` / `requireEnglishPrediction` | **`Bool`** | `PredictionMode` 列挙型 |
| 変換器の生成 | `KanaKanjiConverter()` | `KanaKanjiConverter.withDefaultDictionary()` |
| `dictionaryResourceURL` / `textReplacer` | 必須引数。`ConvertRequestOptions.withDefaultDictionary(...)` を使えば自動供給される | 同様 |
| `ZenzaiMode.on` の `personalizationMode` | 既定値なし。明示的に渡す必要がある | 同左 |

llama.cpp のビルド成果物の位置(cmake 既定):

- `llama.lib`(リンク時)→ `build\src\Release\`
- `llama.dll`(実行時)→ `build\bin\Release\` ※ `ggml.dll` 等の依存 DLL も同じ場所

tools-version を 6.x にすると既定の言語モードが Swift 6(strict concurrency)になり、
まだ一度も動かしていないコードに大量の Sendable エラーが出るため、当面は
`.swiftLanguageMode(.v5)` を指定している。**エンジンが動くようになったら `.v6` への
移行を検討すること**(`Package.swift` に TODO として記載)。

### 推奨する着手順(手戻りを減らす順序)

1. **llama.cpp(CPU 版)をビルドし、`swift build` を通す。**
   最大の未知数がここなので最初に潰す。この時点では変換の中身は動かなくてよい。
2. 型エラーを潰す。特に `ConvertRequestOptions` の引数を**ピン留めしている 0.8.0 系の
   実際のシグネチャ**に合わせる(必要なら `Package.resolved` で解決済みバージョンを確認)。
3. proto を生成して `RequestRouter` を実装する。
4. パイプの accept ループを実装し、簡単なクライアントから疎通確認する。

1 と 2 で `Package.swift` のピン留めバージョンを上げる判断が必要になる可能性がある。
その場合は決定ログに理由を記録すること。

詳細と未解決の設計課題は `docs/roadmap.md` の「フェーズ1」を参照。

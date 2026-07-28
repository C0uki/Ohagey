# ローカル開発環境の構築(Windows)

## Claude Code をローカルで使う

このリポジトリはクラウド環境(Claude Code on the web)から開発を始めたが、ローカルの
Windows 実機へ移行できる。TSF・WinUI 3・インストーラーはどのみち実機でしか扱えないため、
フェーズ2以降はローカルが前提になる。

### 導入(デスクトップアプリ)

Windows x64 版インストーラーを
[こちら](https://claude.ai/api/desktop/win32/x64/setup/latest/redirect)から入手して
インストールする。インストール後、Claude を起動してサインインし、**Code タブ**を開く。

> ⚠️ **Windows で Code タブを初めて開くときは
> [Git for Windows](https://git-scm.com/downloads/win) が必要。**
> 入れていない場合はインストール後にアプリを再起動すること。

CLI 版を使いたい場合は PowerShell で `irm https://claude.ai/install.ps1 | iex`、
または `winget install Anthropic.ClaudeCode`。設定ファイルは CLI と共通なので、
どちらを使っても `.claude/settings.json` の内容は効く。

### 使い方

Code タブでは会話ひとつが**セッション**で、それぞれ独自のチャット履歴・
プロジェクトフォルダ・変更を持つ。セッション作成時に**プロジェクトフォルダとして
`C:\src\Ohagey`(clone した場所)を選ぶ**。

`CLAUDE.md` は自動で読み込まれるので、プロジェクトの規約・現在地・バージョン固定の
注意を改めて説明する必要はない。会話履歴はクラウド側のセッションから引き継がれないが、
**設計判断は `docs/decisions/`、進捗と残タスクは `docs/roadmap.md`、ビルドの知見は
本ファイルに記録してある**ので、そこから再開できる。

> **並列セッションと worktree**: 新しいセッション(Ctrl+N)を作ると、Git リポジトリでは
> **セッションごとに Git worktree で隔離されたコピー**が作られる。コミットするまで
> 他のセッションに影響しない。
> ただし `.build/` は `.gitignore` 済みなので **worktree にはコピーされず、
> セッションごとにフルビルドが走る**(llama.cpp のリンクを含めて数分)。
> エンジンをビルドする作業は1つのセッションに集約した方が速い。

### 移行時の注意

- **リポジトリの場所**: llama.cpp の中に clone している場合は独立した場所
  (`C:\src\Ohagey` など)へ移すと扱いやすい。llama.cpp とは別物なので入れ子にする
  必然性はない。
- **ビルド成果物は引き継がない**: `.build/` は環境依存なので、移動後は再ビルドになる。
- **`LIB` と `PATH` はユーザー環境変数に登録することを推奨**。デスクトップアプリの
  セッションは「x64 Native Tools Command Prompt」から起動するわけではないため、
  `set` で都度指定する方式は使いにくい。以下をユーザー環境変数に入れておくと、
  アプリから実行するビルドでも効く。

  | 変数 | 追加する値 |
  |---|---|
  | `LIB` | `C:\path\to\llama.cpp\build-b4846\src\Release` |
  | `PATH` | `C:\path\to\llama.cpp\build-b4846\bin\Release` |

  ただし MSVC 自体のパス(`cl.exe` や Windows SDK)は Native Tools プロンプトが
  設定するものなので、**リンクエラーが出る場合は Native Tools プロンプトで
  `swift build` を実行して切り分けること**。

---


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

## ✅ 動作確認済みの構成

以下の組み合わせで `swift build` の成功(`OhageyEngine.exe` の生成)を確認済み。

| 項目 | バージョン |
|---|---|
| Windows SDK | 10.0.26100.0 |
| Visual Studio | 2022 Professional 17.14(MSVC 19.44) |
| Swift for Windows | 6.3.3 |
| AzooKeyKanaKanjiConverter | 0.8.5(`.upToNextMinor(from: "0.8.0")` が解決) |
| llama.cpp | **`b4846`**、`-DBUILD_SHARED_LIBS=ON`、CPU バックエンド(AVX512) |

### ビルドと実行(環境変数を使う方法・おすすめ)

`-Xlinker -L...` は**コマンドごとの指定で保存されない**ため、`swift build` と `swift run`
の両方に毎回渡す必要がある(`swift run` も再リンクするので、忘れると
`lld-link: error: could not open 'llama.lib'` になる)。

lld-link は MSVC 互換で `LIB` 環境変数を参照するので、**セッション先頭で 2 つ設定して
おけばフラグ無しで済む**:

```bat
rem リンク時: llama.lib の場所
set LIB=C:\path\to\llama.cpp\build-b4846\src\Release;%LIB%
rem 実行時: llama.dll / ggml*.dll の場所
set PATH=C:\path\to\llama.cpp\build-b4846\bin\Release;%PATH%

swift build
swift run
```

### テスト

```bat
swift test
```

`OhageyEngineCore`(framing と設定)は Windows・Protobuf・変換器のいずれにも依存しない
ため、**テストは llama.cpp のリンクを必要としない**。`LIB` の設定なしでも通るはずだが、
`swift test` はパッケージ全体をビルドするため、実際には上記の環境変数を設定した
状態で実行するのが確実。

フラグで明示したい場合は、**両方のコマンドに**付ける:

```bat
swift build -Xlinker -LC:\path\to\llama.cpp\build-b4846\src\Release
swift run   -Xlinker -LC:\path\to\llama.cpp\build-b4846\src\Release
```

`LIB` はリンク時、`PATH` は実行時と役割が違うので、**どちらか一方では足りない**。

> Windows で開発者モードが無効だと `unable to create symbolic link at .build\debug` という
> 警告が出るが無害。実体は `.build\x86_64-unknown-windows-msvc\debug\OhageyEngine.exe`。

## 残っている注意点

**ビルドが通ったことと、正しく動くことは別**。以下はまだ検証されていない。

- ~~パイプ ACL(SDDL)のセキュリティレビュー~~ → 完了(決定 0031)。
  **UWP / AppContainer アプリからの実接続は未検証**(`AC` の許可と低整合性ラベルは
  仕様上の挙動から入れており、実機で測ってはいない)。
- **複数クライアントの同時接続は未検証。** 接続を順に張る形でしか試していない。
- **Zenzai 経路は未検証。** モデル未インストール時の辞書変換フォールバックでのみ確認した。

> `PipeServer` の WinSDK 呼び出しと実変換は**実クライアントとの往復で検証済み**に
> なった。何をどこまで確認したかは `docs/roadmap.md` の表を参照。

### protoc-gen-swift の用意(`Scripts/generate-proto.sh` の前提)

`protoc` 本体は `winget install protobuf` で入るが、`protoc-gen-swift` は別途ビルドが要る。
**依存として既に解決済みの swift-protobuf をそのまま使うのが確実**(pin と同じ 1.38.1 に
なるので、生成コードとランタイムのバージョン不一致が起きない):

```bat
xcopy /E /I <scratch>\checkouts\swift-protobuf C:\swb\pgs
cd C:\swb\pgs
swift build -c release --product protoc-gen-swift
```

生成された `.build\x86_64-unknown-windows-msvc\release\protoc-gen-swift.exe` を PATH に
通してから `bash engine/Scripts/generate-proto.sh` を実行する。
生成物 `ohagey.pb.swift` はコミットするので、通常の `swift build` に protoc は要らない。

### パスが長すぎてビルドできない場合(git worktree など)

`engine\.build\checkouts\AzooKeyKanaKanjiConverter\...` 配下のサブモジュールは
パスが深く、リポジトリを深い場所に置くと Windows の 260 文字制限に当たる:

```
fatal: cannot write keep file '...azooKey_dictionary_storage/objects/pack/pack-....keep': Filename too long
```

`git config core.longpaths true` だけでは回避できない。**`--scratch-path` で `.build` の
出力先を短いパスへ逃がすのが最も副作用が少ない**(システム設定もリポジトリ配置も変えない):

```bat
swift build --scratch-path C:\swb\<短い名前>
swift test  --scratch-path C:\swb\<短い名前>
```

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

| `found 2 file(s) which are unhandled`(`ohagey.proto` / `README.md`) | ビルド入力でないファイルがターゲット配下にある | `Package.swift` の `OhageyEngineProto` に `exclude:` を追加 |
| `lld-link: error: could not open 'llama.lib': no such file or directory`(`swift build` は通ったのに `swift run` で出る) | `-Xlinker -L...` はコマンドごとの指定。`swift run` も再リンクするため、フラグを渡さないと `llama.lib` を見失う | 両方のコマンドにフラグを渡すか、`LIB` 環境変数を設定する(上記「ビルドと実行」参照) |

llama.cpp のビルド成果物の位置(cmake 既定):

- `llama.lib`(リンク時)→ `build-b4846\src\Release\`
- `llama.dll`(実行時)→ `build-b4846\bin\Release\` ※ `ggml*.dll` 等の依存 DLL も同じ場所

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

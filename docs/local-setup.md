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
  | `LIB` | `C:\src\Ohagey\backends` |
  | `PATH` | `C:\src\Ohagey\backends\cpu` |

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
| `settings-app/`(ロジック・テスト) | **.NET SDK 8**(`winget install Microsoft.DotNet.SDK.8`) | 8.0.423 で動作確認。**ランタイムだけでは足りない** |
| `settings-app/`(WinUI 本体) | 上記 + **Visual Studio の MSBuild**(既にあるもので足りる) | `dotnet build` では建たない。下記参照 |
| `installer/` | [Inno Setup](https://jrsoftware.org/isinfo.php) | `iscc` でコンパイル |
| 共通 | Git | — |

Zenzai の GPU バックエンドを試す場合のみ追加で:
CUDA なら NVIDIA ドライバ + CUDA Toolkit、Vulkan なら Vulkan SDK(決定 0010/0028)。
**まずは CPU で動かすので必須ではない。**

### ⚠️ WinUI 3 は `dotnet build` では建たない

`settings-app/` のロジック部分(`Ohagey.Settings.Core` とそのテスト)は `dotnet` だけで
ビルド・テストできる。**WinUI 本体はできない。**

```
error MSB4062: "Microsoft.Build.Packaging.Pri.Tasks.ExpandPriContent" タスクを
アセンブリ ...\sdk\8.0.423\Microsoft\VisualStudio\v17.0\AppxPackage\Microsoft.Build.Packaging.Pri.Tasks.dll から読み込めませんでした
```

PRI(リソースインデックス)を作る MSBuild タスクは **Visual Studio 側**にあり、.NET SDK
には無い。**追加インストールは要らない** — 既にある VS の MSBuild を使えばよい:

```
"C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\amd64\MSBuild.exe"
```

`AppxGeneratePriEnabled=false` で当該ターゲットを飛ばせばビルドは通るが、PRI は
リソースインデックスそのものなので XAML のリソース解決が実行時に壊れる。採らない。

#### Restore と Build は分けて呼ぶこと

`-t:Restore,Build` を1回で呼ぶと、**クリーン後の初回だけ**失敗する。復元で入った
ターゲットが、評価済みのプロジェクトには反映されないため。症状は XAML 由来と分からない
3つのエラー(`Main` が無い / `InitializeComponent` が無い / 名前付き要素が無い)。

```
msbuild ... -t:Restore
msbuild ... -t:Build
```

#### 実機で踏んだ WinUI の落とし穴(記録)

| 症状 | 原因 | 対処 |
|---|---|---|
| 起動時に「Windows App Runtime が必要です」ダイアログ。**オンラインでの取得を促す** | unpackaged なアプリはランタイムが要る | `WindowsAppSDKSelfContained=true`。決定 0016(インストール時以外は通信しない)に反するので回避不可 |
| `ScrollViewer` を置いたページで `0xC0000374`(ヒープ破損)。managed のハンドラにも届かない | Windows App SDK **1.6** の問題 | **1.7 に上げる**。あわせて `ScrollView` を使う |
| `Slider` を置いたページで同上 | 同上(1.6) | 同上 |
| `Slider` のあるページで `0xC000027B` | XAML は属性の代入順を保証しない。`Minimum="1"` を既定の `Value`(0) より後に代入できず `Failed to assign to property 'RangeBase.Minimum'` | **範囲はコード側で** Maximum → Minimum → Value の順に設定する |

> ネイティブのクラッシュコードだけが出てメッセージがどこにも無い場合は、`App` の
> `UnhandledException` で例外をファイルに書き出すと実エラーが取れる。上の
> `RangeBase.Minimum` はそれで判明した。

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

### ⚠️ upstream の llama.cpp では**モデルが読めない**

`ggml-org/llama.cpp` ではなく **`azooKey/llama.cpp`** を clone すること。同じ `b4846`
タグでも中身が違う。

upstream の b4846 でビルドすると、**リンクも起動も通り、変換も返ってくる**。しかし
Zenzai は動いていない:

```
llama_model_load: error loading model: error loading model vocabulary:
  unknown pre-tokenizer type: 'gpt2-small-japanese-char'
llama_model_load_from_file_impl: failed to load model
```

zenz モデルは日本語 char 単位の pre-tokenizer を使う。これを知っているのは
azooKey の fork だけで(`src/llama-vocab.cpp`)、upstream には無い。

**症状が出ない形で失敗する**のが厄介なところ。エンジンは辞書変換にフォールバック
するので候補は返り続け、ログを見ない限り Zenzai が死んでいることに気付けない。
エンジンはこれを検出して

```
OhageyEngine: Zenzai model FAILED TO LOAD — converting from the dictionary only. ...
```

と出すようにしてある(それ以前は、モデル**ファイルの存在**だけを見て
`zenzai_used=true` を返していた)。

なお、新しい upstream(b4846 より後)を使うと今度はリンク段階で落ちる。下記参照。

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

### 手順 — プレビルドを取ってくる(推奨)

**自前でビルドする必要はない。** `azooKey/llama.cpp` は `b4846` の Windows x64
バイナリをバックエンド別に公開しているので、それを取ってくる:

```powershell
.\tools\fetch-backends.ps1                        # CPU のみ(17MB)
.\tools\fetch-backends.ps1 -Backends cpu,cuda     # CUDA も(192MB)
```

リポジトリ直下の `backends\` に、決定 0028 のレイアウトそのままで展開される:

```
backends\llama.lib          リンク時。3バックエンド共通(ABI 互換なので1つで足りる)
backends\cpu\*.dll          実行時。llama.dll / ggml*.dll / llava_shared.dll
backends\cuda\*.dll
backends\vulkan\*.dll
```

`backends\` は `.gitignore` 済み。ビルドはこう:

```powershell
$env:LIB  = "C:\src\Ohagey\backends;$env:LIB"       # llama.lib
$env:PATH = "C:\src\Ohagey\backends\cpu;$env:PATH"  # llama.dll
cd engine
swift build
```

取得元は `fkunn1326/llama.cpp`(azooKey-Windows が使っている個人の fork)ではなく
**`azooKey/llama.cpp` にしてある**。中身は同じだが、この DLL は
**ユーザーが文字を打つあらゆるアプリのプロセスに入る**ので、変換器と同じ組織が
出しているものを使う。

どのビルドを取っているか:

| バックエンド | アセット | 備考 |
|---|---|---|
| `cpu` | `llama-b4846-bin-win-avx-x64.zip` | avx2/avx512 ではなく **avx**。速いより、動かない機械が無い方を取る |
| `cuda` | `llama-b4846-bin-win-cuda-cu12.4-x64.zip` | 192MB。cu11.7 版もある |
| `vulkan` | `llama-b4846-bin-win-vulkan-x64.zip` | |

プレビルドにも日本語 pre-tokenizer が入っていることは確認済み
(`llama.dll` に `gpt2-small-japanese-char` の文字列がある。上記
「upstream の llama.cpp ではモデルが読めない」参照)。

### 手順 — 自分でビルドする場合

fork に手を入れて試すときだけ必要。**「x64 Native Tools Command Prompt for VS 2022」で**:

```bat
cd C:\src
git clone https://github.com/azooKey/llama.cpp.git azooKey-llama.cpp
cd azooKey-llama.cpp
git checkout b4846
cmake -B build-b4846 -DBUILD_SHARED_LIBS=ON
cmake --build build-b4846 --config Release
```

`ggml-org/llama.cpp` ではなく `azooKey/llama.cpp` であることを確認すること
(前節の通り、間違えても**エラーは出ず Zenzai だけが黙って無効になる**)。

出力先は cmake の設定で変わるので、決め打ちにせず探す:

```bat
dir /s /b build-b4846\*.lib
dir /s /b build-b4846\*.dll
```

CUDA / Vulkan 版は `-DGGML_CUDA=ON` / `-DGGML_VULKAN=ON` を付けて別ディレクトリへ。
いずれも `backends\{cpu,cuda,vulkan}\` へ配置すればプレビルドと同じように使える。
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
# エンジン（先に .\tools\fetch-backends.ps1 を実行しておくこと）
cd engine
swift build -Xlinker -L..\backends

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
| llama.cpp | **`b4846`**、`azooKey/llama.cpp` の `llama-b4846-bin-win-avx-x64.zip`(プレビルド) |

### ビルドと実行(環境変数を使う方法・おすすめ)

`-Xlinker -L...` は**コマンドごとの指定で保存されない**ため、`swift build` と `swift run`
の両方に毎回渡す必要がある(`swift run` も再リンクするので、忘れると
`lld-link: error: could not open 'llama.lib'` になる)。

lld-link は MSVC 互換で `LIB` 環境変数を参照するので、**セッション先頭で 2 つ設定して
おけばフラグ無しで済む**:

```bat
rem リンク時: llama.lib の場所
set LIB=C:\src\Ohagey\backends;%LIB%
rem 実行時: llama.dll / ggml*.dll の場所
set PATH=C:\src\Ohagey\backends\cpu;%PATH%

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
swift build -Xlinker -LC:\src\Ohagey\backends
swift run   -Xlinker -LC:\src\Ohagey\backends
```

`LIB` はリンク時、`PATH` は実行時と役割が違うので、**どちらか一方では足りない**。

> Windows で開発者モードが無効だと `unable to create symbolic link at .build\debug` という
> 警告が出るが無害。実体は `.build\x86_64-unknown-windows-msvc\debug\OhageyEngine.exe`。

## 変換器そのものを触るとき — `OHAGEY_CONVERTER_PATH`

**`.build/checkouts/` の中を編集しても反映されない。** SwiftPM はあそこを自分の管理下の
キャッシュとして扱うので、編集して `swift build` しても1秒で「Build complete」と言い、
**前のバイナリをそのままリンクする**。決定 0034 は、これに気づかず取った測定を
まるごと撤回している。

fork をクローンして `OHAGEY_CONVERTER_PATH` を指すと、`.package(path:)` に切り替わる:

```powershell
git clone --recurse-submodules https://github.com/C0uki/AzooKeyKanaKanjiConverter C:\swb\AzooKeyKanaKanjiConverter
cd C:\swb\AzooKeyKanaKanjiConverter
git checkout fdaaa9a1dff92109e7b1d88521fe8993b14df2a3
git submodule update --init --recursive

$env:OHAGEY_CONVERTER_PATH = "C:\swb\AzooKeyKanaKanjiConverter"
swift build --scratch-path C:\swb\13x
```

踏むところが4つある:

1. **ディレクトリ名は `AzooKeyKanaKanjiConverter` でなければならない。**
   SwiftPM は path 依存の identity をマニフェストではなく**最後のパス要素**から取る。
   他の名前だと、依存する全ターゲットが `unknown package 'AzooKeyKanaKanjiConverter'`
   で落ちる
2. **scratch を分けること**(上では `C:\swb\13x`)。同じ scratch で pin と path を
   行き来すると、そのたびに全部ビルドし直しになる
3. **`backends\cpu\` を新しい scratch の出力ディレクトリにコピーすること。**
   エンジンは exe の隣の `backends\<name>\` を見る(決定 0028):

   ```powershell
   Copy-Item <repo>\backends\cpu\*.dll C:\swb\13x\x86_64-unknown-windows-msvc\debug\backends\cpu\
   ```

   忘れると **「Zenzai モデルは読めているのに変換が空で返る」**という紛らわしい
   落ち方をする。起動ログに `backend: cpu is not installed` と出るので、そこを見ること

4. **`engine/Package.resolved` が書き換わる。** path 依存には pin が無いので、
   上書きビルドを回すと converter の pin が **`Package.resolved` から消える**。
   環境変数を外して普通にビルドし直せば戻るが、**その差分をコミットしないこと** —
   pin が落ちた `Package.resolved` は、他の全員のビルドから再現性を奪う。
   `git status` に出ていたら `git checkout -- engine/Package.resolved` で戻す

環境変数を外せば pin されたリビジョンに戻る。**CI と出荷ビルドは常にそちら**である。

編集が本当に効いているかは、まず**明らかに壊れる版**をビルドして確かめるとよい
(決定 0034 の 2026-08-04 追記その3 では、混合項に 0 を掛けた版で確かめた)。

## 残っている注意点

**ビルドが通ったことと、正しく動くことは別**。以下はまだ検証されていない。

- ~~パイプ ACL(SDDL)のセキュリティレビュー~~ → 完了(決定 0031)。
  **UWP / AppContainer アプリからの実接続は未検証**(`AC` の許可と低整合性ラベルは
  仕様上の挙動から入れており、実機で測ってはいない)。
- ~~複数クライアントの同時接続~~ → 6クライアント同時で確認済み。
- ~~Zenzai 経路~~ → 検証済み(下記)。
- **UWP / AppContainer アプリからの実接続は未検証。**

## Zenzai の実測(2026-07)

`Miwa-Keita/zenz-v3.1-small-gguf` の `ggml-model-Q5_K_M.gguf`(70.44 MiB)で確認した。

### 開発時のモデル配置(管理者権限は不要)

実配置先 `%ProgramFiles%\Ohagey\models\` への書き込みには管理者権限が要るが、
**`OHAGEY_MODEL_PATH` で上書きできる**。好きな場所にモデルを置けばよい:

```bat
curl -L --create-dirs -o C:\swb\models\ggml-model-Q5_K_M.gguf ^
  https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf
set OHAGEY_MODEL_PATH=C:\swb\models\ggml-model-Q5_K_M.gguf
```

**この上書きは debug ビルドでしか効かない**(release では無視される)。理由は決定 0008 を参照。
効いているかは起動ログで分かる:

```
OhageyEngine: OHAGEY_MODEL_PATH is set — debug builds only, ignored in release
OhageyEngine: Zenzai model found at C:/swb/models/ggml-model-Q5_K_M.gguf
```

> `ProgramFiles` 環境変数を差し替える手は**使えない**。Windows は新規プロセス生成時に
> この変数をレジストリから再設定するので、子プロセスには元の値しか渡らない(実測)。
> `OHAGEY_MODEL_PATH` はまさにこれが理由で用意してある。

### base 言語モデルの配置 — **これが無いと個人化は完全に無効**

個人化(決定 0034)には zenz の重みとは**別に** base の n-gram モデルが要る。
出荷物ではインストーラが `{app}\models\` に入れる(決定 0008 の追記)。開発機では
インストーラを通さないので、自分で取ってきて `OHAGEY_BASE_LM_PATH` に
**接尾辞と拡張子を除いた接頭辞**を渡す:

```bat
for %f in (lm_c_abc lm_r_xbx lm_u_abx lm_u_xbc) do curl -L --create-dirs ^
  -o C:\swb\base_n5_lm\%f.marisa ^
  https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/%f.marisa

set OHAGEY_BASE_LM_PATH=C:\swb\base_n5_lm\lm
```

インストーラと同じ検証を掛けたければ `installer\download-model.ps1` を直接呼べる
(`-Sha256` は `installer\ohagey.iss` に固定してある値):

```powershell
powershell -NoProfile -File installer\download-model.ps1 `
  -Url https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/lm_r_xbx.marisa `
  -Dest C:\swb\base_n5_lm\lm_r_xbx.marisa `
  -Sha256 F9594D23E2F15A8E6D51811F15B23E23BFC7CEFD24B8B1C06F3F0366CE5BF555
```

**`OHAGEY_MODEL_PATH` と同じく debug ビルドでしか効かない。** release が見るのは
`%ProgramFiles%\Ohagey\models\lm_*.marisa` だけである。

半日これで潰した(決定 0034 の 2026-08-04 追記)。**無いときの症状が「エラー」ではなく
「個人化が何もしない」**なので、測定地点からは見えない。起動ログには出る:

```
OhageyEngine: personalisation: no base language model installed — falling back to an empty one, which is INERT: ...
OhageyEngine: personalisation: using the installed base language model
```

個人化を主題にするハーネスは `tsf/Ohagey/tools/base-lm-status.ps1` で不在を検出する。

変換品質は辞書のみとは明確に別物:

| 読み | 結果 |
|---|---|
| きょうはいいてんきですね | 今日はいい天気ですね |
| ひこうきのじかんにまにあった | 飛行機の時間に間に合った |
| たなかさんにでんわしてください | 田中さんに電話してください |

レイテンシ(release ビルド・CPU バックエンド・`n_best=5`):

| 条件 | p50 | p95 |
|---|---|---|
| 未使用の読み・学習 OFF | **68〜95ms** | **86〜142ms** |
| 接続後の初回リクエスト | 260〜460ms | — |

`zenzaiInferenceLimit` を 1 / 3 / 10 で振ったが、**読みのセット間のばらつきを超える差は出なかった**。

### ⚠️ 計測でハマった点(同じ轍を踏まないこと)

**素朴に測ると1桁速い数字が出るが、それはキャッシュを測っている。**
実際に3回やり直した。

1. **同じ読みを繰り返さない。** 初回だけ遅く以降が一定になる。変換器が状態を持つため。
2. **学習を OFF にし、学習データを消してから測る。** 学習が ON だと、一度変換した読みは
   学習ストアに入って以降速くなる。設定を変えて再測定すると、前の測定の学習が効いて
   「設定を変えたら速くなった」と誤読する。
3. **クライアント起動時間を含めない。** 接続を開いたまま往復だけを測る。
   スクリプトを毎回起動すると 400〜850ms に見えるが、その大半は PowerShell の起動。

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
| `lld-link: error: failed to write output 'OhageyEngine.exe': permission denied` | **エンジンが動いたまま**。`tsf/Ohagey/tools/` のハーネスは実行後にエンジンを残す(アイドルタイムアウトで自分で終わる設計・決定 0015)ので、その直後にエンジンを再ビルドすると実行ファイルを上書きできない | `Get-Process OhageyEngine \| Stop-Process -Force` してから再ビルド |
| `error: unable to attach DB: … "build.db": database is locked` | 同じ `--scratch-path` に対して `swift build` が2つ走っている。Debug と Release を続けて回したときに前のプロセスが残っていると起きる | 前のビルドの終了を待つ。残っていれば `swift`/`swift-frontend` を止める |

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

`tools/fetch-backends.ps1` を使った場合の位置:

- `llama.lib`(リンク時)→ `backends\`
- `llama.dll`(実行時)→ `backends\cpu\` ※ `ggml*.dll` 等の依存 DLL も同じ場所

自分で cmake ビルドした場合は `build-b4846\src\Release\` と
`build-b4846\bin\Release\`(cmake 既定)。

tools-version を 6.x にすると既定の言語モードが Swift 6(strict concurrency)になり、
まだ一度も動かしていないコードに大量の Sendable エラーが出るため、当面は
`.swiftLanguageMode(.v5)` を指定している。**エンジンが動くようになったら `.v6` への
移行を検討すること**(`Package.swift` に TODO として記載)。

### 推奨する着手順(手戻りを減らす順序)

1. **`tools/fetch-backends.ps1` で llama.cpp を取得し、`swift build` を通す。**
   最大の未知数がここなので最初に潰す。この時点では変換の中身は動かなくてよい。
2. 型エラーを潰す。特に `ConvertRequestOptions` の引数を**ピン留めしている 0.8.0 系の
   実際のシグネチャ**に合わせる(必要なら `Package.resolved` で解決済みバージョンを確認)。
3. proto を生成して `RequestRouter` を実装する。
4. パイプの accept ループを実装し、簡単なクライアントから疎通確認する。

1 と 2 で `Package.swift` のピン留めバージョンを上げる判断が必要になる可能性がある。
その場合は決定ログに理由を記録すること。

詳細と未解決の設計課題は `docs/roadmap.md` の「フェーズ1」を参照。

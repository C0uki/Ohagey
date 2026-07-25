# ローカル開発環境の構築(Windows)

おはぎーは Windows x64 専用(決定 0018)。TSF・WinUI 3・インストーラーは
**Windows 実機でしかビルド・検証できない**。エンジン(Swift)も最終ターゲットは Windows。

## 必要なツール

| 対象 | ツール | 備考 |
|---|---|---|
| **最初に入れる** | **Visual Studio 2022(「C++ によるデスクトップ開発」ワークロード)** | **TSF ヘッダ(`msctf.h` 等)に加え、cmake と MSVC コンパイラが同梱される。llama.cpp のビルドにも必要**(決定 0002/0003) |
| `engine/` | [Swift for Windows](https://www.swift.org/install/windows/) | 6.0 系。`swift build` に使用 |
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

### 手順(CPU 版・最初の一歩)

**「x64 Native Tools Command Prompt for VS 2022」で実行すること**(上記参照)。

```bat
cd C:\src
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DBUILD_SHARED_LIBS=ON
cmake --build build --config Release
```

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

# ローカル開発環境の構築(Windows)

おはぎーは Windows x64 専用(決定 0018)。TSF・WinUI 3・インストーラーは
**Windows 実機でしかビルド・検証できない**。エンジン(Swift)も最終ターゲットは Windows。

## 必要なツール

| 対象 | ツール | 備考 |
|---|---|---|
| `engine/` | [Swift for Windows](https://www.swift.org/install/windows/) | 6.0 系。`swift build` に使用 |
| `engine/`(proto 生成) | `protoc` + `protoc-gen-swift` | 下記「Protobuf の生成」参照 |
| `tsf/` | Visual Studio 2022(C++ によるデスクトップ開発 + Windows SDK) | TSF ヘッダ(`msctf.h` 等)を含む |
| `settings-app/` | .NET SDK + Windows App SDK(WinUI 3) | 決定 0013 |
| `installer/` | [Inno Setup](https://jrsoftware.org/isinfo.php) | `iscc` でコンパイル |
| 共通 | Git | — |

Zenzai の GPU バックエンドを試す場合のみ追加で:
CUDA なら NVIDIA ドライバ + CUDA Toolkit、Vulkan なら Vulkan SDK(決定 0010)。
**まずは CPU で動かすので必須ではない。**

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
# エンジン
cd engine
swift build

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

詳細と未解決の設計課題は `docs/roadmap.md` の「フェーズ1」を参照。

# CLAUDE.md — Ohagey (おはぎー)

Windows向け日本語IME。azooKeyの変換エンジン(AzooKeyKanaKanjiConverter + Zenzai)を
流用し、TSF層・UI・配布まわりは新規実装。

**作業を始める前に必ず読むこと:**
- `docs/decisions/README.md` — 設計判断の全一覧(なぜそう決めたか)
- `docs/roadmap.md` — フェーズ別の進捗と残タスク、未解決の設計課題
- `docs/local-setup.md` — ビルド手順、**動作確認済みのバージョン組み合わせ**、
  実機で踏んだエラーと対処の記録

## アーキテクチャ概要

```
tsf/ (C++, 各アプリのプロセス内)  ──名前付きパイプ(Protobuf)──  engine/ (Swift, 単一の共有サーバープロセス)
     │                                                                  │
     │ SEHでクラッシュを握りつぶす                          AzooKeyKanaKanjiConverter + Zenzai
     │ DirectWrite/DirectCompositionでFluent Design描画        バックエンドはDLL差し替えで選択
     │                                                          オンデマンド起動・アイドルタイムアウト終了
     ▼
%LOCALAPPDATA%\Ohagey\ (学習データ・ユーザー辞書、ユーザーごと)

settings-app/ (WinUI 3) ──registry/設定ファイル(変更通知で自動反映)──→ tsf/ と engine/
```

## 絶対に守ること

- **完全オフライン動作**。インストール時のモデルダウンロード以外、一切の外部通信をしない(decision 0016)
- **TSF DLL側は必ずSEHで例外を握りつぶす**。ホストアプリ(メモ帳、Chrome等)をクラッシュさせない(decision 0017)
- **x64のみ**対応。ARM64は範囲外(decision 0018)
- **Zenzaiモデル(CC-BY-SA 4.0)はリポジトリにコミットしない**。実行時ダウンロードのみ(decision 0008/0009)
- 名前付きパイプは**セッションID込みの命名**、**AppContainer/管理者権限プロセスからの接続を許可するACL**を必ず設定する(decision 0006)

## バージョンの固定(重要)

**AzooKeyKanaKanjiConverter 0.8.5 ↔ llama.cpp `b4846` は独立に更新できない。**
片方だけ上げるとリンクエラーになる(decision 0028)。pin を変更するときは必ず両方を
確認し、理由を決定ログに記録すること。

また、upstream の `main` と 0.8.5 は API が異なる。README や `main` のソースを参考に
すると食い違うので、**必ず `.build/checkouts/` の実物か 0.8.5 のタグを見ること**。
差分表は `docs/local-setup.md` にある。

## ディレクトリと役割

| パス | 言語/技術 | 役割 |
|---|---|---|
| `engine/Sources/OhageyEngineCore/` | Swift | **移植可能でテスト可能な中核**。framing・設定・リクエストモデル・ルーティング。Windows/Protobuf/変換器に依存しない |
| `engine/Sources/OhageyEngine/` | Swift | 実行可能ターゲット。パイプサーバー(WinSDK)、変換器ラッパー(C++ interop) |
| `engine/Sources/OhageyEngineProto/` | Swift | `ohagey.proto` と、そこから生成する型 |
| `engine/Tests/` | Swift (XCTest) | `OhageyEngineCore` の単体テスト |
| `tsf/` | C++ (MSBuild) | TSF実装(SampleIMEをvendoring・改造)、候補ウィンドウ描画 |
| `settings-app/` | WinUI 3 (.NET) | バックエンド切替、学習データ管理、ユーザー辞書UI |
| `installer/` | Inno Setup | インストーラー、モデルダウンロード呼び出し |
| `docs/decisions/` | Markdown | 設計判断ログ |

## 現在のステータス

**フェーズ1(エンジン)が進行中。** `tsf/` `settings-app/` はまだ雛形のみ。

### 実機で検証済み
- Windows で `swift build` が通り `OhageyEngine.exe` が生成される
- `swift test` **49件パス**(framing 12・ルーティング 5・wire マッピング 23・アイドル 9)
- **実クライアントとの往復**: 名前付きパイプ経由で `Ping` / `Convert` が動作。
  `へんかん` → 変換/返還/… を返す(辞書の実ロードと変換を確認)
- 不正リクエストは同じ `request_id` で `INVALID_ARGUMENT` を返し、**接続は維持される**
- アイドルタイムアウト自己終了(decision 0015)— 5秒設定で実測

### コンパイルは通るが未検証
- 複数クライアントの同時接続(1接続ずつしか試していない)
- Zenzai 経路(モデル未インストールのため辞書変換にフォールバックした状態でのみ検証)

### 未着手
- 設定のホットリロード(decision 0014)
- ユーザー辞書の保存(decision 0026)— `registerWord` は現在エラーを返す
- バックエンド選択の DLL 検索パス切り替え(decision 0028)
- `tsf/` の SampleIME vendoring(手順は `tsf/README.md`)

## ビルドとテスト

「x64 Native Tools Command Prompt for VS 2022」で、以下を設定してから実行する:

```bat
set LIB=<llama.cpp>\build-b4846\src\Release;%LIB%
set PATH=<llama.cpp>\build-b4846\bin\Release;%PATH%

cd engine
swift build
swift test
```

`LIB` はリンク時(`llama.lib`)、`PATH` は実行時(`llama.dll`)。**どちらか一方では足りない。**
詳細は `docs/local-setup.md`。

## 未解決の課題(着手前に確認)

- **パイプ ACL(SDDL)のセキュリティレビューが未実施。** IME は全入力が通るため、
  出荷前に最小権限へ絞ること(`PipeServer.securityDescriptorSDDL`)
- **Swift 6 言語モードへの移行が保留中。** 現在 `.v5` を明示している(`Package.swift` の TODO)
- ユーザー辞書のファイルフォーマット(decision 0026)、設定のレジストリスキーマ(decision 0014)が未確定

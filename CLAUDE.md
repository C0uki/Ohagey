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

settings-app/ (WinUI 3) ──HKCU\Software\Ohagey(変更通知で自動反映)──→ engine/
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

**AzooKeyKanaKanjiConverter は fork をリビジョン固定している**(decision 0034)。
upstream は Windows で個人化(`EfficientNGram`)を除外しているため。
fork 点は 0.8.5 タグそのもので、`Package.swift` の2箇所以外に差分はない
(Windows 除外の解除、`EfficientNGram` の product 公開)。SwiftyMarisa 側の
fork には実バグ修正が2件入っている。**上の b4846 との一体制約はそのまま。**

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
- `swift test` **156件パス**
- **実クライアントとの往復**: 名前付きパイプ経由で `Ping` / `Convert` が動作。
  `へんかん` → 変換/返還/… を返す(辞書の実ロードと変換を確認)
- **6クライアント同時接続** — 全員が自分の `request_id` で正しく応答を受け取る
- 不正リクエストは同じ `request_id` で `INVALID_ARGUMENT` を返し、**接続は維持される**
- アイドルタイムアウト自己終了(decision 0015)— 5秒設定で実測
- 設定のホットリロード(decision 0014 / 0035)— HKCU から読み込み、即時反映、
  再起動が要る項目の通知、新規プロファイルでのキー作成まで確認
- パイプ ACL を稼働中のパイプから読み戻して設計と一致を確認(decision 0031)

- **Zenzai の実変換**(decision 0008)。モデル配置後に文レベルの変換を確認
  (`きょうはいいてんきですね` → 今日はいい天気ですね)。
  release/CPU で **p50 ≈ 70〜95ms、p95 ≈ 90〜140ms**。
  計測方法の落とし穴は `docs/local-setup.md` に記録した(素朴に測るとキャッシュを測ってしまう)

- **Zenzai 有効時の順位に学習が効く**(decision 0034)。`きしゃのきしゃ` で
  5位の候補を 40 回確定 → **1位に上がり、残り4件の相対順序は保たれる**。
  `tsf/Ohagey/tools/build-and-run-personalization.ps1`

### 未検証
- UWP / AppContainer アプリからの実接続(decision 0031 の `AC` 許可)

- **ユーザー辞書**(decision 0026 / 0036)。`registerWord` で登録した語が
  Zenzai 有効のまま**1位に出る**。`tsf/Ohagey/tools/build-and-run-userdict.ps1`

- **バックエンド選択**(decision 0028)。`backends\<name>\` の DLL 検索パス切り替えと、
  `tools/fetch-backends.ps1` による `azooKey/llama.cpp` のプレビルド取得。
- **読み込めないバックエンドからの CPU フォールバック**(decision 0028)。
  `tsf/Ohagey/tools/check-backend-fallback.ps1` で3ケース確認
  (正常 / ディレクトリ無し / `llama.dll` はあるが依存が無い→126)。
  フォールバック後もそのまま Zenzai が変換できる。状態は
  `%LOCALAPPDATA%\Ohagey\backend-status.tsv` に記録し、設定アプリが表示する

### 未着手
- CUDA / Vulkan バックエンドの実機動作(プレビルドの取得までは確認済み)

## ビルドとテスト

まず llama.cpp を取ってくる(**ビルドしない**。`azooKey/llama.cpp` が b4846 の
Windows バイナリをバックエンド別に公開している):

```powershell
.\tools\fetch-backends.ps1
```

その上で「x64 Native Tools Command Prompt for VS 2022」から:

```bat
set LIB=<repo>\backends;%LIB%
set PATH=<repo>\backends\cpu;%PATH%

cd engine
swift build
swift test
```

`LIB` はリンク時(`llama.lib`)、`PATH` は実行時(`llama.dll`)。**どちらか一方では足りない。**
詳細は `docs/local-setup.md`。

**取得元を `ggml-org/llama.cpp` に変えてはいけない。** 同じ `b4846` タグでも zenz の
日本語 pre-tokenizer が無く、**リンクも起動も変換も通ったまま Zenzai だけが黙って
無効になる**(決定 0034 で実際に踏んだ)。

## 未解決の課題(着手前に確認)

- ~~パイプ ACL(SDDL)のセキュリティレビュー~~ → **完了(decision 0031)**。
  ただし**フェーズ2の TSF クライアントには制約がある**: `CreateFileW` を
  `GENERIC_READ | GENERIC_WRITE` で呼ぶと AppContainer から接続できない。
  `FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE`
  を明示すること
- **Swift 6 言語モードへの移行が保留中。** 現在 `.v5` を明示している(`Package.swift` の TODO)
- ユーザー辞書のファイルフォーマット(decision 0026)は **decision 0036**、設定のレジストリスキーマ(decision 0014)は **decision 0035** で確定済み

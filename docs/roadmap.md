# 実装ロードマップ

このドキュメントは、確定済みのアーキテクチャ決定(`docs/decisions/README.md`)を、
実際に着手できる順序に並べ替えた作業計画です。決定ログが「何を・なぜ」を記録するのに対し、
こちらは「いつ・どの順で」を扱います。

## 現状(2026-07)

雛形段階。アーキテクチャは決定0001〜0027で確定済み。動く実装コードはまだ無い。

| コンポーネント | 状態 |
|---|---|
| `engine/` (Swift) | `Package.swift` + `main.swift`(TODOのみ)+ `ohagey.proto`(本フェーズで追加) |
| `tsf/` (C++) | READMEのみ。SampleIME未取り込み |
| `settings-app/` (WinUI 3) | READMEのみ |
| `installer/` (Inno Setup) | `ohagey.iss` 雛形 |

> **実行環境の前提**: 本プロジェクトは Windows 専用(TSF C++ / WinUI 3 / Swift-on-Windows)。
> TSF の実登録・候補ウィンドウ描画・WinUI・インストーラ実行確認は Windows 実機が必須。
> `.proto` 定義・CI YAML・ドキュメント・Swift ソースの一部は OS 非依存で先行できる。

## フェーズ0 — 基盤整備 ✅(本ブランチ)

OS 非依存で完結し、後続実装の土台になるもの。

- [x] `.gitignore` — モデル重み(`*.gguf` 等)・各言語のビルド成果物を除外。決定 0008/0009/0016 の機械的担保。
- [x] `.github/workflows/ci.yml` — CI 雛形。現時点ではモデル誤コミットを弾く `no-committed-model` ジョブのみ稼働。Windows 実ビルドジョブは定義だけ用意し、コンポーネント実装後に有効化。
- [x] `engine/Sources/OhageyEngineProto/ohagey.proto` — IPC スキーマ初版(決定 0007)。
- [x] `docs/roadmap.md` — 本ドキュメント。

## フェーズ1 — エンジン骨格(Swift / OS 非依存部分を先行)

- [ ] `ohagey.proto` から Swift 型を生成(`protoc` + `swift-protobuf`)。`Package.swift` の `swift-protobuf` 依存を有効化。
- [ ] 長さプレフィックス framing のエンコード/デコード実装。
- [ ] `main.swift`: 名前付きパイプサーバーの骨格(決定 0006 の ACL 込み命名。Windows API 依存部分は当面スタブ + 設計コメント)。
- [ ] `ConvertRequestOptions` のロード: `memoryDirectoryURL` → `%LOCALAPPDATA%\Ohagey\`(決定 0024)、`learningType`(決定 0025)、`zenzaiMode` のモデル有無による分岐(決定 0008)。
- [ ] アイドルタイムアウト自己終了(決定 0015)。
- [ ] `swift build` を CI(windows-latest)で有効化。

## フェーズ2 — TSF(C++ / Windows 実機必須)

- [ ] `tsf/README.md` の手順で SampleIME を vendoring(決定 0002/0021)。
- [ ] `CompositionProcessorEngine`/辞書検索 → 名前付きパイプクライアント(Protobuf)に置換(決定 0004〜0007)。
- [ ] 候補ウィンドウを GDI から DirectWrite/DirectComposition + Fluent Design に書き換え(決定 0011/0012)。
- [ ] 全エントリポイントを SEH で防御(決定 0017)、x64 専用ビルドに整理(決定 0018)。
- [ ] MSBuild + `swift build` 連携ターゲット(決定 0020)、CI で MSBuild 有効化。

## フェーズ3 — 設定アプリ / インストーラ

- [ ] `settings-app/`: WinUI 3 プロジェクト生成(決定 0013)。バックエンド選択(0010)/学習データ管理(0025)/ユーザー辞書(0026)/About(帰属表示 0009)。
- [ ] レジストリ/設定ファイルスキーマ確定 + 変更通知連携(決定 0014)。
- [ ] `installer/ohagey.iss`: `[Files]`/`[Run]` 実装、モデルダウンロードステップ(失敗してもインストール続行、決定 0008)、CI で `iscc` パッケージング有効化。

## 実装時に確定する残課題(決定ログより)

- ユーザー辞書ファイルの具体フォーマット(JSON 等、決定 0026)。
- 設定用レジストリスキーマの詳細(決定 0014)。
- `ohagey.proto` の各メッセージ詳細の最終確定(本初版からの調整)。

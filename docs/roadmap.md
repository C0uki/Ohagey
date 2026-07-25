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

## フェーズ1 — エンジン骨格(Swift)

> ⚠️ **未コンパイル**: このフェーズのコードは Swift ツールチェーンの無い環境で書かれている。
> `download.swift.org` が egress ポリシーで遮断されており導入できなかったため、
> **一行もビルド検証されていない**。ローカル Windows(`docs/local-setup.md`)での
> 最初のビルドで型エラーが出る前提で扱うこと。

- [x] 長さプレフィックス framing の実装(`Framing.swift`)— Windows/Protobuf 非依存で単体テスト可能。
- [x] パイプ命名(セッションID 込み)と ACL(SDDL)の定義、`CreateNamedPipeW` 呼び出し(`PipeServer.swift`)。**ACL はセキュリティレビュー未実施**。
- [x] 設定とパスの解決(`EngineSettings.swift`)— `%LOCALAPPDATA%\Ohagey\`(決定 0024)、モデルパス(決定 0008)、学習既定 ON(決定 0025)。
- [x] 変換ラッパー骨格(`ConversionService.swift`)— `ConvertRequestOptions` / `ZenzaiMode` の配線、モデル非在時の `.off` フォールバック。
- [x] Protobuf 生成の配線: `Scripts/generate-proto.sh` + `Package.swift` の `swift-protobuf` 依存有効化。
- [ ] **`Scripts/generate-proto.sh` の実行**(protoc-gen-swift が必要 → Swift 環境必須)。生成物 `ohagey.pb.swift` はコミットする方針。
- [ ] `RequestRouter`: `Request` デコード → 振り分け → `Response` エンコード(`request_id` を保持)。
- [ ] accept ループ / コネクション毎の読み取りループ(`PipeServer.swift` の TODO)。
- [ ] アイドルタイムアウト自己終了(決定 0015)。
- [ ] 設定のホットリロード(決定 0014)。
- [ ] `swift build` を通す → CI(windows-latest)で有効化。

### フェーズ1 で判明した未解決の設計課題

1. **決定 0010(CPU/CUDA/Vulkan のユーザー選択)と upstream の実装方式が食い違う。**
   AzooKeyKanaKanjiConverter はバックエンドを **package trait**(`"Zenzai"` = GPU /
   `"ZenzaiCPU"` = CPU 専用)で選ぶ。これは**ビルド時**の選択であり、設定アプリからの
   **実行時**切り替えという決定 0010 の前提が成り立たない。要再検討(別バイナリ同梱、
   upstream への機能追加、決定 0010 の見直し等)。
2. **依存バージョンの乖離**: 本フェーズのコードは upstream `main` の API を参照して
   書かれているが、`Package.swift` は `0.8.0` 系にピン留めしている。pre-1.0 で API が
   動くため、`ConvertRequestOptions` の必須引数(`textReplacer`、
   `specialCandidateProviders` 等)は実ビルド時に要確認。
3. **パイプ ACL のセキュリティレビュー**: `PipeServer.securityDescriptorSDDL` は
   AppContainer / 低整合性クライアントを通す必要から広めの許可になっている。
   IME のパイプは全入力が通るため、出荷前に Mozc 等と比較して最小権限に絞ること。

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

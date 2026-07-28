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

> ✅ **Windows でビルドが通ることを実機で確認済み**(`Build complete!` / `OhageyEngine.exe` 生成)。
> upstream が Windows を動作確認対象に挙げていない中で、
> AzooKeyKanaKanjiConverter + Zenzai + llama.cpp が Windows でビルドできることを実証した。
> **フェーズ1で最大の未知数だった部分は解消**。
> 到達までに踏んだエラーと対処は [`local-setup.md`](local-setup.md) に記録している。
>
> ただし**動作確認はこれから**。ビルドが通ったことと、変換が正しく動くことは別。

- [x] 長さプレフィックス framing の実装(`Framing.swift`)— Windows/Protobuf 非依存。
- [x] `OhageyEngineCore` ライブラリへの分離と単体テスト追加(`swift test`)。
      SwiftPM は実行可能ターゲットに対するテストを安定して扱えないため、移植可能な部分
      (framing・設定・ルーティング)をライブラリターゲットに切り出した。C++ interop を
      持たないのでテストのビルドは軽く、llama.cpp のリンクも不要。
      **実機で全テストパスを確認済み**(framing 12件)。
- [x] パイプ命名(セッションID 込み)と ACL(SDDL)の定義、`CreateNamedPipeW` 呼び出し(`PipeServer.swift`)。
      **ACL はセキュリティレビュー完了**(決定 0031)。`PipeSecurity.swift` に切り出してテスト済み 12 件。
- [x] 設定とパスの解決(`EngineSettings.swift`)— `%LOCALAPPDATA%\Ohagey\`(決定 0024)、モデルパス(決定 0008)、学習既定 ON(決定 0025)。
- [x] 変換ラッパー骨格(`ConversionService.swift`)— `ConvertRequestOptions` / `ZenzaiMode` の配線、モデル非在時の `.off` フォールバック。
- [x] Protobuf 生成の配線: `Scripts/generate-proto.sh` + `Package.swift` の `swift-protobuf` 依存有効化。
- [x] **Windows で `swift build` を通す**(最大の関門)。llama.cpp `b4846` を CPU 構成でビルドし、
      `-Xlinker -L<llama.lib のディレクトリ>` を渡すことで `OhageyEngine.exe` の生成に成功。
- [x] 生成された `OhageyEngine.exe` を実行し、起動シーケンスが想定どおり動くことを確認。
      **実行時に検証できたこと**:
      - `ProcessIdToSessionId` が動作しセッションID からパイプ名を導出できた
        (`\\.\pipe\ohagey_session_1`)— WinSDK 呼び出しのうち最初の1つが実証された(決定 0006)
      - モデル非在時に辞書変換へフォールバックする判定が正しく効いた(決定 0008)
      - `settings.json` 不在でも既定値で継続(決定 0025)
- [x] エンジン側のリクエスト/レスポンスモデル(`EngineProtocol.swift`)と
      `RequestRouter` を実装。**proto 生成を待たずに書ける部分**として、生成型ではなく
      素の Swift 型で定義した。理由は2つ:
      ルーティングを protoc 抜きでテストできること、
      生成型は wire 形状(optional だらけ、oneof が不在になり得る)なので、
      端で一度変換すれば以降は不正な状態を取り得ない値を扱えること。
      **テスト済み**(request_id の保持、ハンドラの例外を `failure` に畳んで接続を維持)。
- [x] **`Scripts/generate-proto.sh` の実行**。`protoc` 35.1 + `protoc-gen-swift`
      (swift-protobuf 1.38.1 を `swift build -c release --product protoc-gen-swift`
      でビルド)。生成物 `ohagey.pb.swift` はコミット済み。
- [x] proto ↔ `EngineRequest`/`EngineResponse` のマッピング層(`WireMapping.swift`)。
      **当初の想定と置き場所を変えた**: `OhageyEngine`(実行可能ターゲット)ではなく
      `OhageyEngineProto` に置いた。SwiftPM は実行可能ターゲットにテストを持てず、
      マッピング層こそ(oneof 不在・sentinel 値・敵対的な入力で)テストが要る場所だから。
      **テスト済み 23 件。**
- [x] `ConversionService` を `EngineRequestHandling` に適合させる。
      `registerWord` は決定 0026 未確定のため `internalError` を返す(保存できていないのに
      成功を返さない)。
- [x] accept ループ / コネクション毎の読み取りループ(`PipeServer.swift` / `PipeConnection.swift`)。
- [x] アイドルタイムアウト自己終了(`IdleWatchdog.swift`、決定 0015)。**テスト済み 9 件**
      (スケジューラを注入して実時間を待たずに検証)。
- [ ] 設定のホットリロード(決定 0014)。
- [x] `swift build` を通す。
- [ ] CI(windows-latest)で有効化。

#### 実機で検証済み(実クライアントを繋いでの往復)

PowerShell の名前付きパイプクライアントから実際にフレームを流し、以下を確認した。

| 検証項目 | 結果 |
|---|---|
| `Ping` 往復 | `request_id` 保持、`status=OK`、`engine_version="0.0.1"`、`backend=CPU` |
| `Convert("へんかん")` | 変換 / 返還 / 編間 … を返す。**辞書の実ロードと変換が動く** |
| `n_best` の遵守 | 当初 5 を要求して約60件返る不具合を発見 → `ConversionService` 側で切り詰めて修正 |
| 不正リクエスト(oneof 未設定) | `INVALID_ARGUMENT` + メッセージを**同じ request_id で**返し、**接続は維持**。 |
| 同一接続での後続リクエスト | エラーの直後の `Ping` に正常応答(合成中のアプリが IME を失わない) |
| 切断後の再接続 | accept ループが新しいインスタンスを作り直して受け付ける |
| アイドルタイムアウト | `idleTimeoutSeconds=5` で起動 → 5秒後に exit code 0 で自己終了 |

> **起動直後のログに出る `charID.chid` / `mm.binary` が無いというエラーは無害。**
> upstream が既定パスで `DicdataStore` を先行初期化するために出るもので、実際の
> 変換リクエストではバンドル内の正しい辞書が使われる(そちらでは `user` /
> `memory` の LOUDS 不在しか報告されず、これは学習データ未作成なので正常)。

### フェーズ1 で判明した未解決の設計課題

1. ~~**決定 0010 と upstream の実装方式が食い違う。**~~ → **決定 0028 で解決済み。**
   調査の結果、`ZenzaiMode` にバックエンド設定フィールドは無く、Windows では
   `llama.cpp` が `.systemLibrary`(= DLL はこちらが用意する)だった。
   バックエンド別の llama.cpp DLL を同梱し、エンジン起動時に DLL 検索パスで選択する
   方式に確定(切り替えはエンジン再起動を伴う)。詳細は
   [`decisions/0028-inference-backend-selection.md`](decisions/0028-inference-backend-selection.md)。
   なお当初「package trait がバックエンドを選ぶ」と記録していたが**これは誤り**で、
   `Zenzai` / `ZenzaiCPU` の2 trait は Package.swift 上で同一の扱いだった。
2. **依存バージョンの乖離**: 本フェーズのコードは upstream `main` の API を参照して
   書かれているが、`Package.swift` は `0.8.0` 系にピン留めしている。pre-1.0 で API が
   動くため、`ConvertRequestOptions` の必須引数(`textReplacer`、
   `specialCandidateProviders` 等)は実ビルド時に要確認。
3. ~~**パイプ ACL のセキュリティレビュー**~~ → **決定 0031 で解決済み。**
   `WD`(Everyone)を現在のユーザー SID + `SY` + `BA` + `AC` に置換し、`GRGW` を
   明示的な `FILE_*` 権限に、`PIPE_REJECT_REMOTE_CLIENTS` と(初回のみ)
   `FILE_FLAG_FIRST_PIPE_INSTANCE` を追加した。
   **同一ユーザーのプロセス間は DACL で区別できない**ため境界にできない点も明記してある。
   詳細は [`decisions/0031-pipe-acl.md`](decisions/0031-pipe-acl.md)。

## フェーズ2 — TSF(C++ / Windows 実機必須)

- [ ] `tsf/README.md` の手順で SampleIME を vendoring(決定 0002/0021)。
- [ ] `CompositionProcessorEngine`/辞書検索 → 名前付きパイプクライアント(Protobuf)に置換(決定 0004〜0007)。
- [ ] 候補ウィンドウを GDI から DirectWrite/DirectComposition + Fluent Design に書き換え(決定 0011/0012)。
- [ ] 全エントリポイントを SEH で防御(決定 0017)、x64 専用ビルドに整理(決定 0018)。
- [ ] MSBuild + `swift build` 連携ターゲット(決定 0020)、CI で MSBuild 有効化。

## フェーズ3 — 設定アプリ / インストーラ

- [ ] `settings-app/`: WinUI 3 プロジェクト生成(決定 0013)。バックエンド選択(0010/0028、**変更時はエンジン再起動が要る旨を UI に明示**)/学習データ管理(0025)/ユーザー辞書(0026)/About(帰属表示 0009)。
- [ ] レジストリ/設定ファイルスキーマ確定 + 変更通知連携(決定 0014)。
- [ ] `installer/ohagey.iss`: `[Files]`/`[Run]` 実装、モデルダウンロードステップ(失敗してもインストール続行、決定 0008)、`backends\{cpu,cuda,vulkan}\` の同梱(決定 0028)、CI で `iscc` パッケージング有効化。

### llama.cpp の用意(決定 0028、フェーズ2〜3 と並行)

Windows では upstream が `llama.cpp` を `.systemLibrary` として宣言しているため、
**おはぎー側で llama.cpp をビルドして用意する必要がある**。エンジンのビルドを通す
前提条件でもあるので、フェーズ1の `swift build` 到達時に必要になる。

- [ ] llama.cpp を CPU / CUDA / Vulkan の各構成でビルド(バージョン・ビルドフラグを記録)。
      手順は [`local-setup.md`](local-setup.md) の「llama.cpp の用意」を参照。
      **まず CPU 版だけ用意して `swift build` を通すのが最短経路。**
- [x] ~~`systemLibrary` 用の module map とヘッダ配置を用意~~ → **upstream が同梱済み**
      (`Sources/llama.cpp/module.modulemap` + 各ヘッダ)。`link "llama"` 指定があるため、
      こちらが用意するのは `llama.lib` / `llama.dll` と、リンカへの `-Xlinker -L` 指定のみ。
- [ ] エンジン起動時の DLL 検索パス切り替え(`SetDllDirectory` / 遅延ロード)を実装。
- [ ] 選択したバックエンドの初期化失敗時に CPU へフォールバックし、状態を設定アプリに表示。

## 実装時に確定する残課題(決定ログより)

- ユーザー辞書ファイルの具体フォーマット(JSON 等、決定 0026)。
- 設定用レジストリスキーマの詳細(決定 0014)。
- `ohagey.proto` の各メッセージ詳細の最終確定(本初版からの調整)。

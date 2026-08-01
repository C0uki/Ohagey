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
| `settings-app/` (WinUI 3) | ロジック(テスト77件)+ 4画面。実機で起動確認済み |
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
      - 設定が無くても既定値で継続(決定 0025)
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
      `registerWord` は**実装済み**(決定 0036)。読みがかなでないときは
      `INVALID_ARGUMENT` を返して接続は維持する。
- [x] accept ループ / コネクション毎の読み取りループ(`PipeServer.swift` / `PipeConnection.swift`)。
- [x] アイドルタイムアウト自己終了(`IdleWatchdog.swift`、決定 0015)。**テスト済み 9 件**
      (スケジューラを注入して実時間を待たずに検証)。
- [x] 設定のホットリロード(`SettingsWatcher.swift`、決定 0014 / **0035**)。
      **当初は `settings.json` + `ReadDirectoryChangesW` で実装し実機検証まで済ませたが、
      決定 0035 で HKCU のレジストリに変更した**(Windows の IME としての慣例と、
      将来の GPO 配備の余地)。現在は `RegNotifyChangeKeyValue` でキーを監視する。
      **実装中に既存のバグを1つ見つけて直した**: Swift の合成 `Codable` はプロパティの
      既定値を使わずキー欠落で throw するため、部分的な設定は全体が復号失敗し、
      `load()` が**全設定を既定値に戻していた**(= 学習が勝手に ON に戻る、決定 0025 違反)。
      この「壊れた値はその項目だけ倒す」規則は決定 0035 に引き継いである。
- [x] `swift build` を通す。
- [x] CI(windows-latest)で有効化。llama.cpp `b4846` を `azooKey/llama.cpp` の
      リリースから取得し、`swift build` + `swift test` を回す。`swift test` は
      パッケージ全体をビルドするため、ライブラリのテストだけを llama.cpp 抜きで
      回すことはできない。

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
| **6クライアント同時接続** | 全接続を同時に開いたまま各々が変換+Ping。**6/6 が自分の `request_id` で正しく応答を受け取った** |
| アイドルタイムアウト | `idleTimeoutSeconds=5` で起動 → 5秒後に exit code 0 で自己終了 |
| **設定のホットリロード** | HKCU から起動時に読み込み、`LearningEnabled` の変更を即時反映、同内容の再書き込みは無反応、`Backend` 変更は「再起動が必要」と通知。**新規プロファイル**ではキーを空のまま作り、設定アプリの初回書き込みを検知(決定 0035) |
| **パイプ ACL の読み戻し** | 稼働中のパイプから実際の DACL を取得し設計と一致を確認。`WD` 無し、ユーザーのみ `0x12019f`、SY/BA/AC は `0x100183`、Owner も正しい |
| **Zenzai のリンク** | `dumpbin /dependents` で `llama.dll` 依存を確認 — Zenzai は実際にリンクされている(mock ではない) |
| **Zenzai の実変換** | モデル配置後、`model_loaded=true`。**文レベルの変換が動く**(`きょうはいいてんきですね` → 今日はいい天気ですね、`ひこうきのじかんにまにあった` → 飛行機の時間に間に合った)。辞書のみでは出ない品質 |
| **Zenzai のレイテンシ** | release / CPU で **p50 ≈ 70〜95ms、p95 ≈ 90〜140ms**(下記の注意書きを参照) |

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

### 学習と Zenzai の関係 → **解決済み(決定 0034)**

確定時の `Commit` を配線し、エンジン側で `updateLearningData` を呼ぶようにした
(決定 0024 / 0025)。**辞書変換では学習が効く**ことを実測で確認している —
2位の候補を確定すると次の変換で1位に上がる。

**しかし Zenzai を有効にすると順位は変わらなかった。** Zenzai が神経モデルで
並べ替えるため、学習ストアはその下の格子にしか効かない。

これを [`decisions/0034-zenzai-personalization.md`](decisions/0034-zenzai-personalization.md)
で解決した。`ZenzaiMode.PersonalizationMode` に、確定テキストから学習した
n-gram を渡している。**実測**(`build-and-run-personalization.ps1`):

```
before: 記者の記者 / 汽車の記者 / き者の記者 / 貴社の記者 / 機者の記者
after:  機者の記者 / 記者の記者 / 汽車の記者 / き者の記者 / 貴社の記者
```

「機者の記者」を 40 回確定 → **5位から1位**。残り4件の相対順序は保たれている。

ブロッカーは2つあり、どちらも upstream 依存側のバグだった:

1. **upstream は Windows で個人化を丸ごと除外していた。** 原因とされる
   「SwiftyMarisa が Windows で使えない」の実体は、ヘッダの
   `typedef unsigned long size_t;` **1行**(LLP64 で再定義エラー)
2. **`[Int8]` のキーと検索語を `strlen` で測っていた。** 終端 NUL のない
   Swift 配列なので配列外を読み、同じ trie から実行ごとに違う確率が返っていた
   (0.49297 → 0.125125)。Windows 固有ではなく、単に露見しにくいだけの未定義動作

両方を直した fork をリビジョン固定している。azooKey 側は `Package.swift` の
2箇所のみでソース無改変、fork 点は 0.8.5 タグなので**決定 0028 の
「0.8.5 ↔ llama.cpp b4846 は一体」制約はそのまま維持される。**

- [ ] fork の変更を upstream に PR するかの判断(今は出していない)。
- [x] コールドスタート時に最初の変換が空で返る問題(決定 0033 の範囲)。
      **当初「数秒 IME が死ぬ」と書いたが、実測の結果それは誤りだった。**
      パイプが立つまでは release / debug とも **0.1〜0.4秒**で、失われるのは
      **最初の1変換だけ**、次の打鍵で復帰する — `Connect` が起動後 250ms で
      諦める設計どおりの挙動(打鍵スレッドを止めないことを優先)。
      それでもタダで消せるので、テキストサービスの有効化時にエンジンを起動する
      `EngineClient::Warmup` を追加した。**15ms で戻り、接続は持たない**
      (接続を持つとアイドルタイムアウトが効かなくなる)。
      `build-and-run-launch.ps1` が cold / warm 両方を実測する。

### 決定 0034 の再検証 → 解決(改訂あり)

決定 0034 は「学習ストアは Zenzai の順位に届かない」という観測の上に立っている。
その観測は**確認できない状態で行われていた**ことが分かり、測り直した。

原因は2つ重なっていた。どちらも壊れていることが見えない。

1. **`ggml-org/llama.cpp` では zenz モデルを読めない**(日本語 char pre-tokenizer が
   `azooKey/llama.cpp` の fork にしか無い)。読めなくても辞書変換に落ちるので候補は返る
2. **`zenzai_used` はモデルファイルの存在しか見ていなかった**

両方修正のうえ、fork をビルドして Zenzai を本当に動かして測った結果:

| | 3回確定 | 40回確定 |
|---|---|---|
| 学習ストアのみ | 2位 → 2位 | **2位 → 2位** |
| + 個人化(空 base、α=0.15) | 2位 → 2位 | **2位 → 2位** |
| + 個人化(**本物の base**、α=1.0) | 2位 → 2位 | **2位 → 1位** |

- **決定 0034 の前提は正しかった**
- **空 base では個人化も動かない** → 決定 0034 の該当部分を撤回し、base LM を
  インストール時取得にした(`Miwa-Keita/base_n5_lm`、42.6 MB、ライセンス未記載のため同梱はしない)
- **alpha を 0.15 → 1.0**(azooKey-Desktop の既定に合わせる。上限 1.5)

`tsf/Ohagey/tools/build-and-run-learning.ps1` で再現できる。

残る限界(実測):

- [x] **3回の確定では動かない** → **しきい値をコーパス長に比例させて解決。**
      まず訓練コストを実測した(`tsf/Ohagey/tools/build-and-run-training-cost.ps1`、release):

      | 行数 | 時間 | 行数 | 時間 |
      |---|---|---|---|
      | 100 | 66ms | 2,500 | 747ms |
      | 500 | 179ms | 5,000 | 1,317ms |
      | 1,000 | 327ms | 10,000 | 2,652ms |

      数百行から先は線形で約 265µs/行。訓練は毎回コーパス全体を読むので、
      **固定しきい値だと1コミットあたりの CPU が青天井に増える** —
      20 コミットなら新規プロファイルで 3ms/コミット、満杯で 133ms/コミット。
      しきい値をコーパスに比例させるとこれが一定になる。
      `commitsPerTrainingRun(corpusLines:)` = `clamp(lines / 50, 3, 20)`。
      **150行までは3**、1,000行以上は従来どおり20(長く使っている人は従来から悪化しない)。
      新規プロファイルで**3コミット → `generation 1 published (3 lines, 48ms)`** を実測
- [ ] **40回確定すると他の候補も入れ替わる**(元の4件のうち残ったのは1件)

#### ⚠️ 決定 0034 の順位変化が現在**再現しない**

上のしきい値の作業中に判明した。`build-and-run-personalization.ps1` が
**2件とも FAIL する**。記録されているベースラインとは候補一覧そのものが違う:

```
記録: 記者の記者 / 汽車の記者 / き者の記者 / 貴社の記者 / 機者の記者
現在: 記者の記者 / キシャノキシャ / きしゃのきしゃ / きしゃ / 期しゃ
```

**しきい値の変更が原因ではない** — 変更前の `main` でも同じ結果になることを確認済み。
`ZenzaiInferenceLimit`(1/5/10/30 を試した)でも、空のユーザー辞書の
`importDynamicUserDict([])` でもない。

- [ ] **`mainResults` に部分長の候補が混ざる。** `きしゃ` / `期しゃ` は
      `きしゃのきしゃ` 全体の変換ではない。IME としては候補窓に断片が並ぶことになる
- [ ] **ハーネスの目標選択が不健全。** `candidates.last` を目標にしているので、
      部分長候補が入ると**断片を全文の読みに対して40回教え込む**ことになり、
      測っているものが変わる(実際 `記社之記社` という無意味な候補が1位に出た)。
      候補の実際の読みで絞るべきだが、`EngineCandidate.reading` には
      **要求した読みがそのまま入っている**(`ConversionService.convert`)ので
      現状は区別できない。ここも直す必要がある

### 先行実装から取り込むべきこと(azooKey-Windows / azooKey-Desktop)

- [x] **llama.cpp の自前ビルドをやめた。** `tools/fetch-backends.ps1` が
      **`azooKey/llama.cpp`** の `b4846` リリースからバックエンド別のプレビルドを
      取得する(avx / cuda-cu12.4 / vulkan)。リンクは `llama.lib` 一つでよい。
      azooKey-Windows は `fkunn1326/llama.cpp` から取っているが、この DLL は
      全アプリのプロセスに入るので**変換器と同じ組織のリリース**を選んだ。
      副産物として **CI が llama.cpp をビルドしなくなり**(cmake 10分超 → 17MB の
      ダウンロード)、キャッシュ共有のために `tsf` が `engine` を待つ必要も無くなった。
      さらに **CI がビルドしていたのは `ggml-org/llama.cpp`(pre-tokenizer の無い方)
      だった**のも同時に直っている。決定 0028 の追記を参照
  - [ ] **CUDA 版に CUDA ランタイムが同梱されているか未確認。** upstream は
        `cudart-llama-bin-win-*` を別アセットで出しているが、azooKey のリリースには
        無い。同梱されているのか、CUDA 導入済みの機械を前提にしているのかで、
        インストーラーが CUDA を提供できるかが決まる。**CUDA を配布物に入れる前に確定**
        (アセット自体は 183.7MB、URL は疎通確認済み)
- [ ] **バックエンド切り替えは launcher でもよい。** 向こうは launcher が PATH に
      バックエンドのディレクトリを足してからサーバーを起動している。
      Ohagey は遅延ロードで解決済みだが、単純さでは向こうが上
- [ ] **x86 の TSF DLL。** 向こうは 32bit アプリ向けに x86 版も作っている。
      決定 0018(x64 のみ)は、32bit アプリで IME が使えないことを意味する

## フェーズ2 — TSF(C++ / Windows 実機必須)

- [x] `tsf/README.md` の手順で SampleIME を vendoring(決定 0002/0021)。
      取り込み元コミットを記録。Pinyin 辞書 1.5MB は取り込んでいない。
- [x] x64 専用ビルドに整理(決定 0018)。**Debug/Release とも警告ゼロ**。
      変更は `.vcxproj` のみでソースは無改変。
- [x] IPC クライアントを C++ で実装(決定 0032)。Protobuf は
      `ohagey.proto` の範囲だけ手書き。**DLL の依存はシステム DLL のみ**。
- [x] `CompositionProcessorEngine`/辞書検索 → 名前付きパイプクライアントに置換
      (決定 0004〜0007)。
- [x] ローマ字 → かな変換(`RomajiKana`)。エンジンはひらがなの読みを期待するため。
- [x] 合成中の表示をかなにする。読み(エンジンへ)と表示(画面)は別物として分けた。
- [x] 確定時の学習フィードバック(`Commit`)の配線(決定 0024/0025)。
      **Zenzai 有効時の順位にも効く**(決定 0034)— 上記「学習と Zenzai の関係」参照。
- [x] エンジンのオンデマンド起動(決定 0015)。ブロッカーだったインストール配置を
      決定 0033 で確定させた。DLL 自身の隣の `OhageyEngine.exe` を起動する。
      **実機で確認**: エンジン停止状態から、最初の接続は即座に失敗して戻り、
      約1秒後の再試行で接続できる。
- [x] 候補ウィンドウを GDI から **DirectWrite + DirectComposition** に書き換え
      (決定 0011/0012)。`WS_EX_NOREDIRECTIONBITMAP` + コンポジションスワップチェイン。
      合成バッファを読み戻すハーネスで描画結果を確認済み。
      DComp が使えない環境向けに HDC 経路を残してある(判断はウィンドウ生成前)。
- [x] エントリポイントを SEH で防御(決定 0017)。ウィンドウプロシージャの
      ディスパッチャ(全ウィンドウを1箇所で)・DLL エクスポート4つ・
      キーイベントシンク6つ・その他の COM メソッド 90。
      **`AddRef` / `Release` の 24 は意図的に非防御** — 参照カウント転送で落ちる時点で
      `this` が壊れており、でっち上げたカウントは障害を別の場所の use-after-free に
      化けさせるため(`tsf/README.md` 参照)。
- [x] MSBuild + `swift build` 連携ターゲット(決定 0020)、CI で MSBuild 有効化。
      `tsf/Ohagey.Engine.targets`。llama.cpp をビルドしなくなったので、CI では
      engine ジョブと並列に走る(以前はキャッシュ共有のために待たせていた)。

> **TSF の実登録には管理者権限が必要**なため、メモ帳等で実際に打っての確認は未実施。
> 検証できているのはビルドと、`tsf/Ohagey/tools/` のハーネスによる
> ローマ字 → かな → エンジン → 候補の往復まで。

## フェーズ3 — 設定アプリ / インストーラ

- [x] `settings-app/`: ロジック(`Ohagey.Settings.Core` + テスト77件、CI 有効)。
      設定スキーマ(0035)と辞書フォーマット(0036)の C# 実装、学習データ消去(0025/0034)。
      **C# が書いた設定を Swift のエンジンが読むところまで実測済み。**
- [x] `settings-app/`: WinUI 3 の画面(決定 0013)。変換エンジン / 学習 /
      ユーザー辞書 / このソフトウェアについて の4画面。**実機で起動を確認済み**
      (モデルの実インストール状態まで表示される)。
      **`dotnet build` では建たない** — PRI 生成のタスクが VS 側にしかない。
      Restore と Build も分けて呼ぶ必要がある(`docs/local-setup.md`)。
      Windows App SDK は **1.7**。1.6 では `ScrollViewer` と `Slider` を置いた
      ページがヒープ破損で落ちた。バックエンド選択(0010/0028、**変更時はエンジン再起動が要る旨を UI に明示**)/学習データ管理(0025)/ユーザー辞書(0026)/About(帰属表示 0009)。
- [x] レジストリスキーマ確定 + 変更通知連携(決定 0014 → **0035**)。エンジン側は完了。
- [ ] `installer/ohagey.iss`: `[Files]`/`[Run]` 実装、モデルダウンロードステップ(失敗してもインストール続行、決定 0008)、`backends\{cpu,cuda,vulkan}\` の同梱(決定 0028)、CI で `iscc` パッケージング有効化。

### llama.cpp の用意(決定 0028、フェーズ2〜3 と並行)

Windows では upstream が `llama.cpp` を `.systemLibrary` として宣言しているため、
**おはぎー側で llama.cpp をビルドして用意する必要がある**。エンジンのビルドを通す
前提条件でもあるので、フェーズ1の `swift build` 到達時に必要になる。

- [x] ~~llama.cpp を CPU / CUDA / Vulkan の各構成でビルド~~ → **ビルドしない。**
      `tools/fetch-backends.ps1` が `azooKey/llama.cpp` の b4846 リリースから
      バックエンド別のプレビルドを取る(決定 0028 の追記)。
- [x] ~~`systemLibrary` 用の module map とヘッダ配置を用意~~ → **upstream が同梱済み**
      (`Sources/llama.cpp/module.modulemap` + 各ヘッダ)。`link "llama"` 指定があるため、
      こちらが用意するのは `llama.lib` / `llama.dll` と、リンカへの `-Xlinker -L` 指定のみ。
- [x] エンジン起動時の DLL 検索パス切り替え(`SetDefaultDllDirectories` / `AddDllDirectory`
      + 遅延ロード)を実装。
- [x] 選択したバックエンドの初期化失敗時に CPU へフォールバックし、状態を設定アプリに表示。
      **検索パスを向けるだけでは足りない** — それでは読み込めるかが決まらず、遅延ロード
      任せだと最初の変換で構造化例外になってフォールバックの機会が無い。まだ引き返せる
      うちに `LoadLibraryExW` で実際に読み込む。状態は
      `%LOCALAPPDATA%\Ohagey\backend-status.tsv` に書いて設定アプリが読む
      (エンジンはオンデマンド起動なので、設定アプリを開いた時点では動いていない)。
      実機で3ケース確認(`tsf/Ohagey/tools/check-backend-fallback.ps1`)、
      フォールバック後もそのまま Zenzai が変換できることまで確認済み。決定 0028 の追記

## 実装時に確定する残課題(決定ログより)

- ~~ユーザー辞書ファイルの具体フォーマット(JSON 等、決定 0026)~~ → **決定 0036 で確定**(タブ区切り)。
- ~~設定用レジストリスキーマの詳細(決定 0014)~~ → **決定 0035 で確定**。
- `ohagey.proto` の各メッセージ詳細の最終確定(本初版からの調整)。

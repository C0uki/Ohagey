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

**変換器そのものを触るときは `OHAGEY_CONVERTER_PATH`。** `.build/checkouts/` の中を
編集しても **SwiftPM は再ビルドしない**(1秒で "Build complete" と言って前の
バイナリをリンクする)。決定 0034 はこれで取った測定をまるごと撤回している。
clone した fork を指すと `.package(path:)` に切り替わる。
ディレクトリ名・scratch・`backends\cpu\` のコピーに落とし穴があるので
`docs/local-setup.md` を見ること。**環境変数を外せば pin に戻る。CI と出荷は常にそちら。**

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

**フェーズ1(エンジン)は動いている。フェーズ2(TSF)が実機で通った。**
`settings-app/` はまだ雛形のみ。

### 🎉 実機で日本語が打てる(2026-08-04)

インストールして日本語の入力方式に追加し、メモ帳で打った。**エンドツーエンドで動く。**
エンジンのリクエストログが実セッションの証拠を残している:

```
#3 convert (reading 5, preceding 4, n_best 50) -> 50 candidates (zenzai true) in 180ms
#4 commit  (reading 5, text 5, learn true) -> ok in 9ms
```

読みが Zenzai で変換され、**左文脈が乗り**、確定が学習まで届いている。
`%LOCALAPPDATA%\Ohagey\personal\corpus.txt` が実際に育っている。

利用者に確認してもらった動作: **A のとき英語が半角** / **かな入力中は `!` `@` `^` が
`！ ＠ ＾`** / **英数(CapsLock) で あ ↔ A** / **半角/全角 が効く** /
**`ko-hi-` で コーヒー** / **スペース連打で候補送り(50件)** /
**変換せず Enter で確定できる** / **バックスペースがかな1文字を消す** /
**ダークモードでアイコンが見える** / **Microsoft Store(UWP)でも打てる**。

ここに至るまでに **vendoring 元が中国語 IME であることに起因する不具合を12件**
潰している。決定 0033 の追記7〜16 に全部書いた。**LANGID は入口でしかなかった** —
フォント、タッチキーボード配列、言語バーの文言、`.ico` の中身(中/英/样という
**文字そのもの**)、句読点の対応表、切り替えキー、そして
**「IME が閉じていても変換する」という中国語 IME 固有の前提**。

### 実機で検証済み
- Windows で `swift build` が通り `OhageyEngine.exe` が生成される
- `swift test` **202件パス**
- **実クライアントとの往復**: 名前付きパイプ経由で `Ping` / `Convert` が動作。
  `へんかん` → 変換/返還/… を返す(辞書の実ロードと変換を確認)
- **6クライアント同時接続** — 全員が自分の `request_id` で正しく応答を受け取る
- 不正リクエストは同じ `request_id` で `INVALID_ARGUMENT` を返し、**接続は維持される**
- アイドルタイムアウト自己終了(decision 0015)— 5秒設定で実測
- 設定のホットリロード(decision 0014 / 0035)— HKCU から読み込み、即時反映、
  再起動が要る項目の通知、新規プロファイルでのキー作成まで確認
- パイプ ACL を稼働中のパイプから読み戻して設計と一致を確認(decision 0031)
- **UWP / AppContainer から実接続**(decision 0031 の追記)。Microsoft Store の
  検索ボックスから `convert` / `commit` / 左文脈まで動作。接続元 pid をログに出して確認した
- **左文脈が実機で届く**(decision 0034 / 0033 の追記18)。`tsf.log` と `engine.log` が
  同じ時刻で `moved -2 / fetched 2` → `preceding 2` を示す。改行で切るので行頭では 0 になる

- **Zenzai の実変換**(decision 0008)。モデル配置後に文レベルの変換を確認
  (`きょうはいいてんきですね` → 今日はいい天気ですね)。
  レイテンシは上記のとおり毎回ラティスを作り直す前提の値になっている。
  計測方法の落とし穴は `docs/local-setup.md` に記録した(素朴に測るとキャッシュを測ってしまう)

- **Zenzai 有効時の順位に学習が効く**(decision 0034)。`build-and-run-learning.ps1`:
  学習ストアのみは **2位のまま**、個人化を足すと **2位→1位**。他4候補も全部残る。
- 🔴 **個人化には base 言語モデルが要る。無いと「弱く効く」のではなく完全に無効**
  (decision 0034 の 2026-08-04 追記)。
  **base は自前で作って配る** — `tools/build-base-lm.ps1` が Wikipedia のコーパスから
  5ファイル・9.4MB を作り、インストーラがリリース資産として取得する
  (decision 0008 / 0009 の追記2)。CC BY-SA 4.0 で zenz と同じ枠組みに収まる。
  ⚠️ **`Miwa-Keita/base_n5_lm` は外した** — 4ファイルしか無く resume できないので
  **害のある個人モデルしか作れない**。ライセンス未記載の懸案も一緒に消えた。
  リリース資産は **`base-lm-v1` として公開済み**。**実際にインストールして、
  release ビルド・環境変数の上書きなしで個人化が効くことまで確認した**
  (個人化オフ 2位→2位 / オン 2位→1位、評価セット 30/30)。
  開発時は `OHAGEY_BASE_LM_PATH` だが **debug ビルドでしか読まれない** —
  release で個人化を測ろうとして半日溶かした。個人化を主題にするハーネスは
  `base-lm-status.ps1` で不在を検出して止まる
- **個人化は既定で有効**(2026-08-04 に反転)。追記11 がオフにした理由(30件中15〜18件を
  壊す)は、個人モデルをゼロから学習していたことの帰結で、resume 可能な base を
  出荷することで消えた。**base が resume 可能でなければ適用しないガードは残る**ので、
  取得に失敗した端末では既定オンでも何も起きない。
  ⚠️ **オンだと確定した語句の控えが平文で残る**(`personal/corpus.txt`)。
  変換器の学習ストアと違って読める。切れば消える(決定 0025)。
  ⚠️ **ただしユーザー辞書の経路は既定オフでも生きており、そこは未測定**(下記)。
- ⚠️⚠️ **個人化を有効にすると変換品質が落ちる。着手前に必ず読むこと。**
  正解が既知の32件の評価セット(`tsf/Ohagey/tools/eval-set.tsv`)で測ると、
  **1つの語句を40回確定しただけで無関係な30件中16〜18件が正解を失う**(α=1.0)。
  α=0.5 なら壊れるのは3件だが**目標も上がらない**。820行のコーパスを入れても
  18→16 でほぼ変わらない。**効いて壊れない設定は見つかっていない。**
  機序は判明済み: `ZenzContext` は `log(p + 1e-7)` で下駄を履かせて引き算するので、
  **個人モデルが知らない語すべてに alpha × 約 -4.6 logits** が入る
  (decision 0034 の追記12)。
  語彙を増やしても縮まない: 2163行・1010文字種の個人モデルで混合項の広がりは
  **14.81 logits**(1語 18.05 / 82行 15.50 / 820行 18.12)。
  🔴 **混合式を線形補間に直しても解けない**(decision 0034 の 2026-08-04 追記その3)。
  罰を有界にすると害は減るが(18→13)、**昇格も同じ速さで消える**。fork には入れていない。
  ✅ **害そのものは案3で消えた**(同 追記その4)。個人モデルを base から
  `resumeFilePattern` で学習し直すと、知らない語への罰が **-1.59 → -0.01**、
  混合項の広がりが **16.49 → 1.94 logits**、評価セットの巻き添えが **9件 → 0件**。
  「30件中15〜18件が壊れる」は**個人モデルをゼロから学習していたことの帰結**だった。
  巻き添えが消えたのは罰が消えたからではなく、**罰が利用者の文脈の中だけに
  閉じ込められた**から(打っていない文脈では base と広がり 0.00 で一致)。
  🔴 **upstream は候補の1文字目に個人化を掛けない**(`prefix` が空の間は
  `bulkPredict` を呼ばない)ので、**1文字目が違う候補は原理的に昇格しない**。
  **これは追わない判断**(decision 0034)。ハーネスは1位と先頭を共有する候補を
  目標に選ぶよう直してある。decision 0036 の「登録語が1位に来ない」もこれで説明がつく。
  ✅ **効果も対照付きで実証した。** 読みは `ふくをきる`(服を着る / 服を切る)—
  学習ストアだけでは上がらず、先頭を共有する数少ない例。
  **個人化オフ 2位→2位 / オン 2位→1位**、評価セットは30件中30件が正解のまま。
  `inferenceLimit` は無関係(既定10でも100でも同じ)。
  ⚠️ **昇格を見たらまず個人化を切って測り直すこと** — 決定 0034 はこの取り違えを3回した
  (`きかいをつくる` や `じかんをはかる` は学習ストアだけで上がる)。
  ⚠️ **ハーネスは再学習を待つこと。** 学習はゼロからなら約30ms、resume だと約5s。
  直後に測ると resume がすべて「効果なし」に見える(実際そう見えていた)。
  🔒 **base が resume 可能でなければ個人化は適用しない。** 5ファイル揃わない base
  では害のある個人モデルしか作れないため、その場合はオンでも何もしない。
  🔴 **base の大きさを決めるのは利用者側の再学習コスト。** 個人モデルは base から
  resume するので **base と同サイズになり**、再学習は確定のたびに走る:
  **5.2MB → 4.3秒/257MB、9.4MB → 7.9秒/459MB、42.6MB → 41秒/2,037MB**
  (約0.95秒/MB、約48MBメモリ/MB)。`base_n5_lm` に大きさを合わせる理由は無い —
  **推奨は 9〜10MB**(Wikipedia 約280記事)。小さい base でも昇格は起きる
  (5.2MB は3回確定、9.4MB と 42.6MB は40回確定)。
  **決定 0036 の登録語も同じ害を出したので、そちらの経路は取り消した**(下記)
- **変換は同じ入力に同じ答えを返す**(`build-and-run-stability.ps1`)。
  以前は確定の後に **2位→1位→2位→1位** と呼ぶたび入れ替わっていた —
  `requestCandidates` が前回のラティスを再利用するため。
  `ConversionService.convert` は毎回 `stopComposition()` してから変換する。
  **代償は速度**: release/CPU で平均 137ms、最悪 191ms
  (以前の記録 p50 70〜95ms はキャッシュを測った値)。
  (2026-08-04 に測り直し: 134 / 148 / 148 / 161ms。一度だけ出た 69ms は外れ値だった)

- **左文脈が変換に効く**(decision 0034 の 2026-08-03 追記)。`preceding_text` は
  ワイヤ上にありながら捨てられていた。`ZenzaiV3DependentMode.leftSideContext` に
  末尾30文字を渡すようにした。同じ読みが文脈で割れるのは**5件中4件**、人が選ぶ語を
  当てたのは **10件中7件**(文脈なしは上限の5件)。
  **学習しないので壊す対象が無い** — 個人化とは別の機構である。
  `tsf/Ohagey/tools/build-and-run-context.ps1`

- **ユーザー辞書**(decision 0026 / 0036)。格子のコストのみ。Zenzai 有効時は**3位**、
  Zenzai を切れば1位。**登録語を個人 n-gram に通すのは取り消した** — 1語登録しただけで
  無関係な30件中18件が正解を失ったため(decision 0036 の追記)。
  ハーネスが守るのは「登録しても他が壊れないこと」。
  `tsf/Ohagey/tools/build-and-run-userdict.ps1`

- **バックエンド選択**(decision 0028)。`backends\<name>\` の DLL 検索パス切り替えと、
  `tools/fetch-backends.ps1` による `azooKey/llama.cpp` のプレビルド取得。
- **読み込めないバックエンドからの CPU フォールバック**(decision 0028)。
  `tsf/Ohagey/tools/check-backend-fallback.ps1` で3ケース確認
  (正常 / ディレクトリ無し / `llama.dll` はあるが依存が無い→126)。
  フォールバック後もそのまま Zenzai が変換できる。状態は
  `%LOCALAPPDATA%\Ohagey\backend-status.tsv` に記録し、設定アプリが表示する

- **合成バッファはかなを持つ**(decision 0033 の追記)。不変条件は
  **「解決済みのかな + 未解決のローマ字(末尾)」**で、未解決部分は常に末尾の ASCII 連
  (かなは ASCII ではない)。**バッファの1文字が画面の1文字**になるので、バックスペースは
  「最後の1つを落とす」で済む。⚠️ 末尾の孤立 `n` はバッファでは `n` のまま —
  ん を焼き込むと `hona` が ほな にならない。判定は `RomajiKana` の純粋な関数にあり、
  `build-and-run-kana.ps1` で試験できる

- **確定はすべての経路で学習に届く**(decision 0024 / 0025 / 0033)。候補確定・
  候補リスト・**無変換確定**の3つ。⚠️ 無変換確定は**コーパスには入るが変換器の
  学習ストアには入らない** — 渡せる `Candidate` が存在しないため。エンジンのログが
  `no remembered candidate for this reading` と言う

- **候補は既定50件**(decision 0007)。9件は「候補窓の1ページ分」という表示の慣習で、
  変換の判断ではなかった。Zenzai はどの数でもラティスを作るので**代償は測定に出ない**
  (n_best 9→100 でレイテンシは横ばい)。変換器のほうが先に尽きる

- **エンジンは常駐**(decision 0015 の追記)。`idleTimeoutSeconds` の既定は **0**。
  AppContainer は `CreateProcess` を禁じられているので、アイドル終了は
  「サンドボックスされたアプリが動くかどうか」を**黙って断続的に**決めてしまう

- **ワイヤ互換を試験してある**(decision 0032 の追記)。**更新のたびに必ず
  「新しいエンジン × 古い DLL」になる**(エンジンは即座、DLL は再起動待ち)。
  手書きの reader が未知フィールドを飛ばし、切り詰めと過大な長さ接頭辞を弾くことを
  `build-and-run-wire.ps1` で9件確認

- **診断できる**(decision 0033 の追記10 / 21)。`engine.log` は起動・設定・
  **リクエスト1件ごと**、`tsf.log` は TSF 側。**どちらも打った内容は書かない**
  (長さと件数だけ)。`tsf.log` の毎変換の行は `HKCU\Software\Ohagey\DiagnosticLog`
  で切ってあるが、**DLL が自分のビルドを書く1行はスイッチの外**にある —
  「どの窓が古いビルドか」を起動時刻で人間に見分けさせないため

- **利用者が置いたテキストからコーパスを育てられる**(decision 0034 の追記)。
  `%LOCALAPPDATA%\Ohagey\personal\import\*.txt` を学習の直前に取り込み、
  読んだファイルは `import\done\` に**移す**(消さない)。各行は確定と同じ
  `corpusLine(for:)` を通る。⚠️ **重複除去は入れていない** — azooKey の Tuner が
  MinHash で落とすのは画面収集の副産物であって頻度ではなく、こちらでは
  **繰り返し確定したこと自体が個人化の読む信号**だからである(昇格に3〜40回)。
  Tuner の**画面収集は採らない**: 利用者が打っていないテキストが平文で残る

- **CI がインストーラをコンパイルする**(decision 0033 の追記22)。自己検査
  (`kana-selftest` / `wire-selftest`)も走る。設定アプリだけ
  `#ifndef CiWithoutSettingsApp` で外す — **出荷構成を define の無い側に置いてある**

### 未検証
- 🔴 **AppContainer からはエンジンを起動できない**(決定 0031 の追記)。
  `CreateProcess` が禁じられているので、エンジンが落ちていると UWP アプリでは
  **打てるのに変換だけ効かない**(エラーにはならない)。決定 0015 の
  オンデマンド起動と緊張関係にあり、解き方は未決


- **CUDA / Vulkan が実機で動く**(decision 0028 の追記)。3つとも読み込まれて変換し、
  CUDA は GPU にも載る(0 → 93 MiB、`nvidia-smi` が compute app として認識)。
  速さは cpu 195ms / cuda 147ms / vulkan 150ms(範囲は重ならない)。
  🔴 **出荷するなら vulkan** — 22.6MB で cuda(977MB)と同じ速さ、しかも GPU を選ばない

### 未着手
- ロードマップに残るのは**測定が要る問い**(alpha 0.5 が「壊さないが効かない」理由、
  1文字目に個人化がかからない件の周辺)と**設定アプリの UI**、それに将来の判断
  (fork を upstream に PR するか、x86 の TSF DLL、`trainNGram` の400万字上限)。
  `docs/roadmap.md` を見ること

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

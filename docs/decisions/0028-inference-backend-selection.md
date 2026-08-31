# 0028: 推論バックエンドの選択方式(決定0010の改訂)

## 背景 — 決定0010の前提が崩れた

決定0010は「CPU / CUDA / Vulkan を設定でユーザーが選択可能」とだけ決めており、
**どう実現するか**は詰めていなかった。フェーズ1の実装着手時に upstream
(AzooKeyKanaKanjiConverter)を調査した結果、以下が判明した。

1. **`ZenzaiMode` にバックエンド関連のフィールドが無い。**
   `weightURL` / `inferenceLimit` / `requestRichCandidates` / `personalizationMode` /
   `versionDependentMode` のみで、`n_gpu_layers` に相当する GPU オフロード設定は
   公開されていない。→ **変換 API 経由での実行時切り替えは不可能**。

2. **`Zenzai` と `ZenzaiCPU` の2つの package trait は、Package.swift 上では同一の扱い。**
   どちらも「C++ 相互運用の有効化 + `llama.cpp` ターゲットへの依存 + SwiftyMarisa」を
   有効にするだけで、**trait はバックエンドを選択していない**。

3. **Windows では `llama.cpp` が `.systemLibrary` ターゲット。**
   SPM は llama.cpp をビルドせず、こちらが用意したライブラリにリンクする
   (Apple プラットフォームのみ `.binaryTarget` の xcframework を取得する)。
   → **バックエンドを決めるのは「どの llama.cpp バイナリを用意・同梱するか」**。

つまり制約は「trait によるビルド時固定」ではなく、「**リンクする llama.cpp が
バックエンドを決める**」だった。おはぎー側で DLL を用意する以上、選択の余地はある。

## 決定事項 — DLL 差し替え方式

CPU / CUDA / Vulkan それぞれでビルドした llama.cpp を**バックエンド別のサブディレクトリに
同梱**し、**エンジンプロセスの起動時に、設定に応じて DLL 検索パスを切り替えて**
読み込む。

```
%ProgramFiles%\Ohagey\
  OhageyEngine.exe
  backends\
    cpu\     llama.dll (+ 依存 DLL)
    cuda\    llama.dll (+ CUDA ランタイム等)
    vulkan\  llama.dll
  models\
    ggml-model-Q5_K_M.gguf
```

- 設定アプリでバックエンドを変更したら、**エンジンプロセスを再起動**して反映する。
- エンジンは元々オンデマンド起動・アイドルタイムアウト終了の別プロセス(決定 0004 / 0015)
  なので、再起動は設計に無理なく収まる。TSF クライアントは再接続するだけでよい。
- 実装は遅延ロード(delay-load)+ `SetDllDirectory` / `AddDllDirectory` 相当で行う。
  詳細な機構は実装時に確定する。

## 決定0010の位置づけ

決定0010(ユーザーがバックエンドを選択できる)は**維持**する。本決定はその実現方式を
定めたものであり、ユーザーから見た体験(設定アプリで選ぶ)は変わらない。
唯一の変更点は、**切り替えにエンジンの再起動を伴う**こと。

## 検討した代替案

| 案 | 却下理由 |
|---|---|
| エンジン exe をバックエンド別に分ける | リンクは単純になるが、インストールサイズが最大。DLL 差し替えで足りる |
| CPU のみに縮小(GPU は将来) | 最小構成だが、Zenzai の GPU 活用という利点を初期段階で捨てることになる |
| CUDA を諦めて CPU + Vulkan の2種 | サイズは有利。**将来的な縮小案として保持**する(下記リスク参照) |

## 実装時のリスク・確認事項

- **CUDA ビルドは CUDA ランタイム DLL の同梱が必要**でサイズが大きい。インストーラー
  肥大化が問題になるなら、CUDA を落として CPU + Vulkan の2種に縮小する
  (Vulkan は NVIDIA / AMD / Intel を一括カバーできる)。
- Vulkan は通常ドライバ同梱の ICD で動くが、環境によっては動作しない。**選択した
  バックエンドで初期化に失敗した場合は CPU にフォールバック**し、設定アプリに状態を
  表示すること。無音で変換不能になる事態を避ける(決定 0008 と同じ思想)。
- llama.cpp のビルド構成(バージョン、ビルドフラグ、`systemLibrary` 用の module map)は
  再現性のため記録すること。

## llama.cpp のバージョン依存(実機ビルドで確定)

**AzooKeyKanaKanjiConverter 0.8.5 ↔ llama.cpp `b4846`。**

upstream の `Package.swift` が Apple 向けに参照している xcframework が
`azooKey/llama.cpp` の `b4846` リリースであり、これが前提バージョン。
最新の master を使うと KV キャッシュ API のリネーム(旧 `llama_kv_cache_*` の削除)により
リンクが通らない:

```
lld-link: error: undefined symbol: llama_kv_cache_seq_rm
lld-link: error: undefined symbol: llama_kv_cache_seq_pos_max
```

**AzooKeyKanaKanjiConverter の pin を上げる際は、llama.cpp 側の対応バージョンを必ず
確認し直すこと。** この2つは独立に更新できない。
手順は [`../local-setup.md`](../local-setup.md) を参照。

## 追記(2026-08-01)— llama.cpp は自前でビルドせず、azooKey のリリースから取る

上の `backends\{cpu,cuda,vulkan}\` を埋める DLL の**出どころ**を決める。

`azooKey/llama.cpp` は `b4846` の Windows x64 バイナリを**バックエンド別に公開して
いる**(`llama-b4846-bin-win-avx-x64.zip` / `-cuda-cu12.4-` / `-vulkan-`)。
これを `tools/fetch-backends.ps1` で取得する。

### なぜビルドをやめるか

3種類を自前でビルドするには、開発者と CI の両方に CUDA Toolkit と Vulkan SDK が
要る。決定 0010 の「ユーザーがバックエンドを選べる」は、それを用意しないと
CPU 以外は**誰も一度も動かさないまま**になる。既に公開されている物を取るだけなら
その障壁が消える。

副産物として CI が速くなった(cmake 10分超 → 17MB のダウンロード)。ただしそれは
理由の2番目で、1番目は下記。

### なぜ upstream ではなく `azooKey/llama.cpp` か

**間違えても壊れないから危ない。** `ggml-org/llama.cpp` の同じ `b4846` でビルドしても、
リンクは通り、エンジンは起動し、変換も返ってくる。ただ zenz モデルだけが
`unknown pre-tokenizer type: 'gpt2-small-japanese-char'` で読めず、辞書変換に
フォールバックする。**ログを見ない限り気付けない**(決定 0034 で実機で踏んだ)。

CI は以前 upstream をビルドしていた。CI にモデルは無いので表面化しなかったが、
正しくない物を基準にビルドを緑にしていたことに変わりはない。今回それも直った。

### なぜ `fkunn1326/llama.cpp` ではないか

azooKey-Windows(先行実装)は同じ b4846 バイナリを `fkunn1326/llama.cpp` から
取っている。中身は同等だが、**この DLL はユーザーが文字を打つあらゆるアプリの
プロセスに入る**(決定 0002 のインプロセス構成)。個人の fork ではなく、変換器そのものを
出している組織のリリースを使う。

### CPU は avx。avx2 / avx512 ではない

`llama-b4846-bin-win-avx-x64.zip` を使う。avx2 は 2013年以降の CPU、avx512 はさらに
限られる。**起動しない機械が存在する**方が、少し遅いより悪い。IME は他のアプリの
中で動くので、失敗の見え方も悪い。

なお `llama.lib` は1つで足りる。3バックエンドは ABI 互換であり、そうでなければ
実行時に差し替えるという本決定自体が成り立たない。

## 追記(2026-08-01)— 読み込めなかったときの扱い

上の「実装時のリスク」にある**初期化失敗時の CPU フォールバックと状態表示**を実装した。

### 検索パスを向けるだけでは足りない

`AddDllDirectory` で `backends\cuda\` を指しても、決まるのは**どの `llama.dll` が選ばれるか**
だけで、**それが読み込めるか**は決まらない。CUDA ランタイムの無い機械に CUDA ビルドを
置けば、ファイルは存在し、読み込みは失敗する。

遅延ロード任せにすると、これは**最初の変換で構造化例外**として出る。エンジンは
入力の途中で落ち、本決定の「CPU にフォールバックする」は発動する機会すら無い。

そこで、まだ引き返せるうちに `LoadLibraryExW` で**実際に読み込んでしまう**。プローブと
確定を兼ねている。以降の遅延ロードはベース名で `LoadLibrary` を呼び、Windows は
ロード済みモジュール一覧から解決するので、ここで読み込んだものが使われる。

失敗したディレクトリは `RemoveDllDirectory` で検索パスから外す。読み込めない
`llama.dll` を残しておくと、その `ggml*.dll` が動く方のバックエンドのものより先に
見つかりうる。

実機で確認(`tsf/Ohagey/tools/check-backend-fallback.ps1`):

| 要求 | 状況 | 結果 |
|---|---|---|
| cpu | 正常 | `reason=requested` |
| cuda | ディレクトリごと無い | cpu へ、`reason=not-installed` |
| vulkan | `llama.dll` はあるが依存が無い | cpu へ、`reason=load-failed`、`detail=126` |

3つ目のあと**そのまま Zenzai が変換できる**ことも確認済み(`Zenzai model loaded` が出て、
`きょうはいいてんきですね` が通る)。つまり遅延ロードはフォールバック先を掴んでいる。

### 状態は**ファイル**で渡す — レジストリではない

エンジンはオンデマンド起動・アイドル終了(決定 0004 / 0015)なので、**設定アプリを開いた
時点で動いていることの方が少ない**。エンジンが知ったことは、知ったプロセスより長生き
する必要がある。

`%LOCALAPPDATA%\Ohagey\backend-status.tsv` にタブ区切りで書く(決定 0036 と同じ形式)。

```
version	1
requested	vulkan
effective	cpu
reason	load-failed
recorded-at	2026-08-01T07:11:37Z
detail	126
```

`HKCU\Software\Ohagey` を使わないのは、あそこが**設定アプリが書き、エンジンが読む**
一方向のチャネルだから(決定 0035)。エンジンが書けばその1項目だけ向きが逆になり、
しかもエンジンは**自分の書き込みで自分の変更通知を起こす**。ファイルなら
どのチャネルも一方向のままでいられる。

### 設定アプリでの見せ方

`要求 ≠ 実際` のときだけ警告にする。正常時も警告にすると読み飛ばされるようになり、
本決定がこの表示に求めていることの逆になる。

**設定を変えた直後**は「フォールバック」ではなく「次回の起動から有効」と出す。記録は
前回の起動時のもので、まだ試していないバックエンドについて「読み込めなかった」と
言うのは嘘になる。

## 追記(2026-08-03)— CUDA ランタイムは同梱されていない。**サイズが判断を迫る**

`tools/fetch-backends.ps1` を入れたとき、「CUDA 版に CUDA ランタイムが同梱されて
いるか未確認。CUDA を配布物に入れる前に確定させること」と残した。確定した。

## 同梱されていない

`llama-b4846-bin-win-cuda-cu12.4-x64.zip`(184MB)の中身:

| | |
|---|---|
| `cudart` / `cublas` / `cublasLt` 等 | **1つも無い** |
| `ggml-cuda.dll` | **427MB**(展開後) |
| DLL 合計 | 7個、**429MB** |

`ggml-org/llama.cpp` の同じタグには `cudart-llama-bin-win-cu12.4-x64.zip` が別アセット
としてあるが、**`azooKey/llama.cpp` のリリースには無い**。CUDA ランタイム自体は NVIDIA の
再配布可能物なので、そちらから取ること自体は可能。

## つまり CUDA を提供するなら

1. **`ggml-org` から cudart を別途取る**(azooKey の fork には無いため)。
   決定 0028 の追記で「DLL は変換器と同じ組織のリリースから」としたが、
   cudart は NVIDIA のものなので出所の議論は当てはまらない
2. あるいは **CUDA Toolkit 導入済みの機械を前提にする**。IME としては現実的でない

## それより重い問題 — 429MB

CPU は展開後 2.4MB(実測)。Vulkan は zip が 21.8MB で、展開後は未測定。
**CUDA だけ 429MB + cudart** で、モデル(70MB)と base LM(42.6MB)を足した
インストーラ全体を一桁変えてしまう。

決定 0028 は当初から逃げ道を用意していた:

> CUDA を落として CPU + Vulkan の2種に縮小する(Vulkan は NVIDIA / AMD / Intel を
> 一括カバーできる)

**その判断をする材料が揃った。** 429MB を配るか、Vulkan で NVIDIA も賄うか。

- Vulkan の zip は 21.8MB。**CUDA の 1/20**
- Zenzai は 500M 級の小さなモデルで、GPU 差が体感に出るかは未測定
- CPU で平均 137ms(決定 0034 の追記5)。これが遅すぎるなら GPU が要る

- [ ] **CPU / Vulkan のレイテンシを実測してから決める。** Vulkan で足りるなら
      CUDA は落とせる。実機に NVIDIA GPU がある前提の測定が要る
- [ ] 落とさないなら、**インストーラでバックエンドを選択式にする**(全部入れない)

## 追記(2026-08-04)— GPU バックエンドを実機で動かした。**Vulkan が答えである**

RTX 3050 Ti Laptop + Intel UHD の機械で、cpu / cuda / vulkan の3つを実際に走らせた。

### 3つとも読み込まれ、変換する

```
backend: cpu    from ...ackends\cpu
backend: cuda   from ...ackends\cuda
backend: vulkan from ...ackendsulkan
```

`backend-status.tsv` も `requested vulkan / effective vulkan / reason requested` を記録する。

### CUDA は本当に GPU に載っている

**「読み込めた」と「GPU で動いている」は別の主張である。** llama.cpp は
オフロードを頼まれなければ CUDA ビルドのまま CPU で回る — 黙って。確かめた:

```
GPU memory before: 0 MiB
GPU memory after : 93 MiB       ← Q5_K_M の重み約70MB + コンテキスト
nvidia-smi: OhageyEngine.exe が compute app として並ぶ
```

### 速さ(`きょうはいいてんきですね`、n_best 50、各3回)

| バックエンド | 平均 | 最小 | 最大 |
|---|---|---|---|
| cpu | **195ms** | 182 | 204 |
| cuda | **147ms** | 138 | 154 |
| vulkan | **150ms** | 145 | 153 |

**約25%速い。** 範囲は重なっていない(cpu の最小 182 > cuda の最大 154)。
劇的ではないのは、1リクエストの費用が行列積だけでないからである —
ラティスの構築は CPU 側にあり、決定 0034 で毎回 `stopComposition()` してから
組み直すようにしてあり、推論の歩数は既定10である。

### 🔴 出荷の判断: **CUDA を同梱する理由が無い**

| | 大きさ | 平均 |
|---|---|---|
| cuda | **977 MB** | 147ms |
| vulkan | **22.6 MB** | 150ms |

**43分の1の大きさで、測定できる差は無い。** そして Vulkan は NVIDIA だけでなく
Intel でも AMD でも動く。この決定は GPU バックエンドを `#ifdef GpuBackends` の
後ろに置いたが、**同梱するなら vulkan であり、cuda ではない。**

⚠️ 測定は1機種・各3回である。**別の GPU、別の読みの長さ、別の `inferenceLimit` で
比が変わる可能性は残る。** 特に `inferenceLimit` を上げれば行列積の割合が増えるので、
CUDA の分が良くなる方向に動くはずである — 上げる判断をするときに測り直すこと。

## 追記(2026-08-27)— NPU で演算できるか。**できない。狙うなら Vulkan である**

「Copilot+ PC の NPU で変換できないか」という問い。**この決定の枠内で答えは出て
いて、「NPU 用の `llama.dll` が存在しない」である。** 理由は3段あり、それぞれ
独立に効く — 1つ解けても残り2つが立っている。

### 1. おはぎーにとっての「NPU 対応」は、`backends\npu\llama.dll` を置けるかである

本決定の調査項目1のとおり、`ZenzaiMode` に `n_gpu_layers` に相当するフィールドは
無い。**変換 API からデバイスを指名する経路は存在しない。** `BackendLoader` が
やっているのも DLL 検索パスの切り替えだけである。

だから問いは推論の話ではなく配布の話に還元される — **NPU で動く llama.cpp
b4846 相当の Windows x64 ビルドを用意できるか。**

### 2. その DLL が無い

`tools/fetch-backends.ps1` の資産表がそのまま答えになっている。`azooKey/llama.cpp`
の `b4846` が公開している Windows x64 は **avx / cuda-cu12.4 / vulkan の3つだけ**で、
NPU 向けは無い。

⚠️ **上流(`ggml-org`)の b4846 に何のバックエンドがあったかは現物で確認していない。**
確認するなら b4846 タグの `ggml/src/ggml-*` を見ること。記憶で書くと、ggml で
「NPU」と呼べるのは CANN(Huawei Ascend、Linux/aarch64 のサーバー向け)だけで、
Windows の民生 NPU に届く経路は当時どれも無い:

| NPU | 実際の経路 | b4846 時点(未検証) |
|---|---|---|
| Intel Core Ultra (AI Boost) | OpenVINO / DirectML | ggml の OpenVINO バックエンドは b4846 より後 |
| AMD Ryzen AI (XDNA) | ONNX Runtime + Vitis AI EP | ggml バックエンド無し |
| Qualcomm Hexagon | QNN | 当時未マージ。かつ **Snapdragon X は ARM64 で決定 0018 の対象外** |
| Huawei Ascend | CANN | ggml にはある。Windows x64 の話ではない |

**ただし結論はこの表に依存しない。** 仮に上流にあったとしても、この決定が既に
断っている2つがそのまま残る(いずれも追記 2026-08-01):

- **自前ビルドはしない。** 3種を自前でビルドするには開発者と CI の全員に
  ツールキットが要り、それを用意しないと「ユーザーが選べる」は**誰も一度も
  動かさないまま**になる。NPU はここにベンダー SDK をもう1つ足す
- **他所のビルドを持ち込むと Zenzai だけが黙って無効になる。** zenz の
  `gpt2-small-japanese-char` pre-tokenizer は azooKey の fork にしか無く、
  リンクも起動も変換も通ったまま辞書変換に落ちる(決定 0034 で実際に踏んだ)

NPU ビルドは**この2つを同時に踏む**。

### 3. 仮に用意できても、この負荷では効かない見込み

上の実測(cpu 195ms / cuda 147ms / vulkan 150ms)が**そのまま NPU の見通しになる**。
GPU に載せても25%しか縮まないのは、1リクエストの費用が行列積だけではないから
だった — ラティスの構築は CPU 側にあり、決定 0034 で毎回 `stopComposition()` して
から組み直し、推論の歩数は既定10である。

NPU が得意なのは**大きな静的形状のバッチ行列積**で、Zenzai の使い方は
**小さいプロンプト評価を、動的な形で、何度も**である。噛み合わせが一番悪い形。

さらにモデルの形式が合わない。NPU 系ランタイムは GGUF の k-quant を食べないので、
`ggml-model-Q5_K_M.gguf`(70.4MB)を INT8/INT4 の別形式へ変換することになる。
それは**モデルを作り直し、決定 0008 / 0009 の配布経路も作り直す**話である
(zenz は CC BY-SA 4.0 なので再配布自体は可能だが、帰属の枠組みごと引き受ける)。

### 器は既にある。無いのは中身だけ

将来 NPU 向けの llama.cpp ビルドが出たときに必要な変更は小さい:

| 触る場所 | 変更 |
|---|---|
| `EngineSettings.swift` の `Backend` | `case npu` を足す |
| `ohagey.proto` の `Backend` | `BACKEND_NPU = 4` を足す |
| `BackendLayout` | **不要**。ディレクトリ名は `rawValue` から作る |
| `BackendLoader` | **不要**。読み込めなければ CPU に落ちる経路は実機で3ケース確認済み |
| `tools/fetch-backends.ps1` | `$assets` と `ValidateSet` に1行ずつ |
| インストーラ | `#ifdef GpuBackends` と同じ扱いで同梱を選ぶ |

古い DLL との組み合わせ(決定 0032 の「新しいエンジン × 古い DLL」)も持つ。
`Backend` が乗るのは `PingResponse.backend` だけで、C++ 側は未知の値を
`static_cast<Backend>` でそのまま保持する。**DLL はこの値を診断ツール以外で
使っていない**ので、知らない番号が来ても動作は変わらない。

つまりこの決定の DLL 差し替え方式は、**バックエンドが増えること自体には既に
耐えている**。判断が要るのは常に「その DLL を配れるか」の側である。

### 🔴 結論: NPU は追わない。省電力・CPU 温存の動機は Vulkan で取る

NPU を狙う理由の実体は「速さ」ではなく「CPU を空ける・電池を食わない」である。
**それは Vulkan で取れる** — 22.6MB で、Intel の内蔵 GPU でも AMD でも NVIDIA でも
動き、CUDA と測定できる差が無い(前の追記)。

llama.cpp を捨てて ONNX Runtime 側へ移る案は、**決定 0001(変換エンジンのみ流用)を
崩す**。ラティスも学習も個人化も自前になるので、NPU の見返りとは釣り合わない。

再考する条件を書いておく。**上流に Windows x64 の NPU バックエンドが入り、かつ
`azooKey/llama.cpp` がそのバイナリを公開したとき**、この追記は無効になる。
そのときも判断材料は同じで、`inferenceLimit` を上げた状態での実測である
(歩数を上げれば行列積の割合が増え、アクセラレータ側に有利に動く)。

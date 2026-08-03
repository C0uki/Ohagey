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

## 追記(2026-08-03、その2)— CUDA を同梱する。**ただし速度差は 12ms しかない**

「CUDA を含める」という判断を受けて `tools/fetch-backends.ps1` に CUDA ランタイムの
取得を足した。`-Backends cuda` は2つのアーカイブを取る:

| 取得元 | アセット | 展開後 |
|---|---|---|
| `azooKey/llama.cpp` | `llama-b4846-bin-win-cuda-cu12.4-x64.zip` | 429MB |
| `ggml-org/llama.cpp` | `cudart-llama-bin-win-cu12.4-x64.zip` | **548MB** |
| | **合計** | **977MB**(10 DLL) |

`cublasLt64_12.dll` 単体で 451.6MB ある。**ダウンロード 557MB、ディスク 977MB。**

ランタイムを upstream から取るのは、上の「なぜ `azooKey/llama.cpp` か」と矛盾しない。
あの議論は zenz の pre-tokenizer を持つ llama 側の DLL についてのもので、
`cudart` / `cublas` は **NVIDIA の再配布物**であり、どこから取っても同一である。

**2つのアーカイブは必ず一緒に取る。** 片方だけの `backends\cuda\` は
「インストールされているのに読み込めない」状態そのもので、エンジンは CPU に
フォールバックし、設定アプリは CUDA と表示することになる(上の 126 の件)。

### 実機で動いた

RTX 3050 Ti Laptop で確認:

```
backend: cuda from ...\backends\cuda
requested cuda / effective cuda / reason requested
```

`cudart` を入れる前は同じ構成が **126(依存 DLL が無い)で CPU に落ちていた**ので、
ランタイムの同梱が効いていることも同時に確かめられた。

### ⚠️ 速度差は 12ms

`tsf/Ohagey/tools/build-and-run-stability.ps1`、release、同一セッション、
`きしゃのきしゃ` を20回:

| バックエンド | 平均 | 最悪 |
|---|---|---|
| CPU | **78ms** | 86ms |
| CUDA | **66ms** | 71ms |

**977MB を配って 12ms(約15%)。** Zenzai は 500M 級の小さなモデルで、1回の変換が
数十msしかかからない以上、GPU に載せても稼げる幅がそもそも小さい。

判断は「CUDA を含める」で確定しているが、**この数字は判断の前には無かった**ので
記録しておく。再考の材料になるなら:

- Vulkan は zip 21.8MB。NVIDIA / AMD / Intel を一括で賄える。**未計測**
- インストーラでバックエンドを選択式にすれば、既定は CPU のまま CUDA を任意にできる
- CPU 78ms が許容できるなら、GPU 自体が要らない可能性もある

- [ ] **Vulkan のレイテンシを測る。** CUDA と同程度なら、**1/45 のサイズで足りる**ことになる

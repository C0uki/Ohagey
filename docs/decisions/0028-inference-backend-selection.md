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

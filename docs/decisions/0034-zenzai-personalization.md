# 決定 0034: 学習を Zenzai の順位に効かせる

決定 0025(学習はデフォルト有効)の実装に必要だった未確定部分。
決定 0021(依存コードの取り込み方)に fork という選択肢を追加する。

## 背景 — 学習していたのに、順位が変わっていなかった

`commit` は `updateLearningData` を呼んで変換器の学習ストアを埋めている。
これは**辞書のみのときは効く**が、**Zenzai を有効にすると効かない**。実測:

| モデル | 2番目の候補を確定 → 再変換 |
|---|---|
| なし(辞書のみ) | 1位に上がる |
| あり(Zenzai) | 順位は動かない |

学習ストアはラティスを養う。Zenzai はそのラティスの**上**でニューラルモデル
による再ランクをかける。つまり学習は届いていない。

upstream が Zenzai 自体を個人化する手段は
`ZenzaiMode.PersonalizationMode` で、学習済みの n-gram 言語モデル 2本
(base と personal)を marisa trie として受け取る。

## 障害だったもの

**upstream は Windows で個人化を丸ごと除外していた。**

```swift
#if (!os(Linux) || !canImport(Android)) && !os(Windows)
// Android環境・Windows環境ではSwiftyMarisaが利用できないため、EfficientNGramは除外する。
```

除外されると `EfficientNGram` はモック実装になり、全語に一律 `1/6000` を返す。
`trainNGram` はそもそも宣言すらされない。

理由とされる「SwiftyMarisa が Windows で利用できない」を確かめたところ、
**原因はヘッダの1行だった**:

```c
typedef unsigned long size_t;   // <stdlib.h> の直後にある
```

Windows x64 は LLP64 で `size_t` は `unsigned long long`。`unsigned long` は
32bit なので再定義エラーになる。これはどのプラットフォームでも本来バグで、
たまたま `unsigned long == size_t` の環境では露見しなかっただけ。

その1行を消すと **`swift build` が通り、機能テストも全部通った** —
構築・検索・predictive/prefix・save/load の往復。

### さらに見つかった、もっと深いバグ

ビルドが通ることと動くことは別だった。学習後の `bulkPredict` が
**実行ごとに違う値を返した**:

```
実行1: bulkPredict("おはぎー") の最大 = 0.49297109375
実行2: 同じ trie ファイル、同じクエリで 0.125125
```

`marisa_add_word` と `marisa_search` は `const char *` を取って `strlen` する。
String から呼ぶ分には正しいが、SwiftyMarisa の **`[Int8]` オーバーロードは終端
NUL のない Swift 配列をそのまま渡していた**。EfficientNGram はキーの区切りに
負値を使う設計でキー部分に 0 が現れないため、`strlen` は必ず配列を踏み越え、
その先のメモリがキーと検索語の一部になっていた。

長さを取る `marisa_add_word_l` / `marisa_search_l` を足し、`[Int8]` 版から
そちらを呼ぶようにした(`marisa::Keyset::push_back` と
`marisa::Agent::set_query` はどちらも長さ付きオーバーロードを持っている)。
以後、同じ 3 実行が `0.496046240234375` で完全に一致する。

**このバグは Windows 固有ではない。** 未定義動作なので、配列の直後がたまたま
0 になりやすい環境では表面化しにくいだけ。

## 決定

### 1. fork を切ってコミットで固定する

| リポジトリ | fork | 変更内容 |
|---|---|---|
| `ensan-hcl/SwiftyMarisa` | [`C0uki/SwiftyMarisa`](https://github.com/C0uki/SwiftyMarisa) `ohagey-windows` | `size_t` 再定義の削除、`[Int8]` 経路への長さ引き渡し |
| `azooKey/AzooKeyKanaKanjiConverter` | [`C0uki/AzooKeyKanaKanjiConverter`](https://github.com/C0uki/AzooKeyKanaKanjiConverter) `ohagey-windows` | `Package.swift` のみ2箇所。Windows 除外の解除、`EfficientNGram` の product 公開 |

**azooKey 側はソース無改変**。fork 点は 0.8.5 タグそのものなので、
**決定 0028 の「0.8.5 ↔ llama.cpp b4846 は一体」という制約はそのまま維持される。**

ブランチではなく**リビジョンで固定**する。ブランチ指定だと再現性がない。

`EfficientNGram` を product として公開する必要があるのは、
`PersonalizationMode` が学習済み trie を受け取るだけで**それを作る手段を
提供しない**ため。`trainNGram` はこのターゲットにある。

upstream への PR は今回は出さない。fork で運用して確かめてから判断する。

### 2. base 言語モデルは同梱せず、空の trie で代替する

upstream の base n-gram LM は Hugging Face で配布されているが、
**ライセンスが明記されていない**。再配布できないし、決定 0016 により
インストール時以外の通信もできないので、実行時取得もできない。

そこで**何も学習していない base**を初回起動時に生成して置き換える。

これは劣化というより意味の変化である。`ZenzContext` の混合は

```
logit += alpha * (log p_personal - log p_base)
```

なので、**base が全語に同じ値を返すなら、全語に同じ定数を足すだけになり
順位は動かない**。実測: 空 base は 6000 語すべてに `1/6000` を返す(spread 0.0)。
結果として、ユーザーが打ったことのない候補は **Zenzai がつけた順序をそのまま
保ち**、学習した候補だけがそこから持ち上がる。

実測でも確認した。「機者の記者」を 40 回確定させた後:

```
before: 記者の記者 / 汽車の記者 / き者の記者 / 貴社の記者 / 機者の記者
after:  機者の記者 / 記者の記者 / 汽車の記者 / き者の記者 / 貴社の記者
```

ターゲットが 5位→1位 に上がり、**残り4件の相対順序は完全に保たれている。**

代償は較正である。打ち消してくれる本物の base が無い分、同じ alpha が
はるかに強く効く。

| alpha | 頻出語への加点 | 未学習語 |
|---|---|---|
| 0.50 (upstream 既定) | **+4.00 logits** | -2.38 |
| 0.25 | +2.00 | -1.19 |
| **0.15 (Ohagey 既定)** | **+1.20** | -0.72 |
| 0.10 | +0.80 | -0.48 |

upstream 既定の 0.5 はニューラルモデルを丸ごと押し切ってしまう。
**既定を 0.15 とし、設定で変更可能**にする。

### 3. コーパスを持ち、毎回まるごと学習し直す

確定したテキストを `%LOCALAPPDATA%\Ohagey\personal\corpus.txt` に1行ずつ
追記し、20コミットごとにコーパス全体から再学習する。

差分学習(`resumeFilePattern`)ではなく全体再学習にした理由:

- **決定 0025 の「消せる」が本当に成立する。** trie からエントリを引き算する
  必要がなく、ファイルを消すだけで済む
- 破損やドリフトが蓄積しない
- **そもそも安い。** 実測 10,000行で 1.8秒、ディスク 50 KiB。
  差分学習も既存 trie 全体を読み直すので、大きな差はない

コーパスは 10,000行で頭打ちにする(古い順に捨てる)。再学習コストと、
「打った内容がどこまで遡って残るか」の両方に上限をかけるため。

### 4. 世代ディレクトリで差し替える

**欠けた trie や書きかけの trie を読むと、エラーにならずプロセスが落ちる。**
実測 `0xC0000409`。marisa が C++ から throw し、エンジンの main までの間に
受ける者がいない。

なので再学習は変換器が読んでいるかもしれないファイルを**絶対に上書きしない**。

```
personal/
  corpus.txt
  base_*.marisa          ← 一度作ったら置き換えない
  gen-3/model_*.marisa   ← 現行世代
  gen-4.partial/         ← 学習中。ディレクトリ名が世代として parse されない
```

`gen-4.partial` に書き切ってから、**ディレクトリごと** `gen-4` に move する。
読み手からは「前の世代がまるごと見える」か「新しい世代がまるごと見える」かの
どちらかで、途中は見えない。新世代を公開してから旧世代を消す。

起動時は**番号の大きい順に、5ファイル揃っているものを探す**。
最大の番号を信用しないのは、ディレクトリを作った直後に落ちた実行があると
それを掴んでしまい、掴んだ瞬間に落ちるため。

### 5. 学習を切ったら記録も消す

`personalizationActive = learningEnabled && personalizationEnabled`。

個人化は変換器の学習ストア(不透明なデータベース)と違い、**確定した語句を
平文でディスクに置く**。性質が違うので設定も分けたが、
**学習を切れば個人化も切れる**(逆はない)。

そして切り替えを検知したらコーパスと学習済み世代を**消す**。共有端末で
学習を切る人は「もう見に行かない」ではなく「残さない」を求めている
(決定 0025)。

## 検証

`tsf/Ohagey/tools/build-and-run-personalization.ps1`

自分のプロファイルを汚さないよう、`LOCALAPPDATA` をスクラッチに向けてから
エンジンを起動する(エンジンは環境を継承する)。既にエンジンが動いていると
本物のプロファイルを掴んでいるので、その場合は実行を拒否する。

`swift test` は 107件パス(個人化まわりで +25)。

## 副産物として分かったこと

`EngineClient::Connect` の再試行は約1秒で、エンジンのコールドスタート
(辞書 + Zenzai の重み)はそれより明らかに長い。**再起動後の最初の変換が
空で返り、次の打鍵で通る**可能性がある。ハーネス側は待つようにしたが、
TSF クライアント本体は未対応。決定 0033 の範囲なので別途。

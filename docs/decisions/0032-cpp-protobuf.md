# 0032: TSF 側(C++)の Protobuf 実装方法

決定 0007 は IPC に Protobuf を使うと決めたが、**C++ 側で何を使って読み書きするか**は
決めていなかった。フェーズ2の着手時にここを詰める。

## 前提 — この DLL は全アプリのプロセスに入る

TSF テキストサービスは in-proc COM サーバーで、**メモ帳・Chrome・Word など、
ユーザーが文字を入力するあらゆるプロセスに読み込まれる**(決定 0002/0003)。
つまり依存ライブラリの大きさと初期化コストは、そのまま
「この IME を入れるとアプリが重くなる」という体験に直結する。
エンジン(`engine/`)が別プロセスで好きなだけライブラリを積めるのとは前提が違う。

## 決定事項 — `ohagey.proto` の範囲だけ手書きする

`libprotobuf` も `protobuf-lite` も nanopb も使わず、**このスキーマが必要とする
エンコーダ/デコーダだけを自前で書く**(`tsf/Ohagey/OhageyWire.cpp`)。

理由:

- **依存ゼロ。** 全プロセスに入る DLL に、数百KB〜数MBのライブラリと静的初期化を
  持ち込まずに済む。vendoring も CI のビルド手順追加も要らない。
- **必要な wire 形式が狭い。** `ohagey.proto` が使うのは varint と length-delimited
  だけで、group も map も packed repeated も使っていない。float / double すら無い。
- **スキーマが小さく安定している。** リクエスト4種・レスポンス4種と Status /
  Candidate / Segment のみ。決定 0007 で確定しており、頻繁に増える性質のものではない。

## 代償と、その担保

手書きの代償は **wire 形式のバグが自分たちの責任になる**こと。次の3つで担保する。

1. **実エンジンとの往復テスト。** `tsf/Ohagey/tools/` のハーネスが、実際に
   `OhageyEngine.exe` へ繋いで往復する。相手は Swift 側の生成コード
   (`swift-protobuf`)なので、**こちらの実装が間違っていれば必ず露見する**。
   自作エンコーダを自作デコーダで読み返すだけの自己満足テストにはしない。
2. **未知フィールドを正しく読み飛ばす。** スキーマが前に進んだとき、古い DLL が
   新しいエンジンの応答で壊れないこと。wire type 0/1/2/5 のスキップを実装する。
3. **Swift 側のマッピングテスト 23 件**(決定 0029)が、境界の扱いを既に固定している。

## やらないこと

- **`.proto` からの C++ 生成はしない。** 生成器を入れるなら nanopb を選ぶべきで、
  手書きの利点(依存ゼロ)が消える。代わりに `ohagey.proto` を変更したら
  `OhageyWire.cpp` も手で追随する必要がある。**このことをファイル先頭に明記する。**
- **汎用の Protobuf ライブラリは作らない。** 他のスキーマに使い回せる形にすると、
  結局 protobuf-lite を劣化再実装することになる。

## 追記(2026-08-04)— 手書きの読み手を試験した。**混在は例外ではなく毎回起きる**

この決定は「エンジン側は生成物、TSF 側は手書き」を選んだ。手書きの側に
**試験が1件も無かった。**

そして決定 0033 の追記6 で、混在が**避けられない**ことが分かっている:
インストーラが走った瞬間にエンジンは入れ替わり、**TSF DLL は再起動を待つ** —
テキスト入力面を持つ全アプリに読み込まれていて置き換えられないからである。
**その間、この機械上のすべての変換が「新しいエンジン × 古いクライアント」である。**
将来に備える隅の話ではなく、**更新のたびに全員に起きる。**

`tsf/Ohagey/tools/build-and-run-wire.ps1`(エンジンもパイプもプロファイルも要らない):

```
unknown varint field is skipped, later fields intact           ok
unknown length-delimited field is skipped, later fields intact ok
unknown fixed32 field is skipped, later fields intact          ok
unknown fixed64 field is skipped, later fields intact          ok
unknown field with a multi-byte tag is skipped                 ok
a truncated message is rejected                                ok
a length past the end is rejected                              ok
an empty message reads as empty, not as an error               ok
a known field with an unexpected type does not derail the rest ok
```

**未知フィールドの「後ろ」を見ているのが要点である。** 飛ばすバイト数を
読み違えても失敗はしない — **黙って後続を読み違える。** だから各ケースは、
未知フィールドの後ろに置いた既知フィールドが無傷であることを確かめている。

そして**飛ばすことが安全なのは、末尾を越えたことを検出できる場合だけ**である。
切り詰めと過大な長さ接頭辞を入れてあるのはそのためで、後者は
**利用者のアプリの中でバッファ外を読む**ことを意味する。

エンジン側にも同じ問いを立ててある(`WireForwardCompatibilityTests`)。生成物なので
構造上正しいが、**将来これを手書きに変える判断をしたときに性質が黙って落ちない**ように。

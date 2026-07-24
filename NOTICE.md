# サードパーティ表記(NOTICE)

おはぎー(本リポジトリ)はMITライセンスです。以下のサードパーティ資産に依存・vendoring・
ダウンロードしています。

## Microsoft SampleIME
- リポジトリ: https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME
- ライセンス: MIT(リポジトリ全体のライセンス表記に基づく。上流のLICENSEファイルを参照)
- 用途: `tsf/SampleIME/`にvendoringし、TSF(Text Services Framework)実装のベースとして
  大幅に改造して使用しています。

## AzooKeyKanaKanjiConverter
- リポジトリ: https://github.com/azooKey/AzooKeyKanaKanjiConverter
- ライセンス: MIT
- 用途: `engine/`のSwift Package依存として、かな漢字変換とZenzai連携を提供します。

## azooKey
- リポジトリ: https://github.com/azooKey/azooKey
- ライセンス: MIT
- 用途: おはぎーはazooKeyに着想を得た非公式・独立のWindows版です。azooKey本家との
  提携・公認関係はありません。

## Zenzaiモデルの重み(zenz-v3.1-small)
- 配布元: https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf
- 作者: Miwa Keita(三輪)氏
- ライセンス: **CC-BY-SA 4.0**(上記のMIT系コードとは別のライセンスです)
- 用途: 本リポジトリやインストーラーには同梱していません。初回起動時にHugging Faceから
  直接ダウンロードします(詳細は`docs/decisions/0008-model-distribution.md`を参照)。
  設定アプリの「このソフトウェアについて」画面に帰属表示を掲載します。

## 設計時に参考にした先行プロジェクト(コードの流用なし)
- [azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows)(fkunn1326版) — MIT
- [myime](https://github.com/unok/myime)(unok版) — Mozc型の共有サーバーアーキテクチャ、
  モデル配布方式の参考にしました

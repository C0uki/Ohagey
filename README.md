# おはぎー (Ohagey)

**おはぎー**は、[azooKey](https://github.com/azooKey/azooKey)のニューラルかな漢字変換エンジン
([AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) + **Zenzai**)を流用しつつ、
TSF(Text Services Framework)まわりはMicrosoft公式の
[SampleIME](https://github.com/microsoft/Windows-classic-samples/tree/main/Samples/IME)をベースに
ゼロから作り直した、非公式のWindows向け日本語IMEです。

> 🍡 プロジェクト名は「アズキー(azooKey)」→「おはぎ(小豆を使った和菓子)」+「ー」という語呂合わせです。
> 「あずきー」という元の呼び方の小豆つながりを引き継ぎつつ、井村屋の登録商標である「あずきバー」など
> 特定企業の商標は避けています。

このプロジェクトはazooKey本家、Microsoft、既存の
[azooKey-Windows](https://github.com/fkunn1326/azooKey-Windows)(fkunn1326版)、
[myime](https://github.com/unok/myime)(unok版)のいずれとも提携関係にありません。
両者の設計思想を参考にしつつ、独立して実装した新しいプロジェクトです。

## なぜ新しくWindows版を作るのか

azooKey自体はiOS・macOSではすでに快適に動いています。Windowsだけが手薄でした。
既存の有志による移植(azooKey-Windows)は現在更新が止まっているため、以下の方針で
新規に実装し直しています。

- **Zenzai**(AzooKeyKanaKanjiConverter経由)による高精度なニューラル変換はそのまま活用
- TSF層・UI・パッケージングは一から作り直す
- 低遅延な入力体験と、モダン(Fluent Design)な候補ウィンドウを優先する

## アーキテクチャ概要

```
┌──────────────────────────────┐        名前付きパイプ        ┌──────────────────────────────┐
│  tsf/ (C++、各アプリのプロセス内) │◄──────(Protobuf、ACL、───►│  engine/ (Swift、単一の共有     │
│  - TSF COM実装                  │        セッション単位)       │  サーバープロセス)              │
│    (SampleIMEをvendoring)       │                             │  - AzooKeyKanaKanjiConverter  │
│  - 候補ウィンドウ描画             │                             │    + Zenzai(CPU/CUDA/Vulkan)  │
│    (DirectWrite/DirectComposition、                            │  - オンデマンド起動、           │
│    Fluent Design)                                               │    アイドルタイムアウトで終了     │
│  - SEHでクラッシュを分離          │                             └──────────────────────────────┘
└──────────────────────────────┘
                │ 読み書き
                ▼
     %LOCALAPPDATA%\Ohagey\   (ユーザーごとの設定・学習データ・ユーザー辞書)

┌──────────────────────────────┐
│  settings-app/ (WinUI 3)      │  バックエンド選択、ユーザー辞書、学習データの
│  - レジストリ/設定ファイルに書き込み│  リセット、モデルの状態確認など
│    TSF/エンジン側が変更を検知し   │
│    自動反映                     │
└──────────────────────────────┘
```

各アーキテクチャ決定の詳しい経緯・理由は[`docs/decisions/`](docs/decisions)を参照してください
(TSFの選定理由、IPCの設計、モデル配布方式、ライセンス対応など、決定事項を一つずつ記録しています)。

## リポジトリ構成

| パス | 内容 |
|---|---|
| `tsf/` | C++のTSFテキストサービス(Microsoft SampleIMEをvendoring、大幅に改造) |
| `engine/` | Swift Package。AzooKeyKanaKanjiConverter + Zenzaiをラップする共有変換サーバープロセス |
| `settings-app/` | WinUI 3の設定アプリ |
| `installer/` | Inno Setupスクリプトとビルド関連資材 |
| `docs/decisions/` | アーキテクチャ決定ログ(主要な決定ごとに1ファイル) |
| `.github/workflows/` | CI: MSBuild(TSF)+ Swiftビルド(エンジン)+ Inno Setupパッケージング |

## 現在のステータス

🚧 まだ雛形段階です。アーキテクチャは確定済み、実装はこれから進めます。

## ライセンス

おはぎー自体のソースコードは[MITライセンス](LICENSE)です(本文は国際的な法的正確性のため英語のまま掲載しています)。

以下に依存・リンク・再配布しています。

- Microsoft SampleIME(Windows-classic-samples) — MIT
- AzooKeyKanaKanjiConverter / azooKey — MIT
- Zenzaiモデルの重み(`zenz-v3.1-small`、Miwa Keita氏作) — **CC-BY-SA 4.0**。
  初回起動時に別途ダウンロードするもので、本リポジトリやインストーラーには同梱していません。
  詳細は[`docs/decisions/0009-model-license.md`](docs/decisions/0009-model-license.md)を参照してください。

## プライバシー

おはぎーは、初回のモデルダウンロードを除き完全にオフラインで動作します。キー入力・変換履歴・
テレメトリなど、外部に送信されるデータは一切ありません。
詳しくは[`docs/decisions/0016-privacy.md`](docs/decisions/0016-privacy.md)を参照してください。

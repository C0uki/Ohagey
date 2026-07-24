# CLAUDE.md — Ohagey (おはぎー)

Windows向け日本語IME。azooKeyの変換エンジン(AzooKeyKanaKanjiConverter + Zenzai)を
流用し、TSF層・UI・配布まわりは新規実装。設計の全経緯は `docs/decisions/README.md`
に決定事項一覧がある。実装前に必ず目を通すこと。

## アーキテクチャ概要

```
tsf/ (C++, 各アプリのプロセス内)  ──名前付きパイプ(Protobuf)──  engine/ (Swift, 単一の共有サーバープロセス)
     │                                                                  │
     │ SEHでクラッシュを握りつぶす                          AzooKeyKanaKanjiConverter + Zenzai
     │ DirectWrite/DirectCompositionでFluent Design描画        CPU/CUDA/Vulkanをユーザーが選択可
     │                                                          オンデマンド起動・アイドルタイムアウト終了
     ▼
%LOCALAPPDATA%\Ohagey\ (学習データ・ユーザー辞書、ユーザーごと)

settings-app/ (WinUI 3) ──registry/設定ファイル(変更通知で自動反映)──→ tsf/ と engine/
```

## 絶対に守ること

- **完全オフライン動作**。インストール時のモデルダウンロード以外、一切の外部通信をしない(decision 0016)
- **TSF DLL側は必ずSEHで例外を握りつぶす**。ホストアプリ(メモ帳、Chrome等)をクラッシュさせない(decision 0017)
- **x64のみ**対応。ARM64は範囲外(decision 0018)
- **Zenzaiモデル(CC-BY-SA 4.0)はリポジトリにコミットしない**。実行時ダウンロードのみ(decision 0008/0009)
- 名前付きパイプは**セッションID込みの命名**、**AppContainer/管理者権限プロセスからの接続を許可するACL**を必ず設定する(decision 0006)

## ディレクトリと役割

| パス | 言語/技術 | 役割 |
|---|---|---|
| `tsf/` | C++ (MSBuild) | TSF実装(SampleIMEをvendoring・改造)、候補ウィンドウ描画 |
| `engine/` | Swift (SPM) | 変換エンジン本体、名前付きパイプサーバー |
| `settings-app/` | WinUI 3 (.NET) | バックエンド切替、学習データ管理、ユーザー辞書UI |
| `installer/` | Inno Setup | インストーラー、モデルダウンロード呼び出し |
| `docs/decisions/` | Markdown | 設計判断ログ(なぜそう決めたかの記録) |

## 現在のステータス

🚧 雛形のみ。`tsf/SampleIME/`は未取り込み(手順は`tsf/README.md`参照)。実装はまだ始まっていない。

## 次にやること候補

1. `tsf/README.md`の手順に従い、SampleIMEをvendoring
2. `engine/`のIPC用Protobufスキーマ(`.proto`)を定義(decision 0007)
3. `engine/Sources/OhageyEngine/main.swift`の`TODO`から実装開始

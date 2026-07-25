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

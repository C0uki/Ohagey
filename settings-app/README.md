# settings-app/ — WinUI 3設定アプリ(決定0013)

予定している画面:

- **バックエンド**: CPU / CUDA / Vulkanの選択(決定0010)、モデルの状態表示
  (ダウンロード済み/未取得/再ダウンロードボタン、決定0008/0009)
- **学習**: 有効/無効の切り替え、「学習データを消去」ボタン(決定0025)。対象は
  `%LOCALAPPDATA%\Ohagey\`(決定0024)
- **ユーザー辞書**: 単語の追加・編集・削除(決定0026)。ファイルは
  `%LOCALAPPDATA%\Ohagey\userdict.tsv` のタブ区切りテキスト(決定0036)。
  形式は [`docs/decisions/0036-user-dictionary-format.md`](../docs/decisions/0036-user-dictionary-format.md)。
  **読みはかなのみ**(引き当てがかなで行われるため、漢字の読みは決して一致しない)。
  品詞は ASCII の固定キーで、UI の表示名とは別物として扱うこと。
  このアプリがファイルを直接書き換えてよい — エンジンは変換のたびに mtime を見て読み直す
- **このソフトウェアについて**: バージョン情報、ライセンス一覧、Zenzaiモデルの帰属表示
  (`docs/decisions/0009-model-license.md`を参照)

設定は **`HKEY_CURRENT_USER\Software\Ohagey`** に書き込み、エンジンがキーを監視して
自動反映します(決定0014 / **0035**)。このアプリ自体が起動中のエンジンプロセスと
直接通信することはありません。

書き込む値の一覧・型・範囲は
[`docs/decisions/0035-settings-schema.md`](../docs/decisions/0035-settings-schema.md)。
実装時に気をつけること:

- **`PersonalizationAlphaPercent` はパーセント**(0〜100 の DWORD)。レジストリに
  浮動小数点型が無いため。UI 側が 0.15 をそのまま書くと 100 倍ずれる
- `IdleTimeoutSeconds` の **0 は「アイドル終了しない」**という意味であって、
  「すぐ終了する」ではない
- `Backend` と `IdleTimeoutSeconds` は**エンジンの再起動が要る**。エンジンはログに
  そう出すが、**UI にも明示すること**(決定0028)。変更しても何も起きないように
  見えると、ユーザーは設定が壊れていると判断する
- エンジンは**このキーに値を書かない**。書くのはこのアプリだけ
- 「学習データを消去」の対象には、`%LOCALAPPDATA%\Ohagey\personal\`
  (個人化のコーパスと学習済みモデル、決定0034)も**含める**こと

🚧 まだWinUI 3プロジェクトとして雛形化していません。実装開始時に`dotnet new winui3`
(または同等のテンプレート)で追加予定です。

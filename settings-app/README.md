# settings-app/ — WinUI 3設定アプリ(決定0013)

画面:

- **バックエンド**: CPU / CUDA / Vulkanの選択(決定0010)、モデルの状態表示
  (ダウンロード済み/未取得/再ダウンロードボタン、決定0008/0009)
- **学習**: 有効/無効の切り替え、「学習データを消去」ボタン(決定0025)。対象は
  `%LOCALAPPDATA%\Ohagey\`(決定0024)
- **ユーザー辞書**: 単語の追加・編集・削除(決定0026)
- **このソフトウェアについて**: バージョン情報、ライセンス一覧、Zenzaiモデルの帰属表示
  (`docs/decisions/0009-model-license.md`を参照)

設定は **`HKEY_CURRENT_USER\Software\Ohagey`** に書き込み、エンジンがキーを監視して
自動反映します(決定0014 / 0035)。このアプリ自体が起動中のエンジンプロセスと
直接通信することはありません。

## 構成

```
src/Ohagey.Settings.Core/     UI に依存しないロジック(単体テスト 54件)
src/Ohagey.Settings/          WinUI 3 の画面
tests/Ohagey.Settings.Core.Tests/
```

エンジン側と同じ分け方をしている。**設定スキーマ(決定0035)と辞書フォーマット
(決定0036)は Swift と C# の二重実装**で、ずれても**ビルドは通りクラッシュもしない** —
「設定を変えても何も起きない」「登録した単語が変換されない」という静かな壊れ方をする。
`SchemaAgreementTests.cs` が値名・型・範囲・既定値を決定文書に対して固定している。

## ビルド

**ロジックとテストだけなら `dotnet` で足りる:**

```
dotnet test tests/Ohagey.Settings.Core.Tests/Ohagey.Settings.Core.Tests.csproj
```

**WinUI 本体は Visual Studio の MSBuild で建てること。** `dotnet build` は PRI 生成の
タスクを持っておらず MSB4062 で落ちる。**Restore と Build は別々に呼ぶ**
(1回にまとめるとクリーン後の初回だけ失敗する)。詳細と、実機で踏んだ落とし穴は
[`docs/local-setup.md`](../docs/local-setup.md) にまとめてある。

```
msbuild src\Ohagey.Settings\Ohagey.Settings.csproj -t:Restore -p:Configuration=Release -p:Platform=x64
msbuild src\Ohagey.Settings\Ohagey.Settings.csproj -t:Build   -p:Configuration=Release -p:Platform=x64
```

## 実装時の注意

- **`PersonalizationAlphaPercent` はパーセント**(0〜100 の DWORD)。UI 側が 0.15 を
  そのまま書くと 100 倍ずれる
- `IdleTimeoutSeconds` の **0 は「アイドル終了しない」**であって「すぐ終了する」ではない
- `Backend` と `IdleTimeoutSeconds` は**エンジンの再起動が要る**。UI にも明示すること
  (決定0028)。変更しても何も起きないように見えると、設定が壊れていると判断される
- エンジンはこのキーに値を書かない。書くのはこのアプリだけ
- **「学習データを消去」は `userdict.tsv` を消さない。** 意図して登録した語であって
  学習ではない(決定0026)

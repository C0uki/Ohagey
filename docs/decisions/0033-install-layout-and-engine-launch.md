# 0033: インストール配置と、エンジンのオンデマンド起動

決定 0015 は「最初のクライアントが未起動ならエンジンを起動する」と決めていたが、
**どこにある実行ファイルを起動するのか**が未確定だったため実装できずにいた。
ここを詰めて、決定 0015 を実装可能にする。

これが解けないと**製品として動かない**。TSF クライアントはエンジンが既に起動して
いなければ繋がれず、ユーザーが手動で起動する運用は成り立たない。

## インストール配置

```
%ProgramFiles%\Ohagey\
    OhageyTSF.dll                       TSF テキストサービス(regsvr32 で登録)
    OhageyEngine.exe                    変換サーバー(決定 0004)
    OhageySettings.exe                  設定アプリ(決定 0013)
    models\
        ggml-model-Q5_K_M.gguf          Zenzai の重み(決定 0008)
    backends\
        cpu\    llama.dll ggml*.dll     決定 0028
        cuda\   ...
        vulkan\ ...
```

`%ProgramFiles%` 配下なのは既に決まっている(決定 0008 のモデル配置)。
**DLL と exe を同じディレクトリに置く**のがこの決定の実質的な中身。

> **DLL は `OhageyTSF.dll` としてビルドされる**(対応済み)。`.vcxproj` に
> `TargetName` を足しただけで、プロジェクト名・ディレクトリ・GUID は vendoring 元の
> `SampleIME` のまま残してある — それらを改名すると、コードの変更が移動に埋もれて
> 取り込み元との差分が読めなくなるため(決定 0021)。
> `.def` の `LIBRARY` と `.rc` の `VERSIONINFO` も出荷名・出荷者に合わせた
> (それ以前は Microsoft のサンプルを名乗ったままだった)。
> 起動処理は「自分の隣の `OhageyEngine.exe`」を見るので、いずれにせよ DLL の
> 名前には依存しない。

## エンジンの場所は DLL からの相対で解決する

TSF DLL は自分自身のパス(`GetModuleFileNameW`)を取り、同じディレクトリの
`OhageyEngine.exe` を起動する。

レジストリに絶対パスを書く案は採らない。

- **状態が増えない。** レジストリ値とファイル配置が食い違う可能性を作らない。
  インストーラのバグやユーザーのフォルダ移動で「登録されているが存在しない」
  状態になり得る。
- **DLL と exe は同時に配布される。** 別々の場所に置かれる理由が無い以上、
  相対で足りる。
- **読み取り権限の問題が無い。** AppContainer から HKLM を読む話をしなくて済む。

## 起動の作法

- `CreateProcessW`、`CREATE_NO_WINDOW | DETACHED_PROCESS`。
  ホストアプリのコンソールやジョブに紐づけない。エンジンは**起動元より長生きする**
  (決定 0015 のアイドルタイムアウトで自分で終わる)。
- ハンドルは継承させない。ホストアプリのハンドルをエンジンに渡す理由が無い。
- **同時起動は放置してよい。** 複数のアプリが同時に起動を試みても、
  `FILE_FLAG_FIRST_PIPE_INSTANCE`(決定 0031)で負けた側が
  `pipeNameAlreadyOwned` として即座に終了する。排他を自前で持つ必要が無い。

## 起動後に待たない

起動してもパイプはすぐには現れない(エンジンは辞書を読んでから listen する)。

**打鍵スレッドを数秒止めるのは論外**なので、起動を投げたら短時間だけ様子を見て、
繋がらなければ諦めて戻る。次の打鍵で再試行すれば、2〜3打鍵目には繋がる。
最初の1〜2打鍵が変換されないのは、IME が数秒固まるよりはるかにましな失敗。

## 暴走させない

エンジンが起動直後に落ち続ける状態だと、素朴に書けば**打鍵ごとにプロセスを生成する**。
起動の試行には間隔(数秒)を設ける。

## 開発用の上書き `OHAGEY_ENGINE_PATH`

開発中は DLL の隣にエンジンが無い。パスを上書きできるようにするが、
**`OHAGEY_ALLOW_ENGINE_PATH_OVERRIDE` を定義してビルドしたときだけ**有効にする。
DLL のプロジェクトはこれを定義しないので、出荷される DLL にはコードごと存在しない。

決定 0008 の `OHAGEY_MODEL_PATH` より厳しくしているのは、**こちらは任意のコードを
実行させる穴**だから。読むモデルを選ばせるのとは危険度が違う。実行時フラグではなく
コンパイル時に落とす。

## 追記(2026-08-04)— インストーラの `[Files]` を実物と突き合わせた。3件中2件が間違っていた

`iscc` を通す前に、`installer/ohagey.iss` の `[Files]` が指しているパスが**実際の
ビルド成果物と一致するか**を確認した。ずっとコメントアウトされたままだったので、
誰も確かめていなかった。

| 対象 | 書いてあったパス | 実際 |
|---|---|---|
| TSF DLL | `..\tsf\SampleIME\x64\Release\OhageyTSF.dll` | ✅ 正しい(実物を確認) |
| エンジン | `..\engine\.build\release\OhageyEngine.exe` | ❌ **存在しない** |
| 設定アプリ | `..\settings-app\bin\x64\Release\OhageySettings.exe` | ❌ **場所も形も違う** |

### エンジン — `.build\release` はシンボリックリンクで、作成に失敗する

SwiftPM は `.build\release` を**アーキテクチャ三つ組ディレクトリへのシンボリック
リンク**として作る。Windows でシンボリックリンクを作るには開発者モードか昇格が要り、
**普通の環境では失敗する**。この機械でも毎回こう出ている:

```
warning: unable to create symbolic link at <...>\.build\release:
encountered an I/O error (code: 512)
```

そしてディレクトリは残らない。リンクの名前で参照すると、**リンクを作れない機械
——つまり大半——でパッケージングが失敗する**。

`..\engine\.build\x86_64-unknown-windows-msvc\release\OhageyEngine.exe` に直した。

### 設定アプリ — ファイル1つではなくディレクトリ

`Ohagey.Settings.csproj` は `RuntimeIdentifier=win-x64` かつ
`WindowsAppSDKSelfContained=true` なので、出力は**アプリと Windows App Runtime の
一式**(数十ファイル)になる。`OhageySettings.exe` だけを入れると、
**起動できないものをインストールすることになる**。

しかも self-contained にしたのは、まさに「インストール後にランタイムの
ダウンロードを訊きにいかせない」ため(決定 0016)だった。1ファイルだけ入れると
その目的ごと失われる。

パスも違っていた。プロジェクトは `settings-app\src\Ohagey.Settings\` にあり、
TFM と RID がパスに入る:

```
..\settings-app\src\Ohagey.Settings\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\*
```

`Flags: recursesubdirs createallsubdirs` を付けてディレクトリごと入れるようにした。

### まだ通していない

`iscc` はこの機械に入っていないので、**コンパイルは確認できていない**。
`[Files]` の行はコメントのままである。確かめたのは「パスが実在するか」までで、
「Inno がこれを受け付けるか」はまだ。

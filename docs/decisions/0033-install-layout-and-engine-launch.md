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

## 追記(2026-08-04、その2)— `iscc` を通した。`AppId` が仮のままだった

Inno Setup 6.7.3 を入れて `installer/ohagey.iss` をコンパイルした。**通る。**
`ohagey-setup.exe`(2.00 MB)が出来る。

> `winget install JRSoftware.InnoSetup` は **`%LOCALAPPDATA%\Programs\Inno Setup 6\`**
> に入る。`C:\Program Files (x86)\Inno Setup 6\` を探しても無い。

### `AppId` を確定させた

`AppId={{REPLACE-WITH-GENERATED-GUID}}` のままだった。**Inno はこれをエラーにしない** —
リテラル文字列として受け取り、そのままコンパイルが通る。

`AppId` は Windows が「既存のインストール」を見分けるための識別子である。仮の値のまま
出荷して後で変えると、**更新が更新にならず、2つ目のおはぎーが並んで入る。**
一度きり生成して固定した:

```
AppId={{FA549B8C-7981-4ABE-A7CC-1F7DC99E15E7}
```

(二重の `{` は Inno のエスケープで、リテラルの `{` を意味する。)

`MyAppURL` の `REPLACE_ME` も実際のリポジトリに直した。

### 有効にしたもの / まだコメントのままのもの

**有効:**

- `[Files]` の `download-model.ps1` — リポジトリに実在するファイルで、ビルド成果物では
  ないため
- `[Run]` の6行すべて — zenz の重み1件と base LM の5件。リリース資産が公開されたので
  URL が実在するようになった

**コメントのまま:** TSF DLL / エンジン / 設定アプリ / バックエンド DLL。
いずれもビルド成果物で、CI でそれらを作る段取りが要る。

いまの `ohagey-setup.exe` は「`download-model.ps1` を入れて、モデル5件+重みを
取得する」ところまでを行う。**アプリ本体はまだ入らない。**

### まだやっていない

- [ ] **実際にインストールしてみる。** `%ProgramFiles%\Ohagey\` に書き、80MB を
      取得する。この機械の状態を変えるので指示待ち
- [ ] CI で `iscc` を回す

## 追記(2026-08-04、その3)— 実際にインストールして、出荷構成で通した

`ohagey-setup.exe` を `/VERYSILENT` で実行した(`PrivilegesRequired=admin` なので
UAC の承認が要る)。終了コード 0。

### 入ったもの — 84.1 MB

```
download-model.ps1                0.01 MB
models\ggml-model-Q5_K_M.gguf    70.45 MB
models\lm_c_abc.marisa            3.22 MB
models\lm_c_bc.marisa             1.78 MB
models\lm_r_xbx.marisa            0.77 MB
models\lm_u_abx.marisa            1.75 MB
models\lm_u_xbc.marisa            1.90 MB
models\download.log
unins000.exe                      4.25 MB
```

`download.log` の1行目が効いている:

```
ggml-model-Q5_K_M.gguf : already present and matches -- nothing to do
```

70MB の重みは既にあったので**ハッシュを確認して飛ばした**。再インストールや修復で
毎回落とし直さない、という設計が実物で効くことの確認になった。

### 出荷構成での実測 — **release ビルド、環境変数の上書きなし**

これまでの個人化の測定はすべて debug ビルド + `OHAGEY_BASE_LM_PATH` だった。
インストーラが `%ProgramFiles%\Ohagey\models\` に base を置いたことで、
**初めて出荷そのものの構成で測れる**ようになった。

```
base language model: present (installed, C:\Program Files\Ohagey\models\lm)

=== 学習ストアのみ(個人化オフ)===   服を切る   2位 → 2位
=== 学習ストア + 個人化 ===          服を切る   2位 → 1位
```

評価セット32件: `correct at rank 1: 30 -> 30 of 32 (broke 0, fixed 0)`、`ALL PASSED`。

**debug + 環境変数で測ってきた結果が、release + 実インストールでそのまま出る。**

### 既定オンが実際に効くことの確認

`HKCU\Software\Ohagey` を**丸ごと消して**(=まっさらな利用者と同じ状態)release の
エンジンを起動した:

```
OhageyEngine: settings loaded (learning=true, backend=cpu)
OhageyEngine: personalisation: using the installed base language model
OhageyEngine: personalisation: no trained model yet
OhageyEngine: personalisation: generation 1 published (3 lines, 8818ms)
OhageyEngine: personalisation: deferring the next training run by 79s to stay under 10% of the machine
```

- 設定キーが1つも無い状態で**個人化が動いている** — 既定オンが実際に効いている
- 8,818ms は 9.4MB の base に対する予測(7.9秒)どおり
- **duty cycle も実物で効いている** — 次の学習を79秒遅らせている

### アンインストール

`%ProgramFiles%\Ohagey\unins000.exe`、または「アプリと機能」から。
学習データは `%LOCALAPPDATA%\Ohagey\` にあり、これは消えない(決定 0024 / 0025 —
消すのは設定アプリの「学習データを消去」)。

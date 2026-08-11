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

## 追記(2026-08-04、その4)— 全部入りで組んで登録した。**黙って外れていた2件**

TSF DLL・エンジン・設定アプリを実際にビルドして `[Files]` を有効にし、
`iscc` で 28MB のインストーラを作って入れた。**そこで初めて分かったことが2件ある。
どちらもビルドもインストールも成功したまま外れていた。**

### 1. 🔴 IME が**中国語**として登録されていた

```
HKLM\SOFTWARE\Microsoft\CTF\TIP\{D2291A80-...}\LanguageProfile\
  0x00000804   Description=Sample IME
```

`0x0804` は簡体字中国語である。vendoring 元の SampleIME は**中国語の拼音サンプル**で、
`Define.h` がそのまま残っていた:

```c
#define TEXTSERVICE_LANGID  MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED)
static const WCHAR TEXTSERVICE_DESC[] = L"Sample IME";
```

**どこもエラーにならない。** ビルドは通り、`regsvr32` は成功し、CLSID はレジストリに
載り、TIP も登録される。ただ**日本語の入力方式一覧には永久に出てこない** —
そこに登録されていないので。

日本語に直した:

```c
#define TEXTSERVICE_LANGID  MAKELANGID(LANG_JAPANESE, SUBLANG_JAPANESE_JAPAN)
static const WCHAR TEXTSERVICE_DESC[] = L"おはぎー";
```

直後の再インストールで `0x00000411  Description=おはぎー` を確認した。

> ⚠️ `DllUnregisterServer` は**コンパイル時の LANGID** で登録解除するので、
> LANGID を変えると前の登録が孤児になる。この機械には
> `0x0804 / Sample IME` が残っている(削除には昇格が要る)。
> 出荷前に変えたので、利用者には起きない。

### 2. 🔴 自前のバイナリが再インストールで**永久に更新されない**

`Define.h` を直して再ビルドし、入れ直したのに、**登録されたのは古い DLL のまま**だった。
インストール先のハッシュが変わっていなかった。

Inno はバージョン資源を比べて「新しくない」ファイルの上書きを飛ばす。
**おはぎーのバイナリはどれもバージョンを上げない** — TSF DLL は vendoring 元の
バージョン資源をそのまま持ち、Swift のエンジンには資源が無く、設定アプリのものも
ビルドで動かない。つまり**最初のインストールが永久に勝つ。**

ログには何も出ない。「上書きを飛ばした」という行が無いまま、そのあとの
`regsvr32` が**古いビルドを登録する。**

自前の成果物すべてに `ignoreversion` を付けた。付けた直後に DLL が置き換わり、
日本語プロファイルが出た。

### GPU バックエンドはパッケージ時に選ぶ

`backends\cuda` は **977MB**(cpu は 2.4MB)で、大半はベンダーランタイムである。
既定で同梱すると、多くの機械で使えない機能のためにインストーラが 1GB を超える。

```
iscc /DGpuBackends installer\ohagey.iss
```

`skipifsourcedoesntexist` も付けてある。`fetch-backends.ps1` は求められたものしか
取ってこないので、define を渡すことが「全部取得済みであること」を要求すべきではない。

### 入ったもの

| | |
|---|---|
| インストーラ | **28.0 MB**(GPU バックエンド無し) |
| 展開後 | **212.2 MB** |

内訳の大半は設定アプリの自己完結 WinUI ランタイム(約 96MB)とモデル(約 80MB)。

### まだやっていない — 実際に打つ

登録はできたが、**日本語の入力方式一覧に追加して切り替える**のは利用者ごとの設定
変更なので、そこは手を出していない。実際にメモ帳で打つのはその先である。

## 追記(2026-08-04、その5)— 実際に打ってもらった。**1打鍵ごとにフル変換していた**

インストールして日本語の入力方式に追加し、メモ帳で打ってもらった。

**打てて、入る。** TSF → 名前付きパイプ → エンジン → 変換 → 確定が実アプリで通った。
エンジンは `C:\Program Files\Ohagey\OhageyEngine.exe` として **メモ帳の中から起動された**
— 決定 0015 のオンデマンド起動が実機で成立している。

そして最初の使用感が2つ返ってきた: **「変換が一回限り」「若干もっさり」**。

### もっさりの原因 — 打鍵ごとの変換

`_HandleCompositionInputWorker`(合成中の文字入力パス)が、キーを1つ処理するたびに
`GetCandidateList` を呼び、それがそのまま `Convert` としてエンジンへ飛んでいた。

これは vendoring 元がピンイン IME だからである。ピンインには**役に立つ中間形が無い**
ので、常に候補一覧から選ぶ。日本語には中間形がある — 画面のかな — そして変換は
利用者が**頼む**ものである。

残しておいたのは様式の問題ではなく、速度の問題だった:

| | |
|---|---|
| 1変換の実測 | **137ms**(release / CPU) |
| `nihongo` と打つ | **7回** |
| 数語打った後のエンジンの CPU | **12.1秒** |

決定 0034 で候補順の振動を直したとき、`ConversionService.convert` は毎回
`stopComposition()` してラティスを作り直すようにした。あのとき「1打鍵ずつ渡す
キーボードには正しく、ここでは間違っている」と書いたのは**エンジン側**の話だったが、
**TSF 側は実際に1打鍵ずつ渡していた。** 両側を見て初めて噛み合っていないと分かる。

`_HandleCompositionInputWorker` から候補取得を外した。かなを見せて、訊かれるまで待つ。
変換は `_HandleCompositionConvert`(変換キー)が行う。

前の変換で開いたままの候補窓は空にする — 読みがその下で変わってしまっており、
出ているのは誰も訊いていない質問への答えだからである。

### 「変換が一回限り」はまだ説明できていない

痕跡だけはある。実セッションのあと `%LOCALAPPDATA%\Ohagey\personal\corpus.txt` が
**存在しなかった** — 確定がエンジンの `record` まで届いていない。
`NotifyCommitted` は**候補一覧から確定した経路でしか呼ばれない**
(`KeyHandler.cpp` の一方の分岐のみ)。ただしこれが原因かは確かめていない。

### 診断できない理由 — **DLL から起動したエンジンのログが残らない**

エンジンは `print` で標準出力に書くだけなので、TSF DLL が起動した実セッションでは
どこにも残らない。このリポジトリが何度も踏んできた「見えない失敗」と同じ形で、
いま実機の診断がそれで止まっている。

- [ ] **エンジンのログをファイルにも書く**(`%LOCALAPPDATA%\Ohagey\engine.log`)。
      実機での診断はこれが無いと始まらない
- [ ] ログが取れたら「一回限り」を再現して原因を特定する

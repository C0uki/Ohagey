# 0031: パイプ ACL の確定(決定 0006 の改訂)

決定 0006 で「AppContainer と管理者権限プロセスからの接続を許可する ACL を設定する」
とだけ決めていたものを、セキュリティレビューを経て確定させる。
これをもって roadmap / CLAUDE.md の「**ACL はセキュリティレビュー未実施**」をクローズする。

## 見直し前の ACL とその問題

```
D:(A;;GRGW;;;WD)(A;;GRGW;;;AC)S:(ML;;NW;;;LW)
```

| 問題 | 内容 |
|---|---|
| **`WD`(Everyone)** | マシン上の**全アカウント**に許可していた。同一マシンの別の対話ユーザーからも到達できる |
| **`GW`(GENERIC_WRITE)** | パイプにおいて `GENERIC_WRITE` は **`FILE_CREATE_PIPE_INSTANCE`(`FILE_APPEND_DATA` と同じビット 0x4)を含む**。これを持つクライアントは**同じパイプ名のインスタンスを自分で立てて他のアプリに応答できる**。IME でこれは、他アプリへの入力を丸ごと読めるということ |
| **リモート接続** | SMB 経由の接続を拒否していなかった |
| **名前の先取り** | 先に同名パイプを作った側が「おはぎーのエンジン」になりすませた |

## 確定した ACL

```
D:(A;;0x12019F;;;<現在のユーザーSID>)(A;;0x100183;;;SY)(A;;0x100183;;;BA)(A;;0x100183;;;AC)S:(ML;;NW;;;LW)
```

ユーザー SID は実行時に `OpenProcessToken` → `GetTokenInformation(TokenUser)` →
`ConvertSidToStringSidW` で取得する(**ハードコードしない** — 許可するのは
「ログイン中の誰か」ではなく「このプロセスを動かしているユーザー」)。

| トラスティ | マスク | 理由 |
|---|---|---|
| 現在のユーザー SID | `0x12019F` | エンジン自身がここで動く。後述の「狭められなかった理由」を参照 |
| `SY`(LOCAL SYSTEM) | `0x100183` | 元々プロセスの乗っ取りが可能なので拒否しても意味が無い。サービス経由のクライアントを壊さないために許可 |
| `BA`(Administrators) | `0x100183` | 同上(昇格プロセスからの入力) |
| `AC`(ALL APPLICATION PACKAGES) | `0x100183` | UWP / ストアアプリは AppContainer で動くため、これが無いと日本語入力が一切できない。**`FILE_CREATE_PIPE_INSTANCE` は与えない** |

マスクの内訳:

- `0x100183` = `FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE`
- `0x12019F` = 上記 + `FILE_CREATE_PIPE_INSTANCE | FILE_READ_EA | FILE_WRITE_EA | READ_CONTROL`

どちらも `DELETE` / `WRITE_DAC` / `WRITE_OWNER` を含まない。

### SACL(低整合性ラベル)は維持する

`S:(ML;;NW;;;LW)` は残す。**AppContainer プロセスは低整合性で動く**ため、
これが無いと上の `AC` ACE で許可した先が整合性チェックで弾かれ、
結局 UWP アプリが使えなくなる。

## サーバー用マスクを狭められなかった理由(重要)

当初はユーザー ACE も `0x100183` に狭めたが、**2本目の接続でエンジンが落ちた**
(`ERROR_ACCESS_DENIED`)。

accept ループは接続ごとにインスタンスを作るが、**2本目以降の
`CreateNamedPipeW` は既存パイプの DACL に対してアクセスチェックされる。
サーバーは自分の ACL の例外ではない。** `PIPE_ACCESS_DUPLEX` は
`FILE_GENERIC_READ | FILE_GENERIC_WRITE` + `FILE_CREATE_PIPE_INSTANCE` を要求し、
チェックは**全ビット**を要求するため、`FILE_READ_EA` が欠けているだけでも失敗する。
これが `0x12019F` の由来。

⚠️ **その帰結を正確に書いておく。** エンジンはログイン中のユーザーとして動き、
各ホストアプリ内の TSF クライアントも同じユーザーとして動く。DACL は同一ユーザーの
2つのプロセスを区別できない。したがって `FILE_CREATE_PIPE_INSTANCE` を含むこの ACE は
**そのユーザーの全プロセスから使える**。つまり同一ユーザーの別プロセスは、
我々のパイプにインスタンスを追加して他のアプリに応答できてしまう。

これは受け入れる。同一ユーザーのプロセスは、そもそも我々のメモリを読み、スレッドを注入し、
実行ファイルを差し替えられる。**Windows がここで引かせてくれる境界ではない**ので、
引けたふりをする方が有害だと判断した。この ACL が実際に守る境界は、
**別ユーザー・AppContainer クライアント・ネットワーク**の3つ。

## パイプ作成フラグ

| フラグ | 目的 |
|---|---|
| `PIPE_REJECT_REMOTE_CLIENTS` | SMB 経由の接続を拒否。ネットワークから届く IME は、住所を公開したキーロガーに等しい |
| `FILE_FLAG_FIRST_PIPE_INSTANCE`(**最初の1本のみ**) | 名前が既に存在するなら失敗させる。他人のパイプに黙ってインスタンスを足さない |

`FILE_FLAG_FIRST_PIPE_INSTANCE` が失敗したときは `pipeNameAlreadyOwned` として
**エンジンを終了させる**。これは2つのケースを区別できないが、どちらでも終了が正しい:

- **別のエンジンが起動競争に勝った** — 決定 0015 が求める「1つだけ」が実現している状態
- **なりすまし目的で名前を先取りされた** — 相手のパイプに自分のインスタンスを足すのが最悪の結果

## クライアント側への制約(フェーズ2の TSF 実装で必ず守ること)

**`CreateFileW` を `GENERIC_READ | GENERIC_WRITE` で呼んではいけない。**
これは `FILE_CREATE_PIPE_INSTANCE` を含むところまで展開され、
アクセスチェックは要求した全ビットを要求するため、AppContainer クライアントは
接続に失敗する。要求する権限を明示すること:

```
FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE
```

(= `0x100183`。`PipeSecurity.clientAccessMask` と同じ値)

## 実機で確認済み

| 検証 | 結果 |
|---|---|
| 明示権限(`0x100183`)での接続 | 成功 |
| `GENERIC_READ \| GENERIC_WRITE` での接続 | **拒否**(意図通り) |
| 連続3接続 + 変換リクエスト | すべて成功、エンジン生存(サーバー用マスクの検証) |
| 2重起動 | 2つ目が `pipeNameAlreadyOwned` で exit code 1、1つ目は無事 |

## 残課題

- **`AC` だけで足りるかは未確認。** LPAC(Less Privileged AppContainer)クライアントには
  `S-1-15-2-2`(ALL RESTRICTED APPLICATION PACKAGES)も要る可能性がある。
  実クライアントが必要とした時点で追加する(不要な許可を先に入れない)。
- **UWP アプリからの実接続は未検証。** AppContainer が低整合性であることは
  Windows の仕様上の挙動から判断しており、実機で測ってはいない。
  フェーズ2で TSF を UWP アプリに読ませた時点で確認すること。

## 実装

- `engine/Sources/OhageyEngineCore/PipeSecurity.swift` — マスクと SDDL の組み立て。
  WinSDK 非依存にしてあるのは、**「後から誰かが利便性のために許可を広げても誰も気づかない」**
  という壊れ方をテストで止めるため(`PipeSecurityTests`、12件)。
- `engine/Sources/OhageyEngine/PipeServer.swift` — SID 取得、パイプ作成フラグ。

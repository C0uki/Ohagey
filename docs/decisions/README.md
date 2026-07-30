# アーキテクチャ決定ログ

おはぎーで決めてきた主要なアーキテクチャ決定を、決定した順に記録しています。理由の詳細を
別ファイルにまとめたものはリンクしています。それ以外はここでの要約が全記録です。

| # | 決定事項 | 結論 |
|---|---|---|
| 0001 | 基本方針 | Zenzai変換エンジン(AzooKeyKanaKanjiConverter)のみ流用し、TSF・UI・パッケージングは一から作り直す |
| 0002 | TSFのベース | Microsoft SampleIME(Windows-classic-samples)をvendoringし、大幅に改造 |
| 0003 | TSF実装言語 | C++(Swiftではない — SwiftのCOM対応は「消費する」側では実績があるが、TSFのような多数のサーバー側COMインターフェースを「実装する」側では前例が少ないため) |
| 0004 | エンジンのプロセス構成 | in-proc DLLではなく、単一の共有サーバープロセス(Mozc型) — Zenzaiのメモリ/GPU使用量を考慮した結果、必須と判断 |
| 0005 | エンジン実装言語 | Swift単体でサーバープロセス全体を実装(C++/SwiftのFFI境界は、エンジンを別プロセス化した時点で不要になったため撤廃) |
| 0006 | IPCの通信方式 | 名前付きパイプ。セッションID込みの命名、AppContainer/管理者権限プロセス向けの明示的なACL設定 |
| 0007 | IPCのメッセージ形式 | Protocol Buffers(Mozcの実績ある方式に準拠) |
| 0008 | [モデル配布方式](0008-model-distribution.md) | インストーラー(Inno Setup)がインストール時にHugging Faceから直接ダウンロード。失敗してもインストールは成功させ、辞書ベース変換にフォールバック |
| 0009 | [モデルのライセンス対応](0009-model-license.md) | zenz-v3.1-smallはCC-BY-SA 4.0。別ファイルとしてダウンロードし、おはぎー本体のMITコードとは分離。帰属表示を必須化 |
| 0010 | 推論バックエンド | CPU / CUDA / Vulkanを設定でユーザーが選択可能(実現方式は決定0028で確定) |
| 0011 | 候補ウィンドウの描画方式 | ネイティブWin32 + DirectWrite/DirectComposition(WebView2は不採用) — レイテンシ優先 |
| 0012 | 候補ウィンドウの見た目 | Windows 11のFluent Design(Mica、アクセントカラー追従、ライト/ダークモード自動追従) |
| 0013 | 設定アプリ | WinUI 3 |
| 0014 | 設定変更の反映方法 | レジストリ/設定ファイル + 変更通知(`RegNotifyChangeKeyValue` / `ReadDirectoryChangesW`)。能動的なIPCブロードキャストは不採用 |
| 0015 | サーバーのライフサイクル | オンデマンド起動(最初のクライアントが未起動なら起動)、アイドルタイムアウトで自動終了 |
| 0016 | [プライバシー](0016-privacy.md) | モデルダウンロード以外は完全オフライン。テレメトリなし、入力内容の外部送信なし |
| 0017 | TSFのクラッシュ耐性 | TSF DLLの全コードパスをSEH(`__try`/`__except`)で防御 |
| 0018 | 対応環境 | x64のみ(Windows 10/11)。ARM64は対象外として見送り |
| 0019 | インストーラー | Inno Setup |
| 0020 | ビルドの自動化 | MSBuildに`swift build`を呼び出すカスタムターゲットを組み込む |
| 0021 | 依存コードの取り込み方 | SampleIMEはvendoring(コピー、大幅改造)。AzooKeyKanaKanjiConverterはSwift Package Manager経由 |
| 0022 | プロジェクトのライセンス | MIT(依存関係のライセンス系統と統一) |
| 0023 | プロジェクト名 | **おはぎー(Ohagey)** — azooKey→おはぎ(小豆の和菓子)の語呂合わせ。井村屋の登録商標「あずきバー」等は回避 |
| 0024 | 学習データの保存場所 | `%LOCALAPPDATA%\Ohagey\`。AzooKeyKanaKanjiConverterの`memoryDirectoryURL`として渡す |
| 0025 | 学習機能のデフォルト | 有効。設定アプリからワンクリックで無効化・消去可能(学校PC等の共有端末に対応) |
| 0026 | 明示的なユーザー辞書登録 | 初期スコープに含める(`%LOCALAPPDATA%\Ohagey\`配下に別ファイルとして保存) |
| 0027 | 他IMEからの辞書インポート | 今回は見送り、将来の拡張機能とする |
| 0028 | [推論バックエンドの選択方式](0028-inference-backend-selection.md) | 決定0010の改訂。バックエンド別のllama.cpp DLLを同梱し、エンジン起動時にDLL検索パスで選択。切り替えはエンジン再起動を伴う |
| 0029 | wire ↔ エンジンモデルのマッピング層の置き場所 | `OhageyEngine`(実行可能ターゲット)ではなく **`OhageyEngineProto`**。SwiftPMは実行可能ターゲットにテストを持てず、oneof不在・sentinel値・敵対的入力を扱うこの層こそテストが要るため。C++ interopを持たないのでテストビルドも軽い。代償としてターゲット名が「生成物置き場」の実態と合わなくなっている(気になれば`OhageyEngineWire`を切って分離する) |
| 0030 | [壊れたリクエスト受信時に接続を切るか](0030-connection-drop-policy.md) | **unservable(`request_id`が取れる)は`failure`を返して接続維持。malformed / framing errorは接続を切る。** 接続はホストアプリ1本につき1本で、切ると合成中の文字列が失われるため |
| 0031 | [パイプ ACL の確定](0031-pipe-acl.md) | 決定0006の改訂・**セキュリティレビュー完了**。`WD`(Everyone)を現在のユーザーSID + `SY` + `BA` + `AC` に置換。`GRGW`をやめ明示的な`FILE_*`権限に。`PIPE_REJECT_REMOTE_CLIENTS` と(初回のみ)`FILE_FLAG_FIRST_PIPE_INSTANCE`を付与。同一ユーザーのプロセス間は**DACLでは区別できない**ため境界にできない旨も明記 |
| 0032 | [TSF 側(C++)の Protobuf 実装方法](0032-cpp-protobuf.md) | 決定0007の詳細化。libprotobuf / protobuf-lite / nanopb を使わず、**`ohagey.proto` の範囲だけ手書きする**。DLL は全アプリのプロセスに入るため依存の重さが体験に直結する。担保は**実エンジンとの往復テスト**(相手は swift-protobuf の生成コードなので、こちらが間違えば必ず露見する) |
| 0033 | [インストール配置とエンジンのオンデマンド起動](0033-install-layout-and-engine-launch.md) | 決定0015の実装に必要だった未確定部分。DLL と `OhageyEngine.exe` を同じディレクトリに置き、**DLL 自身のパスからの相対**でエンジンを解決する(レジストリに絶対パスを書かない)。起動後は待たずに戻り、次の打鍵で再接続する — 打鍵スレッドを止めない |

| 0034 | [学習を Zenzai の順位に効かせる](0034-zenzai-personalization.md) | 決定0025の実装に必要だった未確定部分。学習ストアはラティスを養うだけで、その上で再ランクする Zenzai には届いていなかった(実測)。upstream が Windows で個人化を除外していた原因は SwiftyMarisa のヘッダ1行(`size_t` 再定義)と、`[Int8]` を `strlen` で測る別バグの2つ。**両方を直した fork をリビジョン固定**する(azooKey 側は `Package.swift` のみ、ソース無改変・fork 点は 0.8.5 なので決定0028の制約は維持)。ライセンス不明の base LM は同梱せず**空 trie で代替** — 全語一律なので順位に影響せず、学習した候補だけが持ち上がる。代わりに alpha 既定を 0.5→**0.15** に下げる |

## 実装フェーズで詰める残課題
- ユーザー辞書ファイルの具体的なフォーマット(JSON等) — 実装時に決定
- 設定用のレジストリスキーマの詳細(決定0014関連)
- ~~IPC用のProtobufスキーマ定義(決定0007関連)~~ → `engine/Sources/OhageyEngineProto/ohagey.proto` に初版を定義済み
- llama.cpp のビルド構成(バージョン・ビルドフラグ・`systemLibrary`用のmodule map)の記録(決定0028関連)
- バックエンド初期化失敗時のCPUフォールバック実装(決定0028関連)

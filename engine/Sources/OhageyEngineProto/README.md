# OhageyEngineProto

`.proto`スキーマ定義(決定0007)から生成される、`tsf/`(C++クライアント)と`engine/`(Swift
サーバー)間のIPCプロトコルを表すSwift型をこのターゲットに配置します。例:

- `ConvertRequest` / `ConvertResponse`(読み → 変換候補リスト)
- `CommitRequest`(候補の確定、学習データへの反映)
- `RegisterWordRequest`(ユーザー辞書への明示的な単語登録、決定0026)
- `SettingsChanged`通知(決定0014のファイル監視方式だけで足りない場合に検討)

`.proto`ソースファイルと、`protoc` + `swift-protobuf`によるコード生成の手順は、IPC実装
に着手する際に追加します。

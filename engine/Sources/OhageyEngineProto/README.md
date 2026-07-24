# OhageyEngineProto

`.proto`スキーマ定義(決定0007)から生成される、`tsf/`(C++クライアント)と`engine/`(Swift
サーバー)間のIPCプロトコルを表すSwift型をこのターゲットに配置します。例:

- `ConvertRequest` / `ConvertResponse`(読み → 変換候補リスト)
- `CommitRequest`(候補の確定、学習データへの反映)
- `RegisterWordRequest`(ユーザー辞書への明示的な単語登録、決定0026)
- `PingRequest` / `PingResponse`(死活・バックエンド確認、決定0015/0010)

設定変更の反映はレジストリ/ファイル監視で行う(決定0014)ため、`SettingsChanged`通知は
現時点では定義していません。ファイル監視だけで不十分と判明した場合にのみ追加します。

## スキーマと生成手順

初版スキーマは [`ohagey.proto`](ohagey.proto) にあります(決定0007)。名前付きパイプ上の
framing(4バイト長プレフィックス)もファイル冒頭に記載しています。

`protoc` + [`swift-protobuf`](https://github.com/apple/swift-protobuf) で Swift 型を生成します:

```
protoc --swift_out=. ohagey.proto
```

生成された `*.pb.swift` をこのターゲットに配置し、`Package.swift` の `swift-protobuf`
依存(現在コメントアウト中)を有効化してください。

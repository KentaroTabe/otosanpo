# 02. アーキテクチャ

## レイヤと依存方向

```
App(SwiftUI・統合)──▶ Services(OSフレームワークのラッパ)──▶ Core(純粋ロジック)
```

- **Sources/Core** — Foundation のみ import 可。位置・音・タイマーに一切触れない。全ロジックがここにあり、外部環境なしでテストできる(グローバル規約「副作用と純粋計算の分離」に対応)
- **Sources/Services** — CoreLocation / CoreMotion / AVFoundation / 永続化のラッパ。ロジックを持たない
- **Sources/App** — SwiftUI と `WalkSessionController`(Effect 実行係)

## ファイル対応表

| ファイル | 役割 |
|---|---|
| Core/AppParameters.swift | config/parameters.json に対応する型 |
| Core/Geo.swift | 座標型と距離・方位計算(CoreLocation 非依存) |
| Core/VisitGrid.swift | 通過履歴グリッド(半減期つきカウンタ・除外フラグ) |
| Core/ReturnBudget.swift | 帰宅予算モデル(許容半径・帰宅バイアス) |
| Core/BearingSuggester.swift | 方向提案エンジン |
| Core/HeadGestureDetector.swift | うなずき / 首振り検出(±180° の折り返し解除を含む) |
| Core/TravelDirection.swift | 進行方向の決定(移動方向 course / 端末コンパスの選択) |
| Core/WalkMachine.swift | 状態機械(純粋 reducer)と earcon 語彙 |
| Services/LocationService.swift | CLLocationManager ラッパ(位置・course・speed・コンパス) |
| Services/HeadphoneMotionService.swift | CMHeadphoneMotionManager ラッパ |
| Services/EarconSynth.swift | earcon のコード合成・再生 |
| Services/Persistence.swift | 設定読込・グリッド / 自宅の永続化 |
| Services/FieldLog.swift | フィールドテスト用の追記ログ(端末内 TSV) |
| App/WalkSessionController.swift | reducer への入力供給と Effect 実行(タイマー・音・保存) |
| App/ContentView.swift | セットアップ / デバッグ用 UI |

## 設計上の決まり

- **数値パラメータは config/parameters.json のみ**。コード側にフォールバック値を持たない(二重管理の禁止)。読み込み失敗時はエラー画面を出して止まる
- 状態遷移はすべて `WalkMachine.reduce` を通す。Controller が直接 state を書き換えることは禁止
- JSON のキーは snake_case、Swift 側は camelCase(`.convertFromSnakeCase` で変換)

## ビルド

`OtoSanpo.xcodeproj` は XcodeGen による生成物であり、リポジトリに含めない。`project.yml` を編集して `scripts/setup.sh` で再生成する。ビルド・テストの実行方法は CLAUDE.md を参照。

署名の Team ID は生成物に残せないため、`Support/Signing.xcconfig`(gitignore 対象、`Support/Signing.example.xcconfig` から生成)に置き、`project.yml` の `configFiles` で読み込む。`DEVELOPMENT_TEAM` を `project.yml` の `settings` に書くと xcconfig を上書きしてしまうため書かない。Team ID の確認は `scripts/show_teams.sh`(証明書の OU。**証明書名の括弧内は開発者 ID であって Team ID ではない**)、設定は `scripts/set_team.sh <TEAM_ID>`、ビルド確認は `scripts/build_device.sh`(接続中の実機を自動検出。無料アカウントではこの実機指定ビルドで初めてデバイスがチームに登録される)。

## シミュレータでの制約と代替

| 実機依存機能 | シミュレータでの代替 |
|---|---|
| 位置情報 | Xcode の Features > Location(City Run / GPX ファイル) |
| ヘッドフォンモーション | ContentView のデバッグボタン(うなずき / 首振りを発火) |
| AirPods への音声出力 | Mac のスピーカーで代用(パンの確認はヘッドホン推奨) |

## 未確認事項

シミュレータ向けビルドとユニットテストは通っている(2026-08-14 時点)。未確認は以下。

- **実機ビルド**: Apple ID 未登録のため署名証明書がなく、`scripts/build_device.sh` は Team ID 設定待ち
- **実機動作**: 位置情報・AirPods モーション・音声出力は一度も検証していない
- **バックグラウンド動作**: 画面消灯・ポケット収納時に `CMHeadphoneMotionManager` の更新が続くか、Timer が動き続けるかは未検証。ここが崩れるとポケット運用の前提が成立しない

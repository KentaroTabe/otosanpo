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
| Core/HeadGestureDetector.swift | うなずき / 首振り検出 |
| Core/WalkMachine.swift | 状態機械(純粋 reducer)と earcon 語彙 |
| Services/LocationService.swift | CLLocationManager ラッパ |
| Services/HeadphoneMotionService.swift | CMHeadphoneMotionManager ラッパ |
| Services/EarconSynth.swift | earcon のコード合成・再生 |
| Services/Persistence.swift | 設定読込・グリッド / 自宅の永続化 |
| App/WalkSessionController.swift | reducer への入力供給と Effect 実行(タイマー・音・保存) |
| App/ContentView.swift | セットアップ / デバッグ用 UI |

## 設計上の決まり

- **数値パラメータは config/parameters.json のみ**。コード側にフォールバック値を持たない(二重管理の禁止)。読み込み失敗時はエラー画面を出して止まる
- 状態遷移はすべて `WalkMachine.reduce` を通す。Controller が直接 state を書き換えることは禁止
- JSON のキーは snake_case、Swift 側は camelCase(`.convertFromSnakeCase` で変換)

## ビルド

`OtoSanpo.xcodeproj` は XcodeGen による生成物であり、リポジトリに含めない。`project.yml` を編集して `scripts/setup.sh` で再生成する。ビルド・テストの実行方法は CLAUDE.md を参照。

## シミュレータでの制約と代替

| 実機依存機能 | シミュレータでの代替 |
|---|---|
| 位置情報 | Xcode の Features > Location(City Run / GPX ファイル) |
| ヘッドフォンモーション | ContentView のデバッグボタン(うなずき / 首振りを発火) |
| AirPods への音声出力 | Mac のスピーカーで代用(パンの確認はヘッドホン推奨) |

## 未確認事項

本スキャフォールドは Xcode の無い環境で生成した。**初回ビルドは未実施**であり、コンパイルエラーが残っている可能性がある。最初の作業は `scripts/setup.sh` → Xcode でのビルドエラー解消。

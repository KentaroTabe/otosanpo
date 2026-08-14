# OtoSanpo プロジェクト規約

グローバル共通運用規約(`~/.claude/CLAUDE.md`)を前提とし、本ファイルはプロジェクト固有事項のみを定める。

## ビルド・テスト

- `OtoSanpo.xcodeproj` は **XcodeGen による生成物**。直接編集せず、`project.yml` を編集して `scripts/setup.sh` で再生成する
- ビルド: `scripts/build.sh`(シミュレータ) / `scripts/build_device.sh`(実機・署名確認)
- 署名: Team ID は `Support/Signing.xcconfig`(gitignore 対象)に置く。Team ID の確認は `scripts/show_teams.sh`(**証明書名の括弧内は開発者 ID であり Team ID ではない。OU が Team ID**)、設定は `scripts/set_team.sh <TEAM_ID>`。`project.yml` の `settings` に `DEVELOPMENT_TEAM` を書かない(xcconfig を上書きするため)
- 無料アカウントでは、実機を UDID 指定してビルドした時に初めてデバイスがチームに登録される。`generic/platform=iOS` では登録されない
- テスト: `scripts/test.sh [シミュレータ名]`(既定: `iPhone 17`。手元の Xcode にあるシミュレータ名に合わせて引数で指定)
- 完了条件はテスト全緑(グローバル規約どおり)。`logs/` はスクリプトが生成するログ置き場であり、読み書き・コミットの対象にしない

## パラメータ

- 数値・閾値はすべて `config/parameters.json` に置く。Swift 側へのリテラル埋め込みは禁止(物理定数・単位換算・テストの期待値を除く)
- パラメータを追加・変更したら `Sources/Core/AppParameters.swift` と `docs/` の該当表を同時に更新する
- コード側にフォールバック値を持たない。読み込み失敗はエラー表示で止める(数値の二重管理禁止)

## レイヤ構成(依存方向: App → Services → Core)

- `Sources/Core`: 純粋ロジック。**import は Foundation のみ可**
- `Sources/Services`: OS フレームワークのラッパ(CoreLocation / CoreMotion / AVFoundation / 永続化)。ロジックを持たせない
- `Sources/App`: SwiftUI と統合(`WalkSessionController`)
- 状態遷移は必ず `WalkMachine.reduce` を通す。Controller で state を直接書き換えない
- Core を変更したら `Tests/` の追加・更新をセットで行う

## 実機依存機能

位置情報・ヘッドフォンモーション・音声出力の動作確認は **実機 + AirPods** でのみ可能。シミュレータでは Features > Location(GPX)と ContentView のデバッグボタンで代替する。実機で確認していない挙動は「未確認」と明示して報告する。

## 現状の未確認事項(2026-08 時点)

- シミュレータビルドとユニットテストは通過済み(2026-08-14)。**実機ビルド・実機動作はすべて未確認**
- Apple ID が Xcode に未登録のため署名証明書がなく、実機インストールは未実施
- 画面消灯・ポケット収納時に AirPods のモーション更新と Timer が継続するかは未検証。ポケット運用の前提なので実機で最初に確認する
- ジェスチャ閾値・earcon の音量 / 間隔・予算モデルの係数・進行方向の判定閾値は仮置きで、フィールドテスト未実施

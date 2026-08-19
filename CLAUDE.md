# OtoSanpo プロジェクト規約

グローバル共通運用規約(`~/.claude/CLAUDE.md`)を前提とし、本ファイルはプロジェクト固有事項のみを定める。

## ビルド・テスト

- `OtoSanpo.xcodeproj` は **XcodeGen による生成物**。直接編集せず、`project.yml` を編集して `scripts/setup.sh` で再生成する
- ビルド: `scripts/build.sh`(シミュレータ) / `scripts/build_device.sh`(実機向けビルドのみ)
- **実機へのインストールと起動は人が Xcode から行う。** スクリプトやコマンドで実機を操作しない
- 署名: Team ID は `Support/Signing.xcconfig`(gitignore 対象)に置く。Team ID の確認は `scripts/show_teams.sh`(**証明書名の括弧内は開発者 ID であり Team ID ではない。OU が Team ID**)、設定は `scripts/set_team.sh <TEAM_ID>`。`project.yml` の `settings` に `DEVELOPMENT_TEAM` を書かない(xcconfig を上書きするため)
- 無料アカウントでは、実機を UDID 指定してビルドした時に初めてデバイスがチームに登録される。`generic/platform=iOS` では登録されない
- テスト: `scripts/test.sh [シミュレータ名]`(既定: `iPhone 17`。手元の Xcode にあるシミュレータ名に合わせて引数で指定。手元にあるのは `iPhone 17 Pro`)
- **増分ビルドが古いまま通ることがある。** 実際に 2 度発生した(未署名の `.app` が残ってシミュレータが起動しない / 追加したテストが実行されない)。テスト数が増えたはずなのに変わらない、原因不明の起動失敗が続く、といった場合は `xcodebuild ... clean` を挟む
- ファイルを追加・削除したら `scripts/setup.sh` で `.xcodeproj` を再生成する(`project.yml` はディレクトリを glob しているため、生成時点のファイル一覧が焼き込まれる)
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

## フィールドテスト

段階・実施状況・課題は `docs/05_field_test.md` に集約する。ログの取り出しは
`scripts/import_log.sh`(受け取り口は `field-logs/inbox/`。PC の他のフォルダは読まない)。

**実機テストは実装ごとに行わない。** 1 要素 1 実験では回数が過剰になる。

- 純粋ロジックの検証は `scripts/replay_log.sh`(記録したログを Core に流し直す)で行う。
  パラメータを振って比べることもできるので、値を決めるために歩く必要はない
- 実機に回すのは、音の聞こえ方・ジェスチャ・OS の挙動・GPS の実際の質だけ
- 未検証の実装は docs/05 の待ち行列に貯め、溜まったら散歩 1 回でまとめて確認する。
  1 回のテストで「意図的に試す」項目は 1〜2 個までに抑える(残りは自動で記録される)

## 現状の未確認事項(2026-08-16 時点)

- 段階 3・4(屋外での提案 → 時間到来 → ジェスチャ応答 → 帰路ビーコン)まで実施済み。**通しでは動作したが、提案の精度とジェスチャ閾値に課題あり**(docs/05)
- 画面消灯・ポケット収納時に AirPods のモーション更新と Timer が継続するかは、明示的には未検証
- ジェスチャ閾値・earcon の音量 / 間隔・予算モデルの係数・進行方向の判定閾値は依然として仮置き。実測ログに基づく調整はこれから

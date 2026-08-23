# 音さんぽ(OtoSanpo)— 画面を見ない散歩アプリ

**音でそっと導く、画面を見ない寄り道散歩アプリ。**

出発前に時間だけ決めれば、歩行中は短い効果音が普段通らない道への寄り道を提案する。
時間が来たら音で知らせ、うなずきで帰路開始、首振りで延長。帰路は音が自宅へ導く。
移動履歴は端末内にのみ保存し、外部へ送信しない。

> **試してくれる方へ: [docs/09_tester_guide.md](docs/09_tester_guide.md) を読んでください。**
> ビルドから散歩、フィードバックの返し方まで手順が書いてあります。

## ブランチ

| ブランチ | 中身 | 状態 |
|---|---|---|
| `main` | 公開の基準。PR #1・#2 を取り込み済み | **最新の実装はまだ入っていない**(下記) |
| **`feature/p1-experience`** | **方針 A(曲がる所を指す)の本流。いま試してもらうのはここ** | 開発中・実機テスト待ち |
| `feature/music-spots` | 方針 C(離れたスポットの音楽に惹かれて歩く)。**計画のみで実装は無い** → [docs/08](docs/08_music_spots.md) | 保留 |
| `feature/device-test-prep` | PR #1 の作業ブランチ。役目を終えた | 参照のみ |

`main` は PR #2 までを取り込んでいるが、**それ以降の実装(約 4,000 行)がまだ入っていない**
(2026-08-21 時点)。帰路の案内・散歩の記録・歩調同期・行き先の地帯・頭の追従の計測などは
`main` には無い。**試すときはブランチを間違えないこと。**

案内音には 3 つの方針があり、ブランチを分けて比べる予定
(A = 曲がる所を指す・現行 / B = 道の先から音がする・未着手 / C = スポットの音楽・計画のみ)。
→ [docs/06](docs/06_design_plan.md)「案内音の 3 つの方針」

## 必要環境

- macOS + Xcode 15 以降(iOS 17 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)
- iPhone(iOS 17 以降)実機 — 位置情報・音声のテスト用
- AirPods(モーション対応: 第 3 世代 / Pro / Max 等)— ジェスチャ応答用。
  **無くても散歩はできる**(帰路の開始は画面のボタンで代替)

## セットアップ(開発者)

```
brew install xcodegen
scripts/setup.sh
scripts/show_teams.sh
scripts/set_team.sh <TEAM_ID>
scripts/build_device.sh
```

`OtoSanpo.xcodeproj` は **XcodeGen の生成物**。直接編集せず `project.yml` を編集して
`scripts/setup.sh` で再生成する。実機へのインストールと起動は **Xcode から人が行う**。

テスト:

```
scripts/test.sh "iPhone 17 Pro"
```

Core(帰宅予算・グリッド・分岐提案・誘導・状態機械・散歩の記録)は純粋ロジックで、
外部環境なしにユニットテストできる(181 件)。

## 検証の 3 段(散歩の回数を増やさないための約束)

| 手段 | 対象 | コスト |
|---|---|---|
| ユニットテスト | Core の純粋ロジック | `scripts/test.sh` |
| **ログ再生** | 記録済みの実データに対する振る舞い。経路長・提案の判定・パラメータの振り直し | `scripts/replay_log.sh` |
| 実機テスト | 音の聞こえ方・ジェスチャ・OS の挙動・GPS の実際の質 | 散歩 1 回 |

**実機に回す前に「これは再生で確かめられないか」を必ず問う。** → [docs/05](docs/05_field_test.md)

## ディレクトリ構成

```
config/parameters.json   全数値パラメータ(閾値・時間・音の定義)
Sources/Core/            純粋ロジック(Foundation のみ)
Sources/Services/        位置・モーション・音・永続化のラッパ
Sources/App/             SwiftUI と統合コントローラ
Sources/Replay/          記録したログを Core に流し直す道具(macOS)
Sources/MapBuild/        OSM から経路データを作る道具(macOS)
Sources/Demo/            紹介用に音を書き出す道具(macOS)
Tests/                   Core のユニットテスト
docs/                    設計ドキュメント(01〜09)
scripts/                 setup / build / test / ログ取り込み / 再生
project.yml              XcodeGen 定義(*.xcodeproj は生成物)
```

## 既知の制限(2026-08-21 時点)

- **音はコード合成のサイン波。** デザインされた音源への差し替えは保留中
- 頭の向きは定位に反映していない。AirPods の yaw が旋回を追えなかったため
  (角速度でやり直す実装を入れたが、既定では動作に入れていない)→ [docs/03](docs/03_session_and_audio.md)
- 前後の聴き分けは HRTF では成立しない。音色を暗くして代替している
- 経路データが無い場所ではグリッドのみで動く(提案の質が落ちる)
- ジェスチャ閾値・音量・間隔は実測に基づく暫定値。`config/parameters.json` で調整する

## ドキュメント

| | |
|---|---|
| [01 コンセプトと決定事項](docs/01_concept_and_decisions.md) | 3 原則・ロードマップ・決定の履歴 |
| [02 アーキテクチャ](docs/02_architecture.md) | レイヤ構成と依存規則 |
| [03 セッションと音](docs/03_session_and_audio.md) | 状態機械・帰宅予算・earcon 語彙・誘導 |
| [04 経路・ジェスチャ・プライバシー](docs/04_route_gesture_privacy.md) | 経路学習・OSM の持ち方・安全 |
| [05 フィールドテスト](docs/05_field_test.md) | 実測の記録と未検証の待ち行列 |
| [06 設計方針と実験計画](docs/06_design_plan.md) | 4 本の柱・案内音の 3 方針・判断待ち |
| [07 人に紹介する道具](docs/07_introducing.md) | 音を書き出して聴かせる |
| [08 方針 C: スポットの音楽](docs/08_music_spots.md) | 計画のみ(`feature/music-spots`) |
| [09 テスターの手順書](docs/09_tester_guide.md) | **試してくれる方はここから** |

経路データは OpenStreetMap 由来。ODbL の下で提供されている。
© OpenStreetMap contributors

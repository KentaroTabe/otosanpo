# 音さんぽ(OtoSanpo)— 画面を見ない散歩アプリ

**音でそっと導く、画面を見ない寄り道散歩アプリ。**

出発前に時間だけ決めれば、歩行中は短い効果音が普段通らない道への寄り道を提案する。
時間が来たら音で知らせ、うなずきで帰路開始、首振りで延長。帰路は音が自宅へ導く。
移動履歴は端末内にのみ保存し、外部へ送信しない。
外へ出るのは地図を取得する時(散歩開始時の自動取得と画面のボタン)だけで、
送るのは**その区画(約 5 km 角)の番号**のみ。揃っていれば通信しない
(→ [docs/12](docs/12_map_delivery.md))。

> **試してくれる方へ: [docs/09_tester_guide.md](docs/09_tester_guide.md) を読んでください。**
> ビルドから散歩、フィードバックの返し方まで手順が書いてあります。

## ブランチ運用(2026-08-28 から)

```
main       テスターが触っている安定盤。develop からの PR でのみ更新する
develop    仮のメイン(統合先)。機能ブランチはここへマージする
feature/*  機能ごと。develop から生やして develop へ戻す
```

| ブランチ | 中身 |
|---|---|
| `main` | **テスターが触っているもの。** ここから TestFlight のビルドを作る |
| **`develop`** | **仮のメイン。開発はここを起点にする**(旧 `feature/p1-experience`) |
| `feature/android` | Android 版 → [docs/10](docs/10_android.md) |
| `feature/music-spots` | 方針 C(スポットの音楽)。**計画のみで実装は無い** → [docs/08](docs/08_music_spots.md) |

### 決めごと

- **機能ブランチは `develop` から生やす。** `main` からではない
- **開発者テストが終わったら `develop` へ PR。** テスト全緑が条件
- **`main` へは `develop` からの PR だけ。** テスターに配る区切りで行う
- **緊急修正は `main` へ直接入れ、すぐ `develop` へ戻す。**
  戻し忘れると次のリリースで修正が消える
- **配ったビルドにはタグを打つ。** `testflight-<ビルド番号>` の形。
  「テスターが何を触っているか」を後から辿るための唯一の手段
  (例: `testflight-202608270058` = TestFlight 1.0 の外部テスト初回)

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

## 店舗通過履歴の基盤(feature/shop-history)

### 変更したファイル

- `Sources/Core/ShopHistory.swift`: 店舗データ、通過履歴、散歩単位の重複除外、通過判定。
- `Sources/Services/ShopHistoryService.swift`: 店舗候補取得 protocol、空 provider、端末内 JSON 永続化、Core への橋渡し。
- `Sources/App/WalkSessionController.swift`: 散歩開始時に店舗通過セッションを初期化し、位置更新中と散歩終了時の経路に店舗判定を接続。
- `Sources/Core/AppParameters.swift` / `config/parameters.json`: 通過判定距離 `shop_history.passage_radius_m` を追加。初期値は 30 m。
- `Tests/ShopHistoryTests.swift` / `Tests/ParametersFileTests.swift`: 店舗履歴ロジックと設定値のテストを追加。

### 新しく追加したデータ構造

- `Shop`: 店舗ID、店名、緯度、経度、カテゴリを持つ店舗データ。
- `ShopPassageHistory`: 店舗ID、初めて通った日時、最後に通った日時、通過回数を持つユーザー履歴。
- `ShopHistory`: `shopsByID` と `historiesByShopID` を別々に保持する端末内アーカイブ。
- `ShopPassageSession`: 1 回の散歩中にすでに数えた店舗IDを保持し、同じ散歩中の往復を 1 回にまとめる。
- `ShopPassageUpdate`: 通過記録の更新結果。`isFirstPassage` で初回通過か判定できる。

### 通過判定の仕組み

散歩中は現在地と店舗座標の距離が `shop_history.passage_radius_m` 以下なら通過として扱う。
散歩終了後は記録された経路の折れ線に対する最短距離で判定する。
同じ店舗IDが同じ `ShopPassageSession` にすでに記録済みなら更新しないため、同じ散歩中に店の前を何度往復しても通過回数は 1 回だけ増える。
別の散歩で再度通った場合は `passCount` を +1 し、`lastPassedAt` を更新する。初回だけ `firstPassedAt` と `lastPassedAt` が同じ日時になる。

店舗候補の取得口は `ShopCandidateProviding` で分離している。
現時点では `EmptyShopCandidateProvider` を接続しており、Hot Pepper API などへの本接続は行わない。

### テスト内容

- 初回通過で `Shop` と `ShopPassageHistory` が分離して保存され、`isFirstPassage` が true になること。
- 別散歩で同じ店を再訪すると `passCount` が増え、初回日時を残したまま最終通過日時だけ更新されること。
- 同じ散歩中の同じ店は 2 回目以降カウントされないこと。
- 30 m の通過判定距離で、29 m の店は通過、31 m の店は対象外になること。
- 散歩終了後の経路判定で、経路の折れ線から 30 m 以内の店だけ通過になること。
- `config/parameters.json` の `shop_history.passage_radius_m` が実際にデコードされること。

### 次に shop-map を実装するときに必要なこと

- `ShopCandidateProviding` の実装を追加し、Hot Pepper API などから現在地周辺または経路沿いの候補店舗を返す。
- API の店舗ID、店名、緯度、経度、カテゴリを `Shop` に正規化する。
- API 呼び出し頻度、キャッシュ、失敗時の扱いを `Services` 側に置き、Core の `ShopHistory` には候補配列だけ渡す。
- MAP UI では `ShopHistory.records` を読めば、店舗データと通過履歴を結合した一覧・ピン表示に使える。
- 通過判定距離を調整したい場合は `config/parameters.json` の `shop_history.passage_radius_m` を変更する。

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
| [08 方針 C: スポットの音楽](docs/08_music_spots.md) | 計画 + 2026-08-29 改訂(頭部固定・音楽は配信) |
| [09 テスターの手順書](docs/09_tester_guide.md) | **試してくれる方はここから**(そのまま渡せる) |
| [12 地図の配り方](docs/12_map_delivery.md) | タイル配信・自動取得・通信の約束 |
| [13 スマホ頭部固定](docs/13_head_mount.md) | B・C 共通の実験基盤(絶対方位・磁気の検疫) |
| [14 方針 B: 道の先から音がする](docs/14_direction_b.md) | 先導ビーコンの設計(帰路の一般化) |

配る側(署名・配信・審査)の手順は `docs/09_distribution_private.md` に分けてあり、
**gitignore 対象なのでここには無い**。手順書をそのまま共有できる状態に保つため。

経路データは OpenStreetMap 由来。ODbL の下で提供されている。
© OpenStreetMap contributors

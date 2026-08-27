# 10. Android 版の設計(2026-08-21)

iOS 版(`Sources/`)で確かめた体験を Android へ移す。ブランチは `feature/android`。

**移すのは「音の鳴る方に歩くと面白い散歩ができる」という体験であって、実装ではない。**
プラットフォームで取れないものがあるので、同じコードにはならない。

## 何がそのまま移せて、何が移せないか

| iOS | Android | 難度 |
|---|---|---|
| `Sources/Core`(Foundation のみ・純粋) | **Kotlin へそのまま移せる**。JVM で単体テストできる | 低(機械的) |
| `config/parameters.json` | **同じファイルを共有する**(数値の二重管理を避ける) | 低 |
| 経路データ `otosanpo-map.json` | **同じ形式をそのまま読む** | 低 |
| `CLLocationManager`(course / speed / 精度) | `LocationManager`。`Location.bearing` / `bearingAccuracyDegrees`(API 26+)/ `speed` が 1 対 1 で対応する | 低 |
| `CMPedometer`(歩調) | `Sensor.TYPE_STEP_DETECTOR` の間隔から自前で歩調を出す | 中 |
| `AVAudioEngine` で波形合成・再生 | `AudioTrack`。**波形は Core(`ToneRenderer`)が作るので同じ音になる** | 中 |
| `AVAudioEnvironmentNode`(HRTF) | 相当が無い。**ステレオパンで代替する**(下記) | — |
| `UIBackgroundModes`(audio / location) | **Foreground Service + 常駐通知**が必須。`foregroundServiceType` の宣言も要る | 高 |
| `CMHeadphoneMotionManager`(頭の姿勢) | **公開 API が無い。** 代替は下記 | **高** |
| SwiftUI | Jetpack Compose | 中 |
| `UIFileSharingEnabled` + `ShareLink` | Storage Access Framework / `ACTION_SEND` | 中 |

## 移せないものへの対処

### 1. 頭のジェスチャ(うなずき / 首振り)

**AirPods の頭部姿勢に相当する公開 API が Android には無い。**
iOS 版はこれで「時間到来 → うなずきで帰る / 首振りで延長」を実現している。

| 案 | 評価 |
|---|---|
| **a. 音量ボタン**(上げる = 延長 / 下げる = 帰る) | ポケットの中で押せる。画面を見ない原則を保てる。**推奨** |
| b. 画面のボタン | 確実だが「画面を見ない」が崩れる。a が効かない端末の逃げ道として残す |
| c. 通知のアクション | ロック画面から押せるが、結局画面を見る |
| d. `Sensor.TYPE_HEAD_TRACKER`(Android 13+) | **対応ヘッドセットがあれば頭の向きが取れる**。ただし機種依存で、手元に対応機があるかは**未確認**。あるなら iOS より条件が良い |
| e. 端末のジャイロ | ポケットの中の端末は頭ではない。**不可** |

**a を既定にし、b を逃げ道に置く。** d は取れるかを実機で確かめてから考える。

> iOS 版は AirPods の yaw が旋回を追えず、頭の向きを定位に使えていない(docs/03)。
> **Android で d が使えるなら、頭の向きは Android のほうが先に成立する可能性がある。**
> その場合の受け皿として、Core の `HeadTracker` / `HeadingFusion` も移植しておく。

### 2. 空間オーディオ(HRTF)

Android に `AVAudioEnvironmentNode` 相当は無い(`Spatializer` はシステム側の処理で、
アプリが音源の座標を指示するものではない)。

**ステレオパンで始める。損失は小さいと実測で分かっている:**

- iOS で HRTF を入れたが、**前後の判別はできなかった**(2026-08-18 実測)。
  いま前後は「音色を暗くする」で分けており、これは**パンでもそのまま使える**
- 左右・距離(音量)・間隔は、いずれもパンで再現できる

`SoundPlacement`(Core)は既に「相対方位 → パン」と「相対方位 → 3D 座標」の両方を持つ。
Android はパン側だけを使う。

### 3. バックグラウンド

iOS は `UIBackgroundModes` の宣言だけで、ポケットに入れたまま位置更新と音が続く。
Android は **Foreground Service** が要る:

- `foregroundServiceType="location|mediaPlayback"`(Android 14 以降は宣言必須)
- 常駐通知が出る(iOS の青いインジケータに相当)
- 電池最適化の除外を利用者に依頼する画面が要ることがある(機種差が大きい)

**ここが Android 版で最も手間のかかる部分。** 体験の質ではなく OS への対応で消える工数。

## 配布は Android のほうが圧倒的に楽(見落としがちな利点)

iOS 版は**無料の Apple ID で開発しているため、ビルド済みのものを人に渡せない**。
TestFlight も Ad Hoc も有料の Apple Developer Program($99/年)が要る。
だからテスターには「自分の Mac と Xcode でビルドしてください」と頼むことになる
(docs/09)。準備だけで 30〜60 分かかる。

**Android は APK をそのまま渡せる。** 自己署名でよく、有料プログラムも要らない
(受け取る側が「提供元不明のアプリ」を許可するだけ)。

> **人数を増やしたいなら、Android 版のほうが先に効く。**
> 体験を別プラットフォームで確かめること以外に、**課金せずに配れる**という
> 副次的な利点がある。これは当初の動機には無かったが、実際には大きい。

## 層の構成(依存方向は iOS と同じ)

```
app(Compose・Service)──▶ services(位置・センサ・音)──▶ core(純粋ロジック)
```

| モジュール | 中身 | テスト |
|---|---|---|
| `android/core` | Kotlin・**kotlin 標準ライブラリのみ**。Android に依存しない | **JVM で単体テスト**(Android SDK 不要) |
| `android/services` | `LocationManager` / `SensorManager` / `AudioTrack` / 永続化 | 実機 |
| `android/app` | Compose の画面と `WalkSessionController` 相当 | 実機 |

**`android/core` は Android SDK が無くてもビルドとテストができる。**
iOS 版で「純粋ロジックは外部環境なしでテストできる」ようにしてあるので、
同じ性質をそのまま引き継ぐ。移植の正しさは**同じ期待値のテストが緑になること**で担保する。

## 数値と地図は共有する

**`config/parameters.json` を 2 つ持たない。** 同じファイルを Android のリソースにも入れる。

- 片方だけ直すと、iOS と Android で挙動が変わり、実測の比較ができなくなる
- JSON の鍵は snake_case のまま。Kotlin 側は `@SerialName` で受ける
- 経路データ(`otosanpo-map.json`)も同じ形式。`WalkMap` の Kotlin 版が同じ鍵で読む

**鍵を足したら Kotlin 側にも足す。** Kotlin は `ignoreUnknownKeys = true` なので、
足しただけでは**落ちずに黙って無視される**。iOS だけ直って Android が古い挙動のまま、
という食い違いに気づけないので、パラメータの追加は必ず両方で行う。

## 採らなかった案

- **Kotlin Multiplatform で Core を 1 つにする。** 理想ではあるが、既存の Swift Core を
  捨てて書き直すことになり、iOS 側の実測の積み上げ(テスト 181 件)を一度失う。
  **当面は「2 実装 + 共有 JSON + 同じ期待値のテスト」**とする。
  両方が育って差分が苦になったら再検討する(判断待ち)
- **Flutter / React Native で作り直す。** 音の低遅延再生とセンサの扱いが要件の中心なので、
  抽象層を挟む利点が小さい
- **Play Services の FusedLocationProvider。** 質は良いが GMS 依存が増える。
  まず `LocationManager` で始め、精度が足りなければ切り替える(判断待ち)

## 実装の段取り

| 段 | 中身 | 検証 | 状態 |
|---|---|---|---|
| 0 | この設計書 | — | **済** |
| 1 | `android/core` の移植(純粋ロジック) | JVM の単体テスト(90 件) | **済** |
| 2 | `parameters.json` の読み込みと共有 | 実ファイルを読むテスト | **済** |
| 3 | 位置・センサ・音の配線(常駐サービスを含む) | **APK のビルドまで済**・実機は未 | **済(未検証)** |
| 4 | 画面(設定・デバッグ・前回の散歩) | 同上 | **済(未検証)** |
| 5 | 実機テスト 1 回 | 散歩 | 待ち |

```
scripts/setup_android_sdk.sh   # 1 回だけ。SDK とライセンス
scripts/test_android.sh        # core の単体テスト(SDK 不要)
scripts/build_android.sh       # APK を作る
```

**段 1 と 2 は Android SDK が無くても動く。** 純粋ロジックを環境なしで検証できる作りを
iOS 版から引き継いでいる。

## テスターに配る(配る側の手順)

**iOS と違って審査も登録料も端末登録も要らない。** APK を渡すだけ。
**テスターに渡すのは [docs/11](11_android_tester_guide.md) と APK の 2 つ**で、
この設計書は渡さない。

### 配るたび

1. core のテストが全緑か

```bash
scripts/test_android.sh
```

2. APK を作る

```bash
scripts/build_android.sh
```

   できるのは `android/app/build/outputs/apk/debug/app-debug.apk`(約 3.3 MB)。

3. **今回何を見てほしいかを伝える。** iOS の TestFlight と違って
   「テスト内容」を書く欄が無いので、**APK を渡すメッセージに直接書く**。
   1 回に頼むのは 1〜2 個まで(docs/05 の方針)

4. APK と docs/11 を渡す

### 新しいテスターを迎えるとき

1. **端末が Android 10(API 29)以降か先に聞く。** `minSdk = 29` なので、
   それ未満の端末には**インストールできない**
2. **経路データを作って渡す**(任意)

```bash
scripts/build_map.sh <地域データ> <中心緯度> <中心経度>
```

   **散歩の中心(自宅など)のだいたいの座標が要る。** 先に断って聞くこと。
   断られたら作らなくてよい(無くても歩ける)。
   置き場所は端末の `Android/data/dev.otosanpo/files/`

3. **まだ 1 度も実機で動いていないことを伝える。**
   最初は「起動して 5 分歩く」だけを頼む。docs/11 の冒頭にも書いてある

> **APK はデバッグ署名。** ストアに出すわけではないので、これで足りる。
> 配布用の署名鍵を作るのは、Play ストアに出すと決めた時でよい(判断待ち 6)。

### ビルド環境で踏んだこと(記録)

- **JDK を固定しない。** `jvmToolchain(17)` を書いたら「17 が無い」で止まった
  (この Mac には 20 と Homebrew の 26 しか無い)
- **Kotlin の版は AGP に合わせる。** `core` を 2.4.0 で作ると、AGP 9.3.1 に内蔵の
  コンパイラ(2.2.0)がその成果物を読めない。**両方 2.2.0 に揃える**
- **AGP 9 以降は `kotlin("android")` を足さない。** 組み込みなので、足すと止まる
- **`:app` に kotlinx.serialization を持ち込まない。** 保存するのは自宅の 1 点・速度の
  2 値・セルの一覧だけなので、行区切りのテキストで足りる。依存が減れば、
  他人の環境でビルドが通らない可能性も減る

### 移植したもの(Core・90 件全緑)

`Geo` / `WalkMachine` / `ReturnBudget` / `SpeedEstimator` / `GaitMetrics` /
`BeaconRhythm` / `SoundPlacement` / `ReturnAck` / `TurnGuidance` / `HeadTracker` /
`AppParameters`(JSON)/ `VisitGrid` / `TravelDirection` / `ToneRenderer` /
`WalkMap` / `WalkGraph` / `RouteField` / `ZoneMap` / `BranchSuggester` /
`BearingSuggester` / `WalkSummary`。

**テストも一緒に移し、期待値は iOS 版と同じ数字にした。** 片方だけ通る状態を作らない。
移植の正しさは「同じ入力に同じ答えを返す」ことで担保する。

**移していないもの: `HeadGestureDetector` / `HeadingFusion`。**
Android にはヘッドフォンの頭部姿勢を取る公開 API が無く、入力源そのものが存在しない。

### アプリ層(段 3・4)

| ファイル | 役割 |
|---|---|
| `WalkSession` | Effect の実行(タイマー・音・位置・保存)。iOS の `WalkSessionController` に対応 |
| `LocationSource` | `LocationManager`。course / speed / 精度は iOS と 1 対 1 |
| `StepCadence` | `TYPE_STEP_DETECTOR` の間隔から歩調を出す |
| `EarconPlayer` | `AudioTrack`。**波形は Core が作る**ので iOS と同じ音 |
| `Storage` | 設定・地図・自宅・履歴・速度・フィールドログ |
| `WalkService` | 常駐サービス(位置と音を画面消灯中も続ける) |
| `MainActivity` | 設定とデバッグの画面。**音量ボタンで「帰る / 延長」** |

### ビルド環境で踏んだこと(記録)

- **JDK を固定しない。** `jvmToolchain(17)` を書いたら「17 が無い」で止まった
  (この Mac には 20 と Homebrew の 26 しか無い)。手元にある JDK で動く形にした
- **Kotlin プラグインは Gradle 本体の埋め込み版に合わせる。** 古い版(2.1.0)は
  新しい JDK の版番号を解釈できず、コンパイラが内部エラーで落ちた
- `android/local.properties`(SDK の場所)は gitignore 対象なので消えることがある。
  「SDK location not found」で止まったら `scripts/setup_android_sdk.sh` を流し直す。
  SDK 本体が既にあれば数秒で終わる

### iOS 側の修正を取り込んだもの

| 取り込み | 内容 |
|---|---|
| 2026-08-27 | **経路長の跳ねを直線距離で抑える**(`route_straight_max_ratio`)。iOS の実測で、経路長が 42 秒だけ直線の 2.9 倍に跳ね、その 1 サンプルで帰宅プロンプトが撃たれた。`ReturnBudget.distance` と `Distance.CappedRoute` を Kotlin にも入れ、テストも同じ数字で移した(→ docs/03「経路長の跳ねを直線距離で抑える」) |

## 判断待ち(こちらでは決めない)

| # | 項目 | 選択肢 |
|---|---|---|
| 1 | ジェスチャの代替 | **音量ボタン(推奨)** / 画面のボタンのみ / `TYPE_HEAD_TRACKER` を試す |
| 2 | 位置情報の取得元 | **`LocationManager`(推奨・GMS 非依存)** / Fused(質は良いが依存が増える) |
| 3 | 対象 Android のバージョン | 8.0(API 26)以上 = `bearingAccuracyDegrees` が使える最低線 / 13(API 33)以上 = 頭部トラッキングも視野 |
| 4 | Core を将来 1 つにするか | 2 実装のまま / Kotlin Multiplatform へ寄せる |
| 5 | テスト端末 | **手元に Android 実機は無い**(2026-08-26 に確認)。持っている知人に頼む前提で進める。段 5(実機テスト)はその人の都合次第 |
| 6 | Play ストアに出すか | **APK を手渡しのまま(いまはこれ)** / ストアに出す(初回登録料が要り、配布用の署名鍵も作ることになる) |

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
| 1 | `android/core` の移植(純粋ロジック) | JVM の単体テスト | **進行中(下記)** |
| 2 | `parameters.json` の読み込みと共有 | JVM | |
| 3 | 位置・センサ・音の配線(Foreground Service を含む) | 実機 | |
| 4 | Compose の画面(設定・デバッグ・散歩の記録) | 実機 | |
| 5 | 実機テスト 1 回 | 散歩 | |

**段 1 と 2 は Android SDK が無くても進む。** 手元の環境には Gradle と Kotlin だけ入れた。
段 3 以降は Android Studio と SDK が要る。

```
scripts/test_android.sh     # gradle -p android :core:test
```

### 段 1 の進み具合

| 移植したもの | テスト |
|---|---|
| `Geo`(距離・方位・線分への最近点) | 6 |
| `WalkMachine` / `Earcon` / `WalkState` / `WalkEffect` | 7 |
| `ReturnBudget`(経路 / 直線の 2 通り・許容半径・帰宅バイアス) | 6 |
| `SpeedEstimator` / `GaitMetrics` | 8 |
| `BeaconRhythm` / `SoundPlacement` / `ReturnAck` | 8 |
| `TurnGuidance`(予告・頂点・片道ブレンド・終端・背後の打ち切り) | 12 |
| `HeadTracker`(角速度の積分と減衰) | 6 |
| **計** | **55 件・全緑** |

まだ移していないもの(依存の少ない順):

1. `AppParameters` の残りの節と **JSON の読み込み**(段 2)
2. `ToneRenderer`(波形合成)/ `TravelDirection` / `HeadGestureDetector` / `HeadingFusion`
3. `VisitGrid` / `WalkMap` / `WalkGraph` / `RouteField` / `ZoneMap` / `BranchSuggester` / `BearingSuggester`
4. `WalkSummary`

**テストも一緒に移す。期待値は iOS 版と同じ数字にする。** 片方だけ通る状態を作らない。

### ビルド環境で踏んだこと(記録)

- **JDK を固定しない。** `jvmToolchain(17)` を書いたら「17 が無い」で止まった
  (この Mac には 20 と Homebrew の 26 しか無い)。手元にある JDK で動く形にした
- **Kotlin プラグインは Gradle 本体の埋め込み版に合わせる。** 古い版(2.1.0)は
  新しい JDK の版番号を解釈できず、コンパイラが内部エラーで落ちた

## 判断待ち(こちらでは決めない)

| # | 項目 | 選択肢 |
|---|---|---|
| 1 | ジェスチャの代替 | **音量ボタン(推奨)** / 画面のボタンのみ / `TYPE_HEAD_TRACKER` を試す |
| 2 | 位置情報の取得元 | **`LocationManager`(推奨・GMS 非依存)** / Fused(質は良いが依存が増える) |
| 3 | 対象 Android のバージョン | 8.0(API 26)以上 = `bearingAccuracyDegrees` が使える最低線 / 13(API 33)以上 = 頭部トラッキングも視野 |
| 4 | Core を将来 1 つにするか | 2 実装のまま / Kotlin Multiplatform へ寄せる |
| 5 | テスト端末 | 手元にある Android 実機の有無(**未確認**)。無ければ段 3 以降は進められない |

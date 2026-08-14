# 03. セッション状態機械と音響設計

## 状態遷移

```
idle ──start──▶ wandering ──timeUp──▶ promptingReturn ──nod──▶ returning ──reachedHome──▶ arrived
                    ▲                       │ shake(上限内)                                    │
                    └───── 延長 +10分 ───────┘                                        start で再開可
                                            │ shake(上限到達) / 無応答
                                            └─▶ promptingReturn のまま再プロンプト(60 秒毎)
どの状態からも stop ──▶ idle
```

- 延長は `extension_step_min`(10 分)刻みで `max_extensions`(2 回)まで
- 上限到達後の首振り・無応答は、強制帰宅させず再プロンプトのみ(叱らない)
- ジェスチャ検出は **promptingReturn 状態のときだけ**サンプルを流す(誤検出の主対策)

## 帰宅予算モデル(ゴムひも)

- 帰宅所要推定: `returnMin = 直線距離 × detour_factor ÷ walking_speed_m_per_min`
- 許容半径: `allowedRadius = min(残り時間 − reserve, max_return_walk_min) × speed ÷ detour`
  - `max_return_walk_min = 15` が天井なので、**どの瞬間に帰路へ入っても帰りは約 15 分以内**
- 帰宅バイアス: 許容半径の `soft_zone_ratio`(0.7)倍までは 0、許容半径で 1 に線形増加。バイアスは提案スコアに掛かり、ユーザーに意識させずに提案を自宅方向へ寄せる

## earcon 語彙(5 種・これ以上増やさない)

| earcon | 役割 | 音形(合成初期値) | 鳴る条件 |
|---|---|---|---|
| suggestion | 寄り道の提案。パンで方向を示す | 880→1175 Hz の 2 ブリップ | wandering 中、最大 25 秒に 1 回。曲がる価値のある時だけ |
| timeUpPrompt | 時間到来。「帰る? うなずき / 首振り」 | 659→784→988 Hz の上行 3 音 | timeUp 時と再プロンプト(60 秒毎) |
| returnAck | 帰路同意の確認 | 523→392 Hz の下行 2 音(長め) | 同意直後から 60 秒間、8 秒毎に繰り返し |
| homeBeacon | 帰路の方向ビーコン | 440 Hz 単発ピップ | ack 期間後、距離連動の間隔で間欠 |
| arrival | 到着 | 523→659→784 Hz の 3 音 | 自宅 40 m 以内に入った時 |

設計原理: 提案=上行(開く)、確認・帰路=下行(閉じる)という音楽的な対で覚えやすくする。

## returnAck の仕様(ユーザー要望による)

うなずきの直後に 1 回、その後 `return_ack_repeat_interval_sec`(8 秒)毎に `return_ack_duration_sec`(60 秒)間繰り返す。「同意が伝わっている」ことを繰り返し保証したうえで、以後は控えめなビーコンに引き継ぐ。帰路中であることをそれ以上意識させない。

## ビーコンの距離・方向キュー

- 間隔: 自宅まで `beacon_far_distance_m`(600 m)で 5 秒毎 → `beacon_near_distance_m`(60 m)で 1 秒毎に線形補間(ガイガーカウンター方式)。HRTF が効かなくても確実に伝わる主キュー
- 方向: `pan = sin(自宅方位 − 進行方位)`。真後ろは pan≈0 になる既知の前後曖昧性があるが、間隔の変化(近づけば速くなる)で補完する。完成品ではローパス・リバーブ・PHASE を追加検討

## オーディオセッション

`.playback` + `.mixWithOthers` + `.duckOthers`。ユーザーの音楽・Podcast が主役で、earcon の瞬間だけ音量を下げて割り込む。連続 BGM は安全(環境音マスク)・飽き・主客逆転の理由で採用しない。外音取り込みは AirPods 側の設定を前提とし、オンボーディングで案内する(アプリからは制御不可)。

## 音源の差し替え方針

プロトタイプはコード合成(ライセンス問題ゼロ・即テスト可)。完成品では CC0 素材か自作に差し替える。CC BY はクレジット表記運用が煩雑なため避ける。

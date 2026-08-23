// Android 版のビルド定義。
// いまは `core`(純粋ロジック)だけ。**Android SDK 無しでビルドとテストができる**。
// `services` と `app` は段 3 以降(docs/10)。
rootProject.name = "otosanpo-android"

include(":core")

// Android 版のビルド定義。
// `core` は純粋ロジックで、**Android SDK 無しでもビルドとテストができる**(docs/10)。
// `app` は画面・位置情報・音・常駐サービス。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "otosanpo-android"

include(":core")
include(":app")

// AGP 9 以降は Kotlin の対応が組み込みなので、kotlin("android") は足さない
// (足すとビルドが止まる)。
plugins {
    id("com.android.application") version "9.3.1"
}

android {
    namespace = "dev.otosanpo"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.otosanpo"
        // 29(Android 10)を下限にする。常駐サービスの種別指定が API 29 からで、
        // それ未満を支えるためだけに分岐を増やす価値が無い
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        // **debug のまま配る。** 相手に渡すのは APK 1 つで、Play ストアには出さない。
        // 難読化も署名鍵の管理も、いまは要らない
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 画面は素の View で組む。**外部の UI ライブラリを足さない** —
    // 依存が増えるほど「相手の環境でビルドできない」確率が上がる。
    // この画面は設定とデバッグのためのもので、本体は音(docs/10)
    buildFeatures {
        buildConfig = false
    }
}

// **設定 JSON は iOS 版と同じファイルを使う。** ビルドのたびに assets へ複製する。
// 2 つ持つと、片方だけ直したときに挙動がずれて実測の比較ができなくなる。
//
// 生成先を `src/main/assets` にしているのは、AGP 9 が sourceSet への
// Provider 追加を認めないため。**複製物なので gitignore 対象**
val copyParameters = tasks.register<Copy>("copyParameters") {
    from(rootProject.file("../config/parameters.json"))
    into(file("src/main/assets"))
}

tasks.named("preBuild") { dependsOn(copyParameters) }

dependencies {
    implementation(project(":core"))
}

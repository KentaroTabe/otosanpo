// core は **Android に依存しない**。JVM のライブラリとしてビルドし、
// Android SDK が無い環境でも `gradle :core:test` で検証できる(docs/10)。
// Kotlin は Gradle 本体に埋め込まれている版に合わせる(`gradle -version` の Kotlin 行)。
// 古い版だと新しい JDK の版番号を解釈できず、コンパイラが内部エラーで落ちる。
plugins {
    kotlin("jvm") version "2.2.0"
    kotlin("plugin.serialization") version "2.2.0"
}

repositories {
    mavenCentral()
}

dependencies {
    // **JSON は iOS 版と同じファイルを読む**(config/parameters.json / otosanpo-map.json)。
    // 鍵は snake_case のままで、命名規則の変換で受ける(数値の二重管理を避ける)
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    testImplementation(kotlin("test"))
}

// **JDK は手元にあるものを使う。** toolchain を固定すると、その版が入っていない
// 環境でビルドできなくなる(この Mac には 20 しか無い)。
// Android の app モジュールを足す段(段 3)で、AGP の要求に合わせて改めて決める。
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
    }
}

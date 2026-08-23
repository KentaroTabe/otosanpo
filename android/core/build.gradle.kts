// core は **Android に依存しない**。JVM のライブラリとしてビルドし、
// Android SDK が無い環境でも `gradle :core:test` で検証できる(docs/10)。
// Kotlin は Gradle 本体に埋め込まれている版に合わせる(`gradle -version` の Kotlin 行)。
// 古い版だと新しい JDK の版番号を解釈できず、コンパイラが内部エラーで落ちる。
plugins {
    kotlin("jvm") version "2.4.0"
}

repositories {
    mavenCentral()
}

dependencies {
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

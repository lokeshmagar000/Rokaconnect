plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.rokaconnect.portal"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.rokaconnect.portal"
        minSdk = 29
        targetSdk = 35
        versionCode = 14
        versionName = "0.4.1"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    val bom = platform("androidx.compose:compose-bom:2026.03.01")
    implementation(bom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material:material-icons-core")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    // Liquid glass: Kyant "backdrop" (Apache-2.0) — blur + lens refraction + edge highlight
    testImplementation("junit:junit:4.13.2")
}

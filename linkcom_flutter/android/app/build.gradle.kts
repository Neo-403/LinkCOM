import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名: 读取 android/key.properties (与 keystore 一起放在 android/ 下, 二者均不入库)。
// 未配置或找不到 keystore 时自动退回 debug 签名, 保证任何环境都能构建。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// storeFile 可写成相对路径: 依次在 android/ 与 android/app/ 下探测
val keystoreName = keystoreProperties.getProperty("storeFile").orEmpty()
val keystoreFile: File? = if (keystoreName.isEmpty()) {
    null
} else {
    listOf(
        File(rootProject.projectDir, keystoreName),
        File(project.projectDir, keystoreName),
    ).firstOrNull { it.exists() }
}
val useReleaseSigning = keystorePropertiesFile.exists() && keystoreFile != null

if (keystorePropertiesFile.exists() && keystoreFile == null) {
    logger.warn(
        "key.properties 已存在, 但未找到 keystore 文件 \"$keystoreName\" " +
            "(请放到 linkcom_flutter/android/ 或 android/app/ 下); 本次使用 debug 签名。",
    )
}

android {
    namespace = "com.zwzw.linkcom"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.zwzw.linkcom"
        minSdk = flutter.minSdkVersion // Android 5.0, 支持 OTG + 蓝牙串口
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (useReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 配好 key.properties + keystore 时用正式签名, 否则退回 debug 签名(仍可构建/侧载)
            signingConfig =
                if (useReleaseSigning) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

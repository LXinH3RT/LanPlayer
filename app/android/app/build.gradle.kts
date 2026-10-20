plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.lanplayer.app"
    compileSdk = 35
    ndkVersion = "26.1.10909125"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "dev.lanplayer.app"
        // AAudio requires API 26.  Older devices are out of scope for v1.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                // Build only what we ship: two ABIs keeps the APK under control.
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    // Point this at the prebuilt FFmpeg / libsmb2 layout described
                    // in docs/build.md.
                    "-DLP_FFMPEG_ROOT=${rootProject.projectDir.parentFile}/../native/third_party/ffmpeg",
                    "-DLP_SMB2_ROOT=${rootProject.projectDir.parentFile}/../native/third_party/libsmb2",
                    "-DLP_NO_TESTS=ON",
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            // The FFmpeg shared objects are loaded by our own library.
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
}

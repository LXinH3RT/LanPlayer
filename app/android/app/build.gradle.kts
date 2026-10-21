plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.lanplayer.app"
    compileSdk = 35
    // Pinned by default; CI overrides it with whatever NDK the runner really
    // has (see the "locate the Android NDK" step in build.yml), because Gradle
    // refuses to configure when the named version is not installed.
    ndkVersion = System.getenv("LP_ANDROID_NDK") ?: "26.1.10909125"

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
                // Only the ABI we actually ship and verify.  Every extra ABI
                // multiplies the FFmpeg/libsmb2 cross-build time, and the CI job
                // (and `flutter build apk --target-platform android-arm64`) only
                // produces arm64-v8a anyway.  Add "armeabi-v7a" here AND pass it
                // to scripts/build_android_deps.sh to ship 32-bit ARM too.
                abiFilters += listOf("arm64-v8a")
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

    sourceSets {
        getByName("main") {
            // FFmpeg and libsmb2 are IMPORTED targets in native/CMakeLists.txt,
            // and the Android Gradle plugin does not package imported shared
            // libraries.  scripts/build_android_deps.sh stages them here in the
            // <abi>/lib*.so layout jniLibs expects.
            jniLibs.srcDir("${rootProject.projectDir.parentFile}/../native/third_party/jniLibs")
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
            // The Flutter Gradle plugin turns resource shrinking on for release
            // builds, and the Android Gradle plugin refuses to configure when
            // resources are shrunk without code shrinking:
            //   Removing unused resources requires unused code shrinking to be
            //   turned on.
            // Shrinking is off for v1 (no ProGuard pass, faster CI builds), so
            // resource shrinking has to be off as well.
            isShrinkResources = false
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

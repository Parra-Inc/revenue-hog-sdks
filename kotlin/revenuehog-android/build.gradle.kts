plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

group = "com.revenuehog"
version = "0.2.0"

android {
    namespace = "com.revenuehog.android"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    // ZERO runtime dependencies — org.json and HttpURLConnection ship with
    // the Android platform. Test deps below are JVM-only.
    testImplementation("junit:junit:4.13.2")
    // the mockable android.jar stubs org.json; unit tests need the real one
    testImplementation("org.json:json:20240303")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.revenuehog"
            artifactId = "revenuehog-android"
            version = project.version.toString()
            afterEvaluate { from(components["release"]) }
            pom {
                name.set("RevenueHog Android SDK")
                description.set("Optional user-level attribution for RevenueHog. RevenueHog works without any SDK.")
                url.set("https://github.com/Parra-Inc/revenue-hog-sdks")
                licenses {
                    license {
                        name.set("MIT")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
            }
        }
    }
}

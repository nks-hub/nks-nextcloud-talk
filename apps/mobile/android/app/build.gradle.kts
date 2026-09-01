import groovy.json.JsonOutput
import java.security.MessageDigest
import java.util.Properties
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.attributes.Attribute
import org.gradle.api.tasks.PathSensitivity

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Reads app/google-services.json, which is gitignored. Without that file
    // the build fails loudly rather than producing an app that silently has
    // no FCM.
    id("com.google.gms.google-services")
}

// Release signing is driven by android/key.properties, which is gitignored and
// points at the upload keystore. It is deliberately not backed by a fallback:
// a release signed with the debug key is rejected by Play, and a silent
// fallback would only surface that at upload time.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.isFile) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

fun requiredKeystoreProperty(name: String): String {
    val value = keystoreProperties.getProperty(name)
    require(!value.isNullOrBlank()) {
        "${keystorePropertiesFile.absolutePath} is missing the '$name' entry."
    }
    return value
}

gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any {
        it.project == project && (it.name == "assembleRelease" || it.name == "bundleRelease")
    }
    if (buildsRelease && !keystorePropertiesFile.isFile) {
        throw GradleException(
            "Release builds need the upload keystore, but " +
                "${keystorePropertiesFile.absolutePath} does not exist. Create it with " +
                "storeFile, storePassword, keyAlias and keyPassword pointing at the " +
                "upload keystore.",
        )
    }
}

android {
    namespace = "com.nkshub.nextcloudtalk"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.nkshub.nextcloudtalk"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.isFile) {
                storeFile = rootProject.file(requiredKeystoreProperty("storeFile"))
                storePassword = requiredKeystoreProperty("storePassword")
                keyAlias = requiredKeystoreProperty("keyAlias")
                keyPassword = requiredKeystoreProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

configurations.configureEach {
    exclude(group = "com.google.crypto.tink", module = "tink-android")
}

dependencies {
    // Both push transports talk to Play Services, and only the one the user
    // picked ever registers: the Web Push coordinator is not built while the
    // proxy transport is selected, and vice versa.
    implementation("org.unifiedpush.android:connector:3.3.5")
    implementation("org.unifiedpush.android:embedded-fcm-distributor:3.1.0")
    implementation(platform("com.google.firebase:firebase-bom:34.18.0"))
    implementation("com.google.firebase:firebase-messaging")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
}

data class ReleaseLicenseEntry(
    val coordinate: String,
    val spdx: String,
    val noticeFile: String,
    val noticeSha256: String,
)

data class ReleasePubLicenseEntry(
    val packageName: String,
    val version: String,
    val spdx: String,
    val noticeFile: String,
    val noticeSha256: String,
    val archiveSha256: String,
)

data class ReleaseNoticeEntry(
    val identity: String,
    val spdx: String,
    val noticeFile: String,
    val noticeSha256: String,
)

fun licenseDeclaration(spdx: String): Map<String, Any> =
    if (spdx.contains(" AND ") || spdx.contains(" OR ") || spdx.contains(" WITH ")) {
        linkedMapOf("expression" to spdx)
    } else {
        linkedMapOf("license" to linkedMapOf("id" to spdx))
    }

fun isUnknownSpdx(spdx: String): Boolean {
    val normalized = spdx.uppercase()
    return spdx.isBlank() || normalized == "NOASSERTION" ||
        normalized == "NONE" || normalized.contains("UNKNOWN")
}

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

val releaseLicenseDirectory = layout.projectDirectory.dir("release-licenses")
val releaseLicenseManifest = releaseLicenseDirectory.file("components.tsv")
val releasePubLicenseManifest = releaseLicenseDirectory.file("pub-components.tsv")
val releaseLicenseNotices = releaseLicenseDirectory.dir("notices")
val generatedReleaseLicenseRoot =
    layout.buildDirectory.dir("generated/release-license-assets")
val generatedReleaseLicenseAssets = generatedReleaseLicenseRoot.map { it.dir("assets") }
val releaseLicenseValidator = layout.projectDirectory.file("../../tool/release_license_gate.py")
val mobilePubspecLock = layout.projectDirectory.file("../../pubspec.lock")
val flutterPluginDependencies =
    layout.projectDirectory.file("../../.flutter-plugins-dependencies")
val releaseApk = layout.buildDirectory.file("outputs/apk/release/app-release.apk")
val androidClassesArtifactType = Attribute.of("artifactType", String::class.java)
val releaseRuntimeArtifacts = providers.provider {
    configurations.getByName("releaseRuntimeClasspath").incoming.artifactView {
        attributes.attribute(androidClassesArtifactType, "android-classes-jar")
    }.artifacts
}

val generateReleaseLicenseAssets = tasks.register("generateReleaseLicenseAssets") {
    inputs.file(releaseLicenseManifest)
    inputs.file(releasePubLicenseManifest)
    inputs.dir(releaseLicenseNotices)
    inputs.files(releaseRuntimeArtifacts.map { it.artifactFiles })
        .withPropertyName("releaseRuntimeArtifacts")
        .withPathSensitivity(PathSensitivity.NONE)
    inputs.property(
        "releaseRuntimeCoordinates",
        releaseRuntimeArtifacts.map { collection ->
            collection.artifacts.mapNotNull { artifact ->
                val id = artifact.id.componentIdentifier as? ModuleComponentIdentifier
                    ?: return@mapNotNull null
                "${id.group}:${id.module}:${id.version}"
            }.sorted()
        },
    )
    outputs.dir(generatedReleaseLicenseRoot)

    doLast {
        val manifestFile = releaseLicenseManifest.asFile
        val entries = manifestFile.readLines(Charsets.UTF_8)
            .map(String::trim)
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .mapIndexed { index, line ->
                val columns = line.split('\t')
                require(columns.size == 4) {
                    "${manifestFile.name}:${index + 1}: expected 4 tab-separated columns"
                }
                ReleaseLicenseEntry(
                    coordinate = columns[0],
                    spdx = columns[1],
                    noticeFile = columns[2],
                    noticeSha256 = columns[3],
                )
            }
        val duplicates = entries.groupBy { it.coordinate }.filterValues { it.size > 1 }.keys
        require(duplicates.isEmpty()) { "Duplicate release-license coordinates: $duplicates" }
        require(entries.none { isUnknownSpdx(it.spdx) }) {
            "Release-license manifest contains an unknown SPDX license"
        }

        val pubManifestFile = releasePubLicenseManifest.asFile
        val pubEntries = pubManifestFile.readLines(Charsets.UTF_8)
            .map(String::trim)
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .mapIndexed { index, line ->
                val columns = line.split('\t')
                require(columns.size == 6) {
                    "${pubManifestFile.name}:${index + 1}: expected 6 tab-separated columns"
                }
                ReleasePubLicenseEntry(
                    packageName = columns[0],
                    version = columns[1],
                    spdx = columns[2],
                    noticeFile = columns[3],
                    noticeSha256 = columns[4],
                    archiveSha256 = columns[5],
                )
            }
        val duplicatePubPackages = pubEntries.groupBy { it.packageName }
            .filterValues { it.size > 1 }
            .keys
        require(duplicatePubPackages.isEmpty()) {
            "Duplicate release-license Pub packages: $duplicatePubPackages"
        }
        require(pubEntries.none { isUnknownSpdx(it.spdx) }) {
            "Pub release-license manifest contains an unknown SPDX license"
        }
        val sha256Pattern = Regex("^[0-9a-f]{64}$")
        require(pubEntries.all { sha256Pattern.matches(it.archiveSha256) }) {
            "Pub release-license manifest contains an invalid archive SHA-256"
        }

        val artifacts = releaseRuntimeArtifacts.get().artifacts
            .mapNotNull { artifact ->
                val id = artifact.id.componentIdentifier as? ModuleComponentIdentifier
                    ?: return@mapNotNull null
                "${id.group}:${id.module}:${id.version}" to artifact.file
            }
            .groupBy({ it.first }, { it.second })
        val actualCoordinates = artifacts.keys
        val declaredCoordinates = entries.map { it.coordinate }.toSet()
        val outputRoot = generatedReleaseLicenseRoot.get().asFile
        outputRoot.mkdirs()
        outputRoot.resolve("resolved-components.txt").writeText(
            actualCoordinates.sorted().joinToString(separator = "\n", postfix = "\n"),
            Charsets.UTF_8,
        )
        val missing = actualCoordinates - declaredCoordinates
        val stale = declaredCoordinates - actualCoordinates
        require(missing.isEmpty() && stale.isEmpty()) {
            buildString {
                appendLine("Release-license manifest does not match releaseRuntimeClasspath.")
                if (missing.isNotEmpty()) appendLine("Missing: ${missing.sorted().joinToString()}")
                if (stale.isNotEmpty()) appendLine("Stale: ${stale.sorted().joinToString()}")
            }
        }

        val outputDirectory = outputRoot.resolve("assets/release_licenses")
        outputDirectory.deleteRecursively()
        outputDirectory.mkdirs()
        val noticeOutput = outputDirectory.resolve("THIRD_PARTY_NOTICES.txt")
        val mavenComponents = entries.sortedBy { it.coordinate }.map { entry ->
            val notice = releaseLicenseNotices.file(entry.noticeFile).asFile
            require(notice.isFile) { "Missing notice file for ${entry.coordinate}: ${entry.noticeFile}" }
            val noticeHash = sha256(notice)
            require(noticeHash == entry.noticeSha256) {
                "Notice hash mismatch for ${entry.coordinate}: expected ${entry.noticeSha256}, got $noticeHash"
            }
            val componentArtifacts = artifacts.getValue(entry.coordinate).distinct()
            require(componentArtifacts.isNotEmpty()) {
                "No runtime artifact was resolved for ${entry.coordinate}"
            }
            val parts = entry.coordinate.split(':')
            linkedMapOf<String, Any>(
                "type" to "library",
                "group" to parts[0],
                "name" to parts[1],
                "version" to parts[2],
                "purl" to "pkg:maven/${parts[0]}/${parts[1]}@${parts[2]}",
                "hashes" to componentArtifacts.sortedBy(File::getName).map { artifact ->
                    linkedMapOf("alg" to "SHA-256", "content" to sha256(artifact))
                },
                "licenses" to listOf(licenseDeclaration(entry.spdx)),
                "properties" to listOf(
                    linkedMapOf(
                        "name" to "com.nkshub.nextcloudtalk.noticeSha256",
                        "value" to noticeHash,
                    ),
                ),
            )
        }

        val pubComponents = pubEntries.sortedBy { it.packageName }.map { entry ->
            val notice = releaseLicenseNotices.file(entry.noticeFile).asFile
            require(notice.isFile) {
                "Missing notice file for ${entry.packageName}: ${entry.noticeFile}"
            }
            val noticeHash = sha256(notice)
            require(noticeHash == entry.noticeSha256) {
                "Notice hash mismatch for ${entry.packageName}: expected ${entry.noticeSha256}, got $noticeHash"
            }
            linkedMapOf<String, Any>(
                "type" to "library",
                "group" to "pub.dev",
                "name" to entry.packageName,
                "version" to entry.version,
                "purl" to "pkg:pub/${entry.packageName}@${entry.version}",
                "hashes" to listOf(
                    linkedMapOf("alg" to "SHA-256", "content" to entry.archiveSha256),
                ),
                "licenses" to listOf(licenseDeclaration(entry.spdx)),
                "properties" to listOf(
                    linkedMapOf(
                        "name" to "com.nkshub.nextcloudtalk.noticeSha256",
                        "value" to noticeHash,
                    ),
                ),
            )
        }

        val noticeEntries = entries.map {
            ReleaseNoticeEntry(it.coordinate, it.spdx, it.noticeFile, it.noticeSha256)
        } + pubEntries.map {
            ReleaseNoticeEntry(
                "pub:${it.packageName}:${it.version}",
                it.spdx,
                it.noticeFile,
                it.noticeSha256,
            )
        }

        val noticeGroups = noticeEntries.sortedBy { it.identity }.groupBy {
            Triple(it.spdx, it.noticeFile, it.noticeSha256)
        }
        noticeOutput.bufferedWriter(Charsets.UTF_8).use { writer ->
            writer.append("Third-party notices for Android release runtime dependencies\n\n")
            for ((noticeKey, groupEntries) in noticeGroups) {
                val notice = releaseLicenseNotices.file(noticeKey.second).asFile
                writer.append("----- BEGIN COMPONENT NOTICE -----\n")
                for (entry in groupEntries) {
                    writer.append("Component: ${entry.identity}\n")
                }
                writer.append("License: ${noticeKey.first}\n")
                writer.append("Notice-SHA256: ${noticeKey.third}\n")
                writer.append("Notice-Bytes: ${notice.length()}\n")
                writer.append("----- NOTICE TEXT -----\n")
                val noticeText = notice.readText(Charsets.UTF_8)
                writer.append(noticeText)
                if (!noticeText.endsWith('\n')) writer.append('\n')
                writer.append("----- END COMPONENT NOTICE -----\n\n")
            }
        }
        val sbom = linkedMapOf<String, Any>(
            "bomFormat" to "CycloneDX",
            "specVersion" to "1.6",
            "version" to 1,
            "components" to mavenComponents + pubComponents,
        )
        outputDirectory.resolve("SBOM.json").writeText(
            JsonOutput.prettyPrint(JsonOutput.toJson(sbom)) + "\n",
            Charsets.UTF_8,
        )
    }
}

val validateReleaseLicenseArtifact = tasks.register<Exec>("validateReleaseLicenseArtifact") {
    group = "verification"
    description = "Validates notices and the SBOM in the assembled release APK."
    inputs.file(releaseLicenseValidator)
    inputs.file(mobilePubspecLock)
    inputs.file(flutterPluginDependencies)
    inputs.file(releaseApk)
    val python = if (System.getProperty("os.name").startsWith("Windows")) {
        "python"
    } else {
        "python3"
    }
    doFirst {
        require(releaseApk.get().asFile.isFile) {
            "Release APK does not exist: ${releaseApk.get().asFile}"
        }
    }
    commandLine(
        python,
        releaseLicenseValidator.asFile.absolutePath,
        releaseApk.get().asFile.absolutePath,
        "--lockfile",
        mobilePubspecLock.asFile.absolutePath,
        "--plugins",
        flutterPluginDependencies.asFile.absolutePath,
    )
}

android.sourceSets.getByName("release").assets.srcDir(
    generatedReleaseLicenseAssets.get().asFile,
)
tasks.matching { it.name == "mergeReleaseAssets" }.configureEach {
    dependsOn(generateReleaseLicenseAssets)
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy(validateReleaseLicenseArtifact)
}

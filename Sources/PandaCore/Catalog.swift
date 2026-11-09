import Foundation

/// A cache folder in the home folder. Paths are relative to home.
struct CacheSpec {
    let id: String
    let title: String
    let ecosystem: Ecosystem
    let paths: [String]
    let tier: Tier
    let rebuild: Rebuild
}

/// A build output folder inside a project. We find it only when a marker file sits next to it.
struct ArtifactRule {
    let names: [String]
    let namePrefixes: [String]
    /// Any one of these must exist in the project folder. "*.ext" matches a file suffix.
    let markers: [String]
    /// Any one of these must exist inside the output folder. Empty means no check.
    let innerMarkers: [String]
    let ecosystem: Ecosystem
    let label: String
    /// `.safe` means safe when the project is stale. `.review` means the user must always choose.
    let tier: Tier
    let rebuild: Rebuild

    init(_ names: [String], prefixes: [String] = [], markers: [String], inner: [String] = [],
         _ ecosystem: Ecosystem, _ label: String, tier: Tier = .safe, rebuild: Rebuild = .minutes) {
        self.names = names
        self.namePrefixes = prefixes
        self.markers = markers
        self.innerMarkers = inner
        self.ecosystem = ecosystem
        self.label = label
        self.tier = tier
        self.rebuild = rebuild
    }

    func matches(name: String) -> Bool {
        names.contains(name) || namePrefixes.contains { name.hasPrefix($0) }
    }
}

/// The list of things we know how to clean.
/// To add a language, add rows here. Phase 1 covers ten ecosystems.
/// The cache locations follow public tool documentation and the Mole project (see NOTICE).
enum Catalog {

    // MARK: Global caches

    static let caches: [CacheSpec] = [
        // Swift, Obj-C and Xcode
        CacheSpec(id: "xcode.derived", title: "Xcode build data", ecosystem: .swift,
                  paths: ["Library/Developer/Xcode/DerivedData"], tier: .safe, rebuild: .minutes),
        CacheSpec(id: "xcode.docs", title: "Xcode documentation cache", ecosystem: .swift,
                  paths: ["Library/Developer/Xcode/DocumentationCache"], tier: .safe, rebuild: .seconds),
        CacheSpec(id: "xcode.simcache", title: "Simulator caches", ecosystem: .swift,
                  paths: ["Library/Developer/CoreSimulator/Caches"], tier: .safe, rebuild: .seconds),
        CacheSpec(id: "xcode.devsupport", title: "iOS device support files", ecosystem: .swift,
                  paths: ["Library/Developer/Xcode/iOS DeviceSupport"], tier: .review, rebuild: .minutes),
        CacheSpec(id: "swiftpm.cache", title: "Swift package cache", ecosystem: .swift,
                  paths: ["Library/Caches/org.swift.swiftpm"], tier: .safe, rebuild: .download),
        CacheSpec(id: "cocoapods.cache", title: "CocoaPods cache", ecosystem: .swift,
                  paths: ["Library/Caches/CocoaPods"], tier: .safe, rebuild: .download),

        // JavaScript and TypeScript
        CacheSpec(id: "npm.cache", title: "npm cache", ecosystem: .javascript,
                  paths: [".npm/_cacache"], tier: .safe, rebuild: .download),
        CacheSpec(id: "yarn.cache", title: "Yarn classic cache", ecosystem: .javascript,
                  paths: ["Library/Caches/Yarn"], tier: .safe, rebuild: .download),
        CacheSpec(id: "bun.cache", title: "Bun cache", ecosystem: .javascript,
                  paths: [".bun/install/cache"], tier: .safe, rebuild: .download),
        CacheSpec(id: "pnpm.store", title: "pnpm store", ecosystem: .javascript,
                  paths: ["Library/pnpm/store", "Library/Caches/pnpm"], tier: .review, rebuild: .download),
        CacheSpec(id: "playwright.browsers", title: "Playwright browsers", ecosystem: .javascript,
                  paths: ["Library/Caches/ms-playwright"], tier: .review, rebuild: .download),

        // Python
        CacheSpec(id: "pip.cache", title: "pip cache", ecosystem: .python,
                  paths: ["Library/Caches/pip"], tier: .safe, rebuild: .download),
        CacheSpec(id: "precommit.cache", title: "pre-commit environments", ecosystem: .python,
                  paths: [".cache/pre-commit"], tier: .safe, rebuild: .download),
        CacheSpec(id: "poetry.cache", title: "Poetry cache", ecosystem: .python,
                  paths: ["Library/Caches/pypoetry"], tier: .review, rebuild: .download),
        CacheSpec(id: "hf.cache", title: "Hugging Face models", ecosystem: .python,
                  paths: [".cache/huggingface"], tier: .review, rebuild: .download),
        CacheSpec(id: "torch.cache", title: "PyTorch downloads", ecosystem: .python,
                  paths: [".cache/torch"], tier: .review, rebuild: .download),

        // Java and Kotlin
        CacheSpec(id: "gradle.caches", title: "Gradle cache", ecosystem: .jvm,
                  paths: [".gradle/caches"], tier: .review, rebuild: .download),
        CacheSpec(id: "maven.repo", title: "Maven repository", ecosystem: .jvm,
                  paths: [".m2/repository"], tier: .review, rebuild: .download),
        CacheSpec(id: "android.cache", title: "Android tool cache", ecosystem: .jvm,
                  paths: [".android/cache"], tier: .safe, rebuild: .download),
        CacheSpec(id: "konan", title: "Kotlin/Native dependencies", ecosystem: .jvm,
                  paths: [".konan/dependencies"], tier: .review, rebuild: .download),
        CacheSpec(id: "jetbrains.cache", title: "JetBrains IDE caches", ecosystem: .jvm,
                  paths: ["Library/Caches/JetBrains"], tier: .review, rebuild: .minutes),

        // C# and .NET
        CacheSpec(id: "nuget.http", title: "NuGet download cache", ecosystem: .dotnet,
                  paths: [".local/share/NuGet/http-cache", ".local/share/NuGet/plugins-cache"],
                  tier: .safe, rebuild: .download),
        CacheSpec(id: "nuget.packages", title: "NuGet packages", ecosystem: .dotnet,
                  paths: [".nuget/packages"], tier: .review, rebuild: .download),

        // C and C++
        CacheSpec(id: "ccache", title: "ccache", ecosystem: .cpp,
                  paths: [".ccache", "Library/Caches/ccache", ".cache/ccache"], tier: .safe, rebuild: .minutes),
        CacheSpec(id: "clangd", title: "clangd index", ecosystem: .cpp,
                  paths: [".cache/clangd", "Library/Caches/org.llvm.clangd"], tier: .safe, rebuild: .minutes),
        CacheSpec(id: "vcpkg", title: "vcpkg downloads", ecosystem: .cpp,
                  paths: [".cache/vcpkg"], tier: .safe, rebuild: .download),
        CacheSpec(id: "conan", title: "Conan packages", ecosystem: .cpp,
                  paths: [".conan2/p"], tier: .review, rebuild: .download),

        // Go (the go build cache is handled in Scanner with the owning tool)

        // Rust
        CacheSpec(id: "cargo.registry", title: "Cargo registry cache", ecosystem: .rust,
                  paths: [".cargo/registry/cache", ".cargo/registry/src"], tier: .safe, rebuild: .download),
        CacheSpec(id: "cargo.git", title: "Cargo git checkouts", ecosystem: .rust,
                  paths: [".cargo/git/db", ".cargo/git/checkouts"], tier: .review, rebuild: .download),

        // PHP
        CacheSpec(id: "composer.cache", title: "Composer cache", ecosystem: .php,
                  paths: [".composer/cache", ".cache/composer", "Library/Caches/composer"],
                  tier: .safe, rebuild: .download),

        // Ruby
        CacheSpec(id: "bundler.cache", title: "Bundler cache", ecosystem: .ruby,
                  paths: [".bundle/cache"], tier: .safe, rebuild: .download),

        // Dart and Flutter. Never touch .pub-cache/bin or global_packages (see PathGuard).
        CacheSpec(id: "dart.pub.hosted", title: "Dart package cache", ecosystem: .dart,
                  paths: [".pub-cache/hosted"], tier: .review, rebuild: .download),
        CacheSpec(id: "dart.pub.git", title: "Dart git packages", ecosystem: .dart,
                  paths: [".pub-cache/git"], tier: .review, rebuild: .download),
        CacheSpec(id: "dart.analysis", title: "Dart analysis cache", ecosystem: .dart,
                  paths: [".dartServer/.analysis-driver"], tier: .safe, rebuild: .minutes),

        // Elixir and Erlang. Never touch ~/.mix (installed archives) or ~/.hex/hex.config (see PathGuard).
        CacheSpec(id: "hex.packages", title: "Hex package cache", ecosystem: .elixir,
                  paths: [".hex/packages"], tier: .safe, rebuild: .download),
        CacheSpec(id: "rebar3.cache", title: "rebar3 cache", ecosystem: .elixir,
                  paths: [".cache/rebar3"], tier: .safe, rebuild: .download),
    ]

    // MARK: Project build outputs

    static let artifacts: [ArtifactRule] = [
        // JavaScript and TypeScript
        ArtifactRule(["node_modules"], markers: ["package.json"], .javascript, "node_modules"),
        ArtifactRule([".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache"],
                     markers: ["package.json"], .javascript, "Build cache", rebuild: .seconds),

        // Python. A venv can hold packages that are not in a lock file, so the user must choose.
        ArtifactRule([".venv", "venv"],
                     markers: ["pyproject.toml", "requirements.txt", "Pipfile", "setup.py", "uv.lock"],
                     .python, "Virtual environment", tier: .review),
        ArtifactRule([".tox", ".nox"], markers: ["tox.ini", "noxfile.py", "pyproject.toml"],
                     .python, "Test environments"),

        // Rust
        ArtifactRule(["target"], markers: ["Cargo.toml"], .rust, "Build output"),

        // Java and Kotlin
        ArtifactRule(["target"], markers: ["pom.xml"], .jvm, "Maven build output"),
        ArtifactRule(["build", ".gradle"],
                     markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                     .jvm, "Gradle build output"),

        // C# and .NET
        ArtifactRule(["obj", ".vs"], markers: ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"],
                     .dotnet, "Build output"),
        ArtifactRule(["bin"], markers: ["*.csproj", "*.fsproj", "*.vbproj"],
                     .dotnet, "Build output (bin)", tier: .review),

        // C and C++. The CMake cache file proves that the folder is a build folder.
        ArtifactRule(["build", "builddir"], prefixes: ["cmake-build-"],
                     markers: ["CMakeLists.txt", "meson.build"],
                     inner: ["CMakeCache.txt", "meson-private", "build.ninja"],
                     .cpp, "Build output"),

        // Swift and Obj-C
        ArtifactRule([".build"], markers: ["Package.swift"], .swift, "Swift package build"),
        ArtifactRule(["Pods"], markers: ["Podfile"], .swift, "CocoaPods"),

        // Dart and Flutter. The Flutter build folder needs a known output file or folder inside.
        ArtifactRule([".dart_tool"], markers: ["pubspec.yaml"], .dart, "Dart tool cache", rebuild: .seconds),
        ArtifactRule(["build"], markers: ["pubspec.yaml"],
                     inner: [".last_build_id", "app", "ios", "web", "macos", "linux", "windows",
                             "flutter_assets", "unit_test_assets", "cache", "test_cache"],
                     .dart, "Flutter build output"),

        // Elixir and Erlang
        ArtifactRule(["_build"], markers: ["mix.exs", "rebar.config"], .elixir, "Compiled output"),
        ArtifactRule(["deps"], markers: ["mix.exs"], .elixir, "Dependencies", rebuild: .download),
        ArtifactRule([".elixir_ls"], markers: ["mix.exs"], .elixir, "Language server cache"),

        // PHP
        ArtifactRule(["vendor"], markers: ["composer.json"], .php, "Composer packages"),
    ]

    static let artifactNames: Set<String> = Set(artifacts.flatMap { $0.names })
    static let artifactPrefixes: [String] = artifacts.flatMap { $0.namePrefixes }

    static func isArtifactName(_ name: String) -> Bool {
        artifactNames.contains(name) || artifactPrefixes.contains { name.hasPrefix($0) }
    }

    /// Folders that a project walk never enters.
    static let skipDescend: Set<String> = [
        ".git", "node_modules", "Library", ".Trash", "vendor", "Pods", "target", "build", "dist", "out",
        "bin", "obj", "__pycache__", "venv", ".venv", "site-packages", ".cache", ".gradle", ".build",
    ]
}

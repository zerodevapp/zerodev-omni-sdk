rootProject.name = "privy-signer"
includeBuild("../../../bindings/kotlin") {
    dependencySubstitution {
        substitute(module("dev.zerodev:zerodev-aa")).using(project(":"))
    }
}

rootProject.name = "gasless-transfer"
includeBuild("../../../bindings/kotlin") {
    dependencySubstitution {
        substitute(module("dev.zerodev:zerodev-aa")).using(project(":"))
    }
}

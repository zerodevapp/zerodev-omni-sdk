rootProject.name = "gasless-transfer-7702"
includeBuild("../../../bindings/kotlin") {
    dependencySubstitution {
        substitute(module("dev.zerodev:zerodev-aa")).using(project(":"))
    }
}

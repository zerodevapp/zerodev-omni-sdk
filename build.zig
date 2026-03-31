const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get zigeth dependency
    const zigeth_dep = b.dependency("zigeth", .{
        .target = target,
        .optimize = optimize,
    });
    const zigeth_mod = zigeth_dep.module("zigeth");
    const zigeth_artifact = zigeth_dep.artifact("zigeth_lib");

    // Get secp256k1 through zigeth's dependency
    const secp256k1_dep = zigeth_dep.builder.dependency("zig_eth_secp256k1", .{
        .target = target,
        .optimize = optimize,
    });
    const secp256k1_artifact = secp256k1_dep.artifact("secp256k1");
    b.installArtifact(secp256k1_artifact);

    // ---- Internal modules (shared between lib, c_api, and tests) ----

    const transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transport/json_rpc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigeth", .module = zigeth_mod },
        },
    });

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigeth", .module = zigeth_mod },
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const signers_mod = b.createModule(.{
        .root_source_file = b.path("src/signers/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigeth", .module = zigeth_mod },
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const validators_mod = b.createModule(.{
        .root_source_file = b.path("src/validators/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigeth", .module = zigeth_mod },
            .{ .name = "signers", .module = signers_mod },
        },
    });

    // ---- Library module (for Zig consumers) ----

    const lib_mod = b.addModule("zerodev_omni_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("zigeth", zigeth_mod);

    // ---- C API module (for FFI consumers) ----

    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_mod.addImport("zigeth", zigeth_mod);
    c_api_mod.addImport("transport", transport_mod);
    c_api_mod.addImport("signers", signers_mod);

    // Static library
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zerodev_aa",
        .root_module = c_api_mod,
    });
    static_lib.bundle_compiler_rt = true;
    static_lib.linkLibrary(zigeth_artifact);
    b.installArtifact(static_lib);

    // Dynamic library
    const dynamic_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zerodev_aa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    dynamic_lib.root_module.addImport("zigeth", zigeth_mod);
    dynamic_lib.root_module.addImport("transport", transport_mod);
    dynamic_lib.root_module.addImport("signers", signers_mod);
    dynamic_lib.linkLibrary(zigeth_artifact);
    b.installArtifact(dynamic_lib);

    // Install C header
    b.installFile("include/aa.h", "include/aa.h");

    // ---- Unit tests (pure computation, no networking) ----

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigeth", .module = zigeth_mod },
                .{ .name = "signers", .module = signers_mod },
            },
        }),
    });
    lib_tests.linkLibC();
    lib_tests.linkLibrary(zigeth_artifact);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // ---- E2E tests (require local Anvil + Alto) ----

    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/full_pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigeth", .module = zigeth_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "validators", .module = validators_mod },
                .{ .name = "signers", .module = signers_mod },
            },
        }),
    });
    e2e_tests.linkLibC();
    e2e_tests.linkLibrary(zigeth_artifact);
    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    const e2e_step = b.step("test-e2e", "Run E2E tests (requires local Anvil + Alto)");
    e2e_step.dependOn(&run_e2e_tests.step);

    // ---- Live tests (against ZeroDev Sepolia) ----

    const live_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/live_sepolia.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigeth", .module = zigeth_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "validators", .module = validators_mod },
                .{ .name = "signers", .module = signers_mod },
            },
        }),
    });
    live_tests.linkLibC();
    live_tests.linkLibrary(zigeth_artifact);
    const run_live_tests = b.addRunArtifact(live_tests);

    const live_step = b.step("test-live", "Run live tests against ZeroDev Sepolia");
    live_step.dependOn(&run_live_tests.step);

    // ---- C API live tests (exercises aa_send_userop orchestrator) ----

    const c_api_test_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zigeth", .module = zigeth_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "signers", .module = signers_mod },
        },
    });

    const live_capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/live_c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c_api", .module = c_api_test_mod },
            },
        }),
    });
    live_capi_tests.linkLibC();
    live_capi_tests.linkLibrary(zigeth_artifact);
    const run_live_capi_tests = b.addRunArtifact(live_capi_tests);

    const live_capi_step = b.step("test-live-capi", "Run C API live tests against ZeroDev Sepolia");
    live_capi_step.dependOn(&run_live_capi_tests.step);
}

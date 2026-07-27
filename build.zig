const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const static_only = b.option(bool, "static-only", "Only build static library (skip dynamic — needed for iOS cross-compilation)") orelse false;

    // Get zabi dependency (replaces zigeth + zig_eth_secp256k1).
    const zabi_dep = b.dependency("zabi", .{
        .target = target,
        .optimize = optimize,
    });
    const zabi_mod = zabi_dep.module("zabi");

    // ---- Internal modules (shared between lib, c_api, and tests) ----

    // Primitives module — Address, Hash, Signature wrappers + hex utils.
    // Its API mirrors what zigeth used to expose so the rest of the codebase
    // doesn't need to know about zabi's raw byte types.
    const primitives_mod = b.createModule(.{
        .root_source_file = b.path("src/core/primitives.zig"),
        .target = target,
        .optimize = optimize,
    });

    const transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transport/json_rpc.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "primitives", .module = primitives_mod },
        },
    });

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zabi", .module = zabi_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const signers_mod = b.createModule(.{
        .root_source_file = b.path("src/signers/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zabi", .module = zabi_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const validators_mod = b.createModule(.{
        .root_source_file = b.path("src/validators/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zabi", .module = zabi_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "signers", .module = signers_mod },
        },
    });

    // ---- Library module (for Zig consumers) ----

    const lib_mod = b.addModule("zerodev_omni_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("zabi", zabi_mod);
    lib_mod.addImport("primitives", primitives_mod);

    // ---- C API module (for FFI consumers) ----

    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_mod.addImport("zabi", zabi_mod);
    c_api_mod.addImport("primitives", primitives_mod);
    c_api_mod.addImport("transport", transport_mod);
    c_api_mod.addImport("signers", signers_mod);

    // Static library
    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zerodev_aa",
        .root_module = c_api_mod,
    });
    static_lib.bundle_compiler_rt = true;
    b.installArtifact(static_lib);

    // Dynamic library (skip for iOS/cross-compilation with -Dstatic-only)
    if (!static_only) {
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
        dynamic_lib.root_module.addImport("zabi", zabi_mod);
        dynamic_lib.root_module.addImport("primitives", primitives_mod);
        dynamic_lib.root_module.addImport("transport", transport_mod);
        dynamic_lib.root_module.addImport("signers", signers_mod);
        b.installArtifact(dynamic_lib);
    }

    // Install C header
    b.installFile("include/aa.h", "include/aa.h");

    // ---- Unit tests (pure computation, no networking) ----

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zabi", .module = zabi_mod },
                .{ .name = "primitives", .module = primitives_mod },
                .{ .name = "signers", .module = signers_mod },
            },
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Transport tests live in a separate compilation because the transport
    // module is referenced by other modules through a named import — its
    // tests don't surface in the root compilation's test list.
    const transport_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transport/json_rpc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "primitives", .module = primitives_mod },
            },
        }),
    });
    const run_transport_tests = b.addRunArtifact(transport_tests);

    // c_api tests: same reason as transport — c_api isn't imported by
    // src/root.zig, so its inline tests need their own compilation.
    const c_api_tests = b.addTest(.{
        .root_module = c_api_mod,
    });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_transport_tests.step);
    test_step.dependOn(&run_c_api_tests.step);

    // ---- E2E tests (require local Anvil + Alto) ----

    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/full_pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zabi", .module = zabi_mod },
                .{ .name = "primitives", .module = primitives_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "validators", .module = validators_mod },
                .{ .name = "signers", .module = signers_mod },
            },
        }),
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    const e2e_step = b.step("test-e2e", "Run E2E tests (requires local Anvil + Alto)");
    e2e_step.dependOn(&run_e2e_tests.step);

    // ---- Live tests (against ZeroDev Sepolia) ----

    const live_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/live_sepolia.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zabi", .module = zabi_mod },
                .{ .name = "primitives", .module = primitives_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "validators", .module = validators_mod },
                .{ .name = "signers", .module = signers_mod },
            },
        }),
    });
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
            .{ .name = "zabi", .module = zabi_mod },
            .{ .name = "primitives", .module = primitives_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "signers", .module = signers_mod },
        },
    });

    const live_capi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/live_c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c_api", .module = c_api_test_mod },
            },
        }),
    });
    const run_live_capi_tests = b.addRunArtifact(live_capi_tests);

    const live_capi_step = b.step("test-live-capi", "Run C API live tests against ZeroDev Sepolia");
    live_capi_step.dependOn(&run_live_capi_tests.step);

    const live_7702_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/live_7702.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c_api", .module = c_api_test_mod },
            },
        }),
    });
    const run_live_7702_tests = b.addRunArtifact(live_7702_tests);

    const live_7702_step = b.step("test-live-7702", "Run EIP-7702 live tests against ZeroDev Sepolia");
    live_7702_step.dependOn(&run_live_7702_tests.step);
}

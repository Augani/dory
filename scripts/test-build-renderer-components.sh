#!/bin/bash
# Focused component gates for the dual VirGL2 + Venus Metal build and packaging graph.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dory-renderer-components.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

python3 "$ROOT/.github/scripts/test-renderer-production-tuple.py"

for script in \
  "$ROOT/scripts/build-renderer-production-dependencies.sh" \
  "$ROOT/scripts/build-virglrenderer.sh" \
  "$ROOT/scripts/prepare-renderer-production-host.sh" \
  "$ROOT/scripts/assemble-renderer-production-worker.sh" \
  "$ROOT/scripts/xcode-package-renderer-production.sh"; do
  bash -n "$script"
done

# Pruning is the only packaging mutation: it removes legacy phase-owned renderer payloads while
# preserving unrelated bundle content. This fixture deliberately needs no VM or renderer build.
RUNNER="$WORK/DoryHVRunner.app"
mkdir -p "$RUNNER/Contents/MacOS" "$RUNNER/Contents/Frameworks" \
  "$RUNNER/Contents/Resources/vulkan/icd.d"
python3 - "$RUNNER/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "dory-hv",
    "CFBundleIdentifier": "com.pythonxi.Dory.HVRunner",
    "CFBundlePackageType": "APPL",
}))
PY
printf '#!/bin/sh\nexit 0\n' >"$RUNNER/Contents/MacOS/dory-hv"
chmod 755 "$RUNNER/Contents/MacOS/dory-hv"
printf 'legacy\n' >"$RUNNER/Contents/Frameworks/libvirglrenderer.dylib"
printf 'legacy\n' >"$RUNNER/Contents/Frameworks/libMoltenVK.dylib"
printf '{}\n' >"$RUNNER/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"
printf 'legacy inventory\n' >"$RUNNER/Contents/Resources/renderer-production-inventory.json"
printf 'stale qualification\n' \
  >"$RUNNER/Contents/Resources/renderer-bootstrap-qualification.json"
printf 'stale signature\n' \
  >"$RUNNER/Contents/Resources/renderer-bootstrap-qualification.json.sig"
printf 'preserve\n' >"$RUNNER/Contents/Resources/unrelated.txt"

python3 "$ROOT/scripts/package-renderer-production-bundle.py" prune --runner-app "$RUNNER"
test ! -e "$RUNNER/Contents/Frameworks/libvirglrenderer.dylib"
test ! -e "$RUNNER/Contents/Frameworks/libMoltenVK.dylib"
test ! -e "$RUNNER/Contents/Resources/vulkan"
test ! -e "$RUNNER/Contents/Resources/renderer-production-inventory.json"
test ! -e "$RUNNER/Contents/Resources/renderer-bootstrap-qualification.json"
test ! -e "$RUNNER/Contents/Resources/renderer-bootstrap-qualification.json.sig"
test -f "$RUNNER/Contents/Resources/unrelated.txt"

# Removed schema-v1 and dynamic-host flags must not be accepted by current producers/packager.
if "$ROOT/scripts/build-virglrenderer.sh" --skip-tests >/dev/null 2>&1; then
  echo "test-build-renderer-components: --skip-tests unexpectedly succeeded" >&2
  exit 1
fi
if python3 "$ROOT/scripts/package-renderer-production-bundle.py" package \
    --runner-app "$RUNNER" --host-root "$WORK/host" --host-inventory "$WORK/host.json" \
    --sign-identity - --expected-team - --allow-adhoc-test >/dev/null 2>&1; then
  echo "test-build-renderer-components: legacy dynamic packaging CLI unexpectedly succeeded" >&2
  exit 1
fi

# The production assembler rejects missing closure inputs before invoking Xcode or SwiftPM.
if "$ROOT/scripts/assemble-renderer-production-worker.sh" \
    --runner-app "$RUNNER" \
    --link-root "$WORK/missing-static-link" \
    --link-inventory "$WORK/missing-static-link/inventory.json" \
    --scratch-path "$WORK/scratch" \
    --sign-identity - \
    --expected-team - \
    --allow-adhoc-test >"$WORK/missing-input.log" 2>&1; then
  echo "test-build-renderer-components: missing static inputs unexpectedly succeeded" >&2
  exit 1
fi
grep 'static link root is unavailable' "$WORK/missing-input.log" >/dev/null

# A canonical profile inventory is not permission to carry extra dynamic renderer authority.
LINK="$WORK/static-link"
LINK_INVENTORY="$LINK/renderer-static-link-inventory.json"
mkdir -p "$LINK"
python3 - "$LINK" "$ROOT/Config/DoryRendererProductionTuple.json" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
definition = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
components = definition["artifactProfiles"]["staticLinkClosure"]
for paths in components.values():
    for relative in paths:
        if relative == "renderer-static-link.json":
            continue
        artifact = root.joinpath(*pathlib.PurePosixPath(relative).parts)
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(f"fixture:{relative}\n".encode())
paths = ["lib/libvirglrenderer.a", "lib/libepoxy.a", "lib/libMoltenVK.a"]
contract = {
    "appleFrameworks": [
        "AppKit", "CoreGraphics", "Foundation", "IOKit", "IOSurface", "Metal", "QuartzCore"
    ],
    "architecture": "arm64",
    "archives": [
        {"path": path, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
        for path in paths
    ],
    "cxxRuntime": "c++",
    "forceLoadArchives": paths,
    "kind": "dev.dory.renderer-static-link-contract",
    "requiredCompileDefinitions": [
        "DORY_VIRGL_RENDERER_DUAL_METAL",
        "DORY_VIRGL_RENDERER_STATIC_LINKED",
    ],
    "requiredVirGLCapsets": [2, 4],
    "runtimeLibraries": [
        {
            "installName": f"@loader_path/{pathlib.PurePosixPath(path).name}",
            "path": path,
            "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest(),
        }
        for path in ("Frameworks/libEGL.dylib", "Frameworks/libGLESv2.dylib")
    ],
    "schemaVersion": 2,
}
(root / "renderer-static-link.json").write_text(
    json.dumps(contract, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
python3 "$ROOT/scripts/renderer-production-tuple.py" create-inventory \
  --profile staticLinkClosure --root "$LINK" --output "$LINK_INVENTORY" >/dev/null
printf 'dynamic renderer fixture\n' >"$LINK/libvirglrenderer.dylib"
if python3 "$ROOT/scripts/package-renderer-production-bundle.py" verify-link-stage \
    --link-root "$LINK" --link-inventory "$LINK_INVENTORY" \
    >"$WORK/dynamic-input.log" 2>&1; then
  echo "test-build-renderer-components: dynamic renderer artifact unexpectedly succeeded" >&2
  exit 1
fi
grep 'static link stage differs' "$WORK/dynamic-input.log" >/dev/null

# An arm64 executable from the right toolchain is still rejected unless the static renderer was
# actually resolved into its final Mach-O bytes.
printf 'int main(void) { return 0; }\n' >"$WORK/unlinked-worker.c"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 \
  "$WORK/unlinked-worker.c" -o "$WORK/unlinked-worker"
if python3 "$ROOT/scripts/package-renderer-production-bundle.py" verify-worker-linkage \
    --worker-executable "$WORK/unlinked-worker" >"$WORK/unlinked-worker.log" 2>&1; then
  echo "test-build-renderer-components: unlinked placeholder worker unexpectedly succeeded" >&2
  exit 1
fi
grep 'missing statically linked symbol' "$WORK/unlinked-worker.log" >/dev/null

# virglrenderer compiles its internal classic-renderer entry points with hidden visibility. The
# final worker must retain those definitions, but it must not needlessly export them from the XPC
# executable. Exercise that exact Mach-O shape so the packaging gate cannot regress to treating a
# correctly hidden VirGL2 implementation as a missing static archive.
python3 - "$WORK/hidden-vrend-worker.c" <<'PY'
import pathlib
import sys

public = (
    "virgl_renderer_cleanup",
    "virgl_renderer_context_create_fence",
    "virgl_renderer_context_create_with_flags",
    "virgl_renderer_context_destroy",
    "virgl_renderer_ctx_attach_resource",
    "virgl_renderer_ctx_detach_resource",
    "virgl_renderer_fill_caps",
    "virgl_renderer_get_cap_set",
    "virgl_renderer_init",
    "virgl_renderer_poll",
    "virgl_renderer_resource_attach_iov",
    "virgl_renderer_resource_create_blob",
    "virgl_renderer_resource_detach_iov",
    "virgl_renderer_resource_export_blob",
    "virgl_renderer_resource_get_info",
    "virgl_renderer_resource_get_map_info",
    "virgl_renderer_resource_unref",
    "virgl_renderer_submit_cmd2",
    "virgl_renderer_transfer_read_iov",
    "virgl_renderer_transfer_write_iov",
    "epoxy_eglInitialize",
    "epoxy_glGetString",
    "vkGetInstanceProcAddr",
)
lines = [
    '#define PUBLIC __attribute__((visibility("default"), noinline))',
    '#define HIDDEN __attribute__((visibility("hidden"), noinline))',
    'static const char egl[] __attribute__((used)) = "@loader_path/../Frameworks/libEGL.dylib";',
    'static const char gles[] __attribute__((used)) = "@loader_path/../Frameworks/libGLESv2.dylib";',
]
lines.extend(f"PUBLIC void {name}(void) {{}}" for name in public)
lines.extend([
    'HIDDEN void vrend_renderer_context_create(void) {}',
    'HIDDEN void vrend_renderer_init(void) {}',
    'int main(void) {',
    '  void (*volatile references[])(void) = {',
    *(f"    {name}," for name in public),
    '    vrend_renderer_context_create,',
    '    vrend_renderer_init,',
    '  };',
    '  return references[0] == 0 || egl[0] == 0 || gles[0] == 0;',
    '}',
])
pathlib.Path(sys.argv[1]).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 \
  "$WORK/hidden-vrend-worker.c" -o "$WORK/hidden-vrend-worker"
if nm -gU "$WORK/hidden-vrend-worker" | grep -q '_vrend_renderer_context_create'; then
  echo "test-build-renderer-components: hidden vrend fixture unexpectedly exported its symbol" >&2
  exit 1
fi
nm "$WORK/hidden-vrend-worker" | grep '_vrend_renderer_context_create' >/dev/null
python3 "$ROOT/scripts/package-renderer-production-bundle.py" verify-worker-linkage \
  --worker-executable "$WORK/hidden-vrend-worker"

# SwiftPM's selected-toolchain compatibility search path is a build-time input, not runtime
# authority. Canonicalization removes exactly that path before signing and records the change.
FAKE_DEVELOPER="$WORK/Xcode.app/Contents/Developer"
FAKE_COMPATIBILITY="$FAKE_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx"
mkdir -p "$FAKE_COMPATIBILITY"
printf 'int main(void) { return 0; }\n' >"$WORK/rpath-worker.c"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 \
  -Wl,-rpath,"$FAKE_COMPATIBILITY" "$WORK/rpath-worker.c" -o "$WORK/rpath-worker"
python3 "$ROOT/scripts/package-renderer-production-bundle.py" canonicalize-worker-linkage \
  --worker-executable "$WORK/rpath-worker" \
  --developer-dir "$FAKE_DEVELOPER" \
  --receipt "$WORK/rpath-canonicalization.json"
if otool -l "$WORK/rpath-worker" | grep -q 'cmd LC_RPATH'; then
  echo "test-build-renderer-components: canonical worker retained LC_RPATH" >&2
  exit 1
fi
python3 - "$WORK/rpath-canonicalization.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["kind"] == "dev.dory.renderer-worker-link-canonicalization"
assert value["removedToolchainRPaths"] == [
    "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx"
]
assert value["inputExecutableSHA256"] != value["outputExecutableSHA256"]
PY

# No other load-path authority is eligible for canonicalization.
mkdir -p "$WORK/untrusted-renderer"
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 \
  -Wl,-rpath,"$WORK/untrusted-renderer" \
  "$WORK/rpath-worker.c" -o "$WORK/untrusted-rpath-worker"
if python3 "$ROOT/scripts/package-renderer-production-bundle.py" canonicalize-worker-linkage \
    --worker-executable "$WORK/untrusted-rpath-worker" \
    --developer-dir "$FAKE_DEVELOPER" \
    --receipt "$WORK/untrusted-rpath-canonicalization.json" \
    >"$WORK/untrusted-rpath.log" 2>&1; then
  echo "test-build-renderer-components: untrusted worker rpath unexpectedly canonicalized" >&2
  exit 1
fi
grep 'outside the selected Xcode toolchain' "$WORK/untrusted-rpath.log" >/dev/null

echo "renderer static component tests passed"

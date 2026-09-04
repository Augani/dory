import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import struct
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--products', required=True)
parser.add_argument('--manifest', required=True)
args = parser.parse_args()
products = Path(args.products).resolve()
original = products / 'Debug/Dory.app'
runroot = Path(tempfile.mkdtemp(prefix='dory-p01-creation-client-isolated-', dir='/tmp'))
copy = runroot / 'DoryP01Tests.app'
subprocess.run(['ditto', str(original), str(copy)], check=True)
info = copy / 'Contents/Info.plist'
metadata = plistlib.loads(info.read_bytes())
original_identifier = metadata['CFBundleIdentifier']
metadata['CFBundleIdentifier'] = 'com.pythonxi.Dory.P01CreationClientTests'
metadata['CFBundleName'] = 'Dory P01 Creation Client Test Host'
info.write_bytes(plistlib.dumps(metadata))
sign_command = ['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements,flags,runtime', str(copy)]
subprocess.run(sign_command, check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(copy)], check=True)

def absolute_paths(value):
    if isinstance(value, str): return value.replace('__TESTROOT__', str(products))
    if isinstance(value, list): return [absolute_paths(v) for v in value]
    if isinstance(value, dict): return {k: absolute_paths(v) for k, v in value.items()}
    return value

candidates = list(products.glob('Dory_Dory_*.xctestrun'))
assert len(candidates) == 1, candidates
configuration = absolute_paths(plistlib.loads(candidates[0].read_bytes()))
for item in configuration['TestConfigurations']:
    for target in item['TestTargets']:
        assert target['BlueprintName'] == 'DoryTests', target['BlueprintName']
        target['TestHostBundleIdentifier'] = metadata['CFBundleIdentifier']
        target['TestHostPath'] = str(copy)
        target['EnvironmentVariables']['DORY_UI_TEST'] = '1'
        target['BundleIdentifiersForCrashReportEmphasis'] = [
            metadata['CFBundleIdentifier'] if value == original_identifier else value
            for value in target['BundleIdentifiersForCrashReportEmphasis']
        ]
xctestrun = runroot / 'DoryP01.xctestrun'
xctestrun.write_bytes(plistlib.dumps(configuration))

def files(root):
    return {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in root.rglob('*') if f.is_file() and not f.is_symlink()}

before, after = files(original), files(copy)
changes = [{'path': path, 'originalSHA256': before.get(path), 'testHostSHA256': after.get(path)}
           for path in sorted(before.keys() | after.keys()) if before.get(path) != after.get(path)]
assert {r['path'] for r in changes} <= {
    'Contents/Info.plist', 'Contents/MacOS/Dory', 'Contents/_CodeSignature/CodeResources'
}, changes
command = ['xcodebuild', 'test-without-building', '-xctestrun', str(xctestrun),
           '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
           '-resultBundlePath', str(runroot / 'Results.xcresult'), '-only-testing:DoryTests/DorydClientTests']
manifest = {
    'testHostPath': str(copy), 'xctestrun': str(xctestrun),
    'originalBundleIdentifier': original_identifier,
    'testBundleIdentifier': metadata['CFBundleIdentifier'],
    'signingCommandArguments': sign_command, 'commandArguments': command,
    'scope': 'DorydClientTests including explicit creation and clone UUID assertions in a copied Debug app, with a separate test-host bundle identity, preserved entitlements and ad-hoc signing. DORY_UI_TEST=1 disables app instance management and startup side effects. This does not qualify the original bundle identity, app UI automation, physical guests or release signing.',
    'copyComparison': {
        'identicalRegularFiles': sum(before.get(f) == after.get(f) for f in before.keys() | after.keys()),
        'changedFiles': changes,
        'meaning': 'The app debug dylib, test bundle and embedded dependencies remain byte-identical; only the host identity and its signature changed.'
    }
}
source_manifest = Path('/tmp/dory-p01-creation-client-source-manifest.json')
manifest['sourceSnapshotManifestPath'] = str(source_manifest)
manifest['sourceSnapshotManifestSHA256'] = hashlib.sha256(source_manifest.read_bytes()).hexdigest()
manifest['scope'] += ' App source is frozen from the prior 86-test app source with only DoryTests/DorydClientTests.swift overlaid to add create/clone UUID assertions. Latest core start work is excluded.'

def macho_payload(path):
    data = path.read_bytes()
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf, 'Expected a thin Mach-O 64-bit test host'
    count, size = struct.unpack_from('<II', data, 16)
    offset, signature_offset = 32, None
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, offset)
        assert length >= 8 and offset + length <= 32 + size
        if command == 0x1d:
            assert signature_offset is None
            signature_offset = struct.unpack_from('<I', data, offset + 8)[0]
        offset += length
    assert offset == 32 + size and signature_offset is not None
    assert 32 + size <= signature_offset <= len(data)
    return data[32 + size:signature_offset]

original_payload = macho_payload(original / 'Contents/MacOS/Dory')
test_payload = macho_payload(copy / 'Contents/MacOS/Dory')
assert original_payload == test_payload, 'Test host executable code/data payload changed'
manifest['copyComparison']['hostExecutablePayload'] = {
    'sha256': hashlib.sha256(original_payload).hexdigest(),
    'bytes': len(original_payload),
    'meaning': 'Identical Mach-O bytes after the header/load commands and before LC_CODE_SIGNATURE; bundle/signature metadata is excluded.'
}
output = Path(args.manifest)
output.write_text(json.dumps(manifest, indent=2) + '\n')
print('Command arguments:', json.dumps(command), flush=True)
result = subprocess.run(command)
manifest['exitCode'] = result.returncode
assert files(original) == before, 'Original app bundle changed during isolated testing'
output.write_text(json.dumps(manifest, indent=2) + '\n')
sys.exit(result.returncode)

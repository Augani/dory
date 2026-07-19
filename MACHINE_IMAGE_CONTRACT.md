# Dory machine image contract

Dory has two intentionally different image contracts:

- The Docker engine guest is a Dory-owned, immutable, reproducibly built kernel and root filesystem.
  Installing arbitrary kernel modules or DKMS packages into that engine guest is unsupported. This
  boundary keeps every Docker user on the payload covered by Dory's signature and release gates.
- Linux Machines accept an explicit bootable Linux kernel and raw root filesystem. These are full
  VMs for custom operating systems and kernel work; they do not mutate the Docker engine guest.

## Signed custom images

The supported baseline is the pair bundled in the signed full app. With the full app installed,
the CLI discovers `dory-hv-kernel-<arch>` and `dory-machine-rootfs-<arch>.ext4` automatically:

```bash
dory machine create baseline
dory machine start baseline
dory machine exec baseline -- uname -a
```

Those files are covered by the app's recursive code-signing and release payload inventory. Keep
the kernel and rootfs from the same Dory release. The baseline is the first reproduction target
when diagnosing a custom image that does not boot.

### Rebuild the supported image from source

The supported custom-image recipe is the same pinned, fail-closed build used for Dory releases.
Run it from the repository root with a reachable Docker-compatible engine, Rust, `rust-lld`, and
`e2fsprogs` installed. Every downloaded kernel, Docker, Alpine, runtime, and utility artifact is
SHA-256 pinned by the files under `guest/kernel` and `guest/initfs`; the verification steps reject
stale build stamps, changed inputs, wrong-architecture binaries, missing guest tools, or a rootfs
containing a different guest agent.

Apple silicon:

```bash
guest/kernel/build.sh arm64
guest/initfs/build.sh arm64
guest/kernel/verify-build.sh arm64
guest/initfs/verify-build.sh arm64

ssh-keygen -t ed25519 -f ~/.ssh/dory-machine-image -C dory-machine-images
scripts/sign-machine-image-manifest.sh \
  --kernel guest/out/Image \
  --rootfs guest/out/initfs-arm64.ext4 \
  --key ~/.ssh/dory-machine-image \
  --signer release@example.com \
  --output ./machine-image-arm64.json
```

Intel:

```bash
guest/kernel/build.sh amd64
guest/initfs/build.sh amd64
guest/kernel/verify-build.sh amd64
guest/initfs/verify-build.sh amd64

scripts/sign-machine-image-manifest.sh \
  --kernel guest/out/bzImage-x86 \
  --rootfs guest/out/initfs-amd64.ext4 \
  --key ~/.ssh/dory-machine-image \
  --signer release@example.com \
  --output ./machine-image-amd64.json
```

The build scripts publish their outputs atomically only after verification. Do not substitute an
unverified `guest/out` file or mix a kernel and rootfs from different source revisions.

For an externally supplied kernel/rootfs pair, add an artifact-level trust chain rather than
relying on its download location. Create a dedicated Ed25519 SSH key and keep its private half
outside the image directory:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/dory-machine-image -C dory-machine-images
scripts/sign-machine-image-manifest.sh \
  --kernel /path/to/Image \
  --rootfs /path/to/rootfs.raw \
  --key ~/.ssh/dory-machine-image \
  --signer release@example.com \
  --output ./machine-image.json
```

Create the machine only after verifying the signed manifest and both large artifacts:

```bash
dory machine create dev \
  --kernel /path/to/Image \
  --rootfs /path/to/rootfs.raw \
  --image-manifest ./machine-image.json \
  --image-signature ./machine-image.json.sig \
  --image-allowed-signers ./machine-image.json.allowed_signers \
  --image-signer release@example.com
```

The signature covers the canonical manifest in the `dory-machine-image` SSH namespace. Dory then
computes SHA-256 over the selected kernel and rootfs and refuses machine creation if either byte
changes. The allowed-signers file is trust policy, not merely another download: obtain it from a
trusted administrator or repository and review the signer identity and public key.

This mechanism does not claim that arbitrary images will boot. A compatible image must use the
host architecture, contain the drivers required by Dory's virtual hardware, and start the Dory
guest agent when managed exec, provisioning, mounts, and lifecycle readiness are required.

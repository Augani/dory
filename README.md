# Dory

Dory is a macOS application with a local container runtime and a developing virtual-machine platform.

**The team's single implementation guide is [PLAN.md](PLAN.md).** It contains the current code review, required fixes and removals, architecture, phased checklists, ownership, qualification criteria and release gates.

The virtualization programme targets Apple Silicon hosts with Linux ARM64, Linux x86_64 and macOS ARM64 guests. ARM guests use native virtualization; x86 Linux uses Dory's full-system translator. Linux graphics and macOS graphics have separate implementations and qualification requirements. These are delivery targets, not a statement that every path is currently release-qualified.

- [Build and contribution instructions](CONTRIBUTING.md)
- [Release history](CHANGELOG.md)
- [License](LICENSE)

Update the relevant section of `PLAN.md` when implementation decisions or evidence change. Do not add another competing roadmap or architecture plan.

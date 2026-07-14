# Homebrew Cask for Dory. version + sha256 are bumped automatically by the release workflow, which
# also syncs this file to the Augani/homebrew-dory tap.  Install:  brew install --cask Augani/dory/dory
cask "dory" do
  version "0.3.0"
  sha256 "4a41166bce3335d552c70c94d4a0e7f3f3a2d6979c99e3320ecf570c77123694"

  url "https://github.com/Augani/dory/releases/download/v#{version}/Dory-#{version}.zip"
  name "Dory"
  desc "Native Docker and Linux container runtime"
  homepage "https://github.com/Augani/dory"

  # Dory's first public production track is Apple Silicon. Intel support remains on the roadmap.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Dory.app"

  # Preserve ~/Library/Application Support/Dory: uninstall and --zap must never remove the selected
  # data-drive authority, images, containers, volumes, networks, machines, or other workload data.
  zap trash: [
    "~/.dory",
    "~/Library/Application Support/com.pythonxi.Dory",
    "~/Library/Preferences/com.pythonxi.Dory.plist",
  ]
end

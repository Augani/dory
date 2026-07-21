# Homebrew Cask for Dory. version + sha256 are bumped automatically by the release workflow, which
# also syncs this file to the Augani/homebrew-dory tap.  Install:  brew install --cask Augani/dory/dory
cask "dory" do
  version "0.4.0"
  sha256 "7e587b26db769506f4801e7094ff9cebde288b84bbc74cfa97b05dc1ca23223c"

  url "https://github.com/Augani/dory/releases/download/v#{version}/Dory-#{version}.zip"
  name "Dory"
  desc "Native Docker and Linux container runtime"
  homepage "https://github.com/Augani/dory"

  auto_updates true
  # Dory's first public production track is Apple Silicon. Intel support remains on the roadmap.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Dory.app"
  binary "#{appdir}/Dory.app/Contents/Helpers/dory"

  uninstall quit:   "com.pythonxi.Dory",
            script: {
              executable: "#{appdir}/Dory.app/Contents/Helpers/dory",
              args:       ["uninstall"],
            }

  # Preserve ~/Library/Application Support/Dory: uninstall and --zap must never remove the selected
  # data-drive authority, images, containers, volumes, networks, machines, or other workload data.
  zap trash: [
    "~/.dory",
    "~/Library/Preferences/com.pythonxi.Dory.plist",
  ]

  caveats "Open Dory once to start its engine."
end

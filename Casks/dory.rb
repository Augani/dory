# Homebrew Cask for Dory. version + sha256 are bumped automatically by the release workflow.
# Tap and install:  brew tap Augani/dory https://github.com/Augani/dory && brew install --cask dory
cask "dory" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Augani/dory/releases/download/v#{version}/Dory-#{version}.zip"
  name "Dory"
  desc "Lightweight native macOS app for Docker and Linux containers on Apple silicon"
  homepage "https://github.com/Augani/dory"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Dory.app"

  zap trash: [
    "~/.dory",
    "~/Library/Application Support/com.pythonxi.Dory",
    "~/Library/Preferences/com.pythonxi.Dory.plist",
  ]
end

# Homebrew cask for DynamicIsland, served from this repository as a tap:
#   brew tap gdfaler/dynamicisland https://github.com/gdfaler/DynamicIsland
#   brew install --cask dynamicisland
# Update `version` and `sha256` for each release:  shasum -a 256 DynamicIsland-<version>.zip
cask "dynamicisland" do
  version "1.3"
  sha256 "763061e752e0d70e01e6865dfae3f1dd2e2beb68c6818d1cb94daaa2012564e0"

  url "https://github.com/gdfaler/DynamicIsland/releases/download/v#{version}/DynamicIsland-#{version}.zip"
  name "DynamicIsland"
  desc "Turns the MacBook notch into an iPhone-style dynamic island"
  homepage "https://github.com/gdfaler/DynamicIsland"

  depends_on macos: :sonoma

  app "DynamicIsland.app"

  # The app is self-signed and not notarized; drop the quarantine flag so it opens without the Gatekeeper dance.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/DynamicIsland.app"], must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/local.dynamicisland.plist",
  ]
end

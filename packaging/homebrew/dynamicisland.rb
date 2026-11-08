# Homebrew cask for DynamicIsland. Put this file in a tap repository (e.g. gdfaler/homebrew-tap, folder Casks/)
# and update `version` and `sha256` for each release:  shasum -a 256 dist/DynamicIsland-<version>.zip
cask "dynamicisland" do
  version "1.1"
  sha256 "6c4d3eac4732dde75a0b1a2a9b54f713ebf77e585a68a3cd8fbd59375bda12cd"

  url "https://github.com/gdfaler/DynamicIsland/releases/download/v#{version}/DynamicIsland-#{version}.zip"
  name "DynamicIsland"
  desc "Turns the MacBook notch into an iPhone-style dynamic island"
  homepage "https://github.com/gdfaler/DynamicIsland"

  depends_on macos: ">= :sonoma"

  app "DynamicIsland.app"

  # The app is self-signed and not notarized; drop the quarantine flag so it opens without the Gatekeeper dance.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/DynamicIsland.app"]
  end

  zap trash: [
    "~/Library/Preferences/local.dynamicisland.plist",
  ]
end

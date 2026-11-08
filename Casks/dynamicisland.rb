# Homebrew cask for DynamicIsland, served from this repository as a tap:
#   brew tap gdfaler/dynamicisland https://github.com/gdfaler/DynamicIsland
#   brew install --cask dynamicisland
# Update `version` and `sha256` for each release:  shasum -a 256 DynamicIsland-<version>.zip
cask "dynamicisland" do
  version "1.2"
  sha256 "06814af04d8c3763dd600c1741074322ba5d6d6e6d110e148e9cecb512e3c181"

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

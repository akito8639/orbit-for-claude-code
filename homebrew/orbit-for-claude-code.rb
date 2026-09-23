# Homebrew Cask template. Lives in your tap repository as Casks/orbit-for-claude-code.rb
# (e.g. github.com/akito8639/homebrew-tap). Users install with:
#   brew tap akito8639/tap && brew trust akito8639/tap && brew install --cask orbit-for-claude-code
#
# Update `version` and `sha256` (from sha256.txt on the GitHub release) for each release.
cask "orbit-for-claude-code" do
  version "1.0.14"
  sha256 "b3d8cb228263f272b1ba093ecf8bfe9392922c8cdc09d6f49061f2fb223fa873"

  url "https://github.com/akito8639/orbit-for-claude-code/releases/download/v#{version}/Orbit-for-Claude-Code-#{version}.zip"
  name "Orbit for Claude Code"
  desc "Menu bar app and widget showing Claude Code usage limits (5h / weekly / per-model), status and local sessions"
  homepage "https://github.com/akito8639/orbit-for-claude-code"

  depends_on macos: :tahoe   # macOS 26 or later

  auto_updates true   # the app updates itself with Sparkle

  app "Orbit for Claude Code.app"

  uninstall quit: "com.akito.OrbitForClaudeCode"

  zap trash: [
    "~/Library/Group Containers/*.com.akito.OrbitForClaudeCode",
    "~/Library/Preferences/com.akito.OrbitForClaudeCode.plist",
  ]

  caveats <<~EOS
    Orbit reads the OAuth token that Claude Code stores in your keychain.
    Run `claude` once in a terminal (and `/login` if asked) so a fresh token exists,
    then add the "Orbit for Claude Code" widget from the desktop's widget gallery.
    Unofficial project — not affiliated with Anthropic.
  EOS
end

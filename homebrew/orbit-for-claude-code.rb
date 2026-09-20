# Homebrew Cask template. Lives in your tap repository as Casks/orbit-for-claude-code.rb
# (e.g. github.com/akito8639/homebrew-tap). Users install with:
#   brew tap akito8639/tap && brew install --cask orbit-for-claude-code
#
# Update `version` and `sha256` (from sha256.txt on the GitHub release) for each release.
cask "orbit-for-claude-code" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/akito8639/orbit-for-claude-code/releases/download/v#{version}/Orbit-for-Claude-Code-#{version}.zip"
  name "Orbit for Claude Code"
  desc "Menu bar app and widget showing Claude Code usage limits (5h / weekly / per-model), status and local sessions"
  homepage "https://github.com/akito8639/orbit-for-claude-code"

  depends_on macos: ">= :tahoe"   # macOS 26 or later (Liquid Glass, WidgetKit APIs used here)

  app "Orbit for Claude Code.app"

  postflight do
    # Register the widget extension with the system so it appears in the widget gallery right away.
    system_command "/usr/bin/pluginkit", args: ["-a", "#{appdir}/Orbit for Claude Code.app/Contents/PlugIns/OrbitWidget.appex"]
  end

  uninstall quit: "com.kazuhide.OrbitForClaudeCode"

  zap trash: [
    "~/Library/Group Containers/*.com.kazuhide.OrbitForClaudeCode",
    "~/Library/Preferences/com.kazuhide.OrbitForClaudeCode.plist",
  ]

  caveats <<~EOS
    Orbit reads the OAuth token that Claude Code stores in your keychain.
    Run `claude` once in a terminal (and `/login` if asked) so a fresh token exists,
    then add the "Orbit for Claude Code" widget from the desktop's widget gallery.
    Unofficial project — not affiliated with Anthropic.
  EOS
end

cask "agent-notch" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Forichok/Agent-Notch/releases/download/v#{version}/AgentNotch-#{version}.zip"
  name "Agent Notch"
  desc "See and approve Claude Code and Codex agents from the MacBook notch"
  homepage "https://github.com/Forichok/Agent-Notch"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Agent Notch.app"

  # The app is ad-hoc signed, not notarized: lift the download quarantine so it opens on first launch.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Agent Notch.app"],
        writable_paths: ["Agent Notch.app"],
        writable_base:  :appdir
  end

  uninstall quit: "com.forichok.agents-notch"

  # zap runs after the app is removed: the hooks come out through the helper copy, before it is trashed.
  zap script: {
        executable: "/bin/sh",
        args:       [
          "-c",
          'h="$HOME/Library/Application Support/AgentsNotch/notch-hook"; [ -x "$h" ] && "$h" --uninstall-hooks; true',
        ],
      },
      trash:  [
        "~/Library/Application Support/AgentsNotch",
        "~/Library/Preferences/com.forichok.agents-notch.plist",
      ]
end

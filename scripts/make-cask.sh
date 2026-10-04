#!/bin/sh
# Writes the Homebrew cask for a release into a checkout of the tap (Taaanos/homebrew-oxys).
# Usage: scripts/make-cask.sh <version> <tap-checkout>     e.g. scripts/make-cask.sh 0.2.0 ../homebrew-oxys
# Run it after scripts/release.sh <version>, from the same checkout: it reads dist/Oxys.zip.sha256.
# It writes <tap-checkout>/Casks/oxys.rb and nothing else; you review, commit and push the tap yourself.
set -eu
[ $# -eq 2 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
version=$1 tap=$2
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must look like 1.2.3, got: $version" >&2; exit 2; }
[ -d "$tap/.git" ] || { echo "not a git checkout: $tap" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)"
sum=$(cut -d' ' -f1 dist/Oxys.zip.sha256)
[ ${#sum} -eq 64 ] || { echo "dist/Oxys.zip.sha256 is missing or wrong: run scripts/release.sh first" >&2; exit 1; }
mkdir -p "$tap/Casks"
cat > "$tap/Casks/oxys.rb" <<CASK
cask "oxys" do
  version "$version"
  sha256 "$sum"

  url "https://github.com/Taaanos/oxys/releases/download/v#{version}/Oxys.zip"
  name "Oxys"
  desc "Keyboard-first RAW culler"
  homepage "https://github.com/Taaanos/oxys"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :golden_gate"

  app "Oxys.app"

  # The build has no Developer ID, so Gatekeeper blocks it while the quarantine mark is on it.
  # Homebrew sets the mark on each download; this removes it from the app only.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Oxys.app"]
  end

  zap trash: [
    "~/Library/Caches/com.thanosam.Oxys",
    "~/Library/Preferences/com.thanosam.Oxys.plist",
    "~/Library/Saved Application State/com.thanosam.Oxys.savedState",
  ]
end
CASK
echo "wrote $tap/Casks/oxys.rb"

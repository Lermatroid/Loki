class Loki < Formula
  desc "Menu bar app for SSH port forwarding"
  homepage "https://github.com/Lermatroid/Loki"
  url "https://github.com/Lermatroid/Loki/archive/61f96053a7492cf61961daedbfe1aa59716941df.tar.gz"
  version "0.1.0"
  sha256 "6a795d9b27de25524647e058a9a5b9e5b11993be4e96073299044e9e7efaf038"
  license "MIT"

  bottle do
    root_url "https://github.com/Lermatroid/Loki/releases/download/v0.1.0"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "81110bd09619da22323455a6a905314de0e7986c761cc40583966d8892e92393"
  end

  depends_on xcode: ["26.0", :build]
  depends_on :macos

  on_macos do
    depends_on macos: :sonoma
  end

  def install
    ENV["VERSION"] = version.to_s
    ENV["BUILD_NUMBER"] = "1"
    system "bash", "scripts/build.sh"
    libexec.install "dist/Loki.app"
    (bin/"loki").write <<~SH
      #!/bin/bash
      if [[ "${1:-}" == "--version" ]]; then
        exec "#{opt_libexec}/Loki.app/Contents/MacOS/Loki" --version
      fi
      exec /usr/bin/open "#{opt_libexec}/Loki.app" --args "$@"
    SH
    (bin/"loki").chmod 0555
  end

  def caveats
    <<~EOS
      Run `loki` to open the menu bar app.

      To also show Loki in Applications:
        mkdir -p ~/Applications
        ln -s #{opt_libexec}/Loki.app ~/Applications/Loki.app
    EOS
  end

  test do
    assert_equal "Loki #{version}", shell_output("#{bin}/loki --version").strip
    system "/usr/bin/codesign", "--verify", "--strict", libexec/"Loki.app"
    refute_match "com.apple.quarantine", shell_output("/usr/bin/xattr #{libexec}/Loki.app")
  end
end

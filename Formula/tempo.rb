# Homebrew formula: builds Tempo from source with the Command Line Tools.
#   brew tap aditya14as/tempo https://github.com/aditya14as/tempo
#   brew install tempo
class Tempo < Formula
  desc "Menu bar work-day progress, window switcher, clipboard history and keep-awake"
  homepage "https://github.com/aditya14as/tempo"
  url "https://github.com/aditya14as/tempo.git", branch: "main"
  version "1.0"
  license "MIT"

  depends_on macos: :sonoma

  def install
    system "./build.sh", "--disable-sandbox"
    prefix.install "dist/Tempo.app"
  end

  def caveats
    <<~EOS
      Homebrew can't write to /Applications, so copy Tempo there and open it:
        cp -R #{opt_prefix}/Tempo.app /Applications/ && open /Applications/Tempo.app

      To update later:
        brew reinstall tempo
      then run the cp line above again.
    EOS
  end

  test do
    assert_path_exists prefix/"Tempo.app/Contents/MacOS/Tempo"
  end
end

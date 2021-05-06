class GawkAT510 < Formula
  desc "GNU awk utility"
  homepage "https://www.gnu.org/software/gawk/"
  url "https://ftp.gnu.org/gnu/gawk/gawk-5.1.0.tar.xz"
  mirror "https://ftpmirror.gnu.org/gawk/gawk-5.1.0.tar.xz"
  sha256 "cf5fea4ac5665fd5171af4716baab2effc76306a9572988d5ba1078f196382bd"
  license "GPL-3.0-or-later"

  keg_only :versioned_formula

  depends_on "gettext"
  depends_on "mpfr"
  depends_on "readline"

  def install
    system "./configure", "--disable-debug",
                          "--disable-dependency-tracking",
                          "--prefix=#{prefix}",
                          "--without-libsigsegv-prefix"

    system "make"
    system "make", "check"
    system "make", "install"

    (libexec/"gnubin").install_symlink bin/"gawk" => "awk"
    (libexec/"gnuman/man1").install_symlink man1/"gawk.1" => "awk.1"
  end

  test do
    output = pipe_output("#{bin}/gawk '{ gsub(/Macro/, \"Home\"); print }' -", "Macrobrew")
    assert_equal "Homebrew", output.strip
  end
end

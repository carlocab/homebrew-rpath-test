class LlvmBootstrapProfdata < Formula
  desc "Next-gen compiler infrastructure"
  homepage "https://llvm.org/"
  # Keep this version in sync with llvm.rb
  url "https://github.com/llvm/llvm-project/releases/download/llvmorg-12.0.1/llvm-project-12.0.1.src.tar.xz"
  sha256 "129cb25cd13677aad951ce5c2deb0fe4afc1e9d98950f53b51bdcfb5a73afa0e"
  # The LLVM Project is under the Apache License v2.0 with LLVM Exceptions
  license "Apache-2.0" => { with: "LLVM-exception" }
  head "https://github.com/llvm/llvm-project.git", branch: "main"

  livecheck do
    url :homepage
    regex(/LLVM (\d+\.\d+\.\d+)/i)
  end

  bottle do
    root_url "https://github.com/carlocab/homebrew-rpath-test/releases/download/llvm-bootstrap-profdata-12.0.1"
    sha256 cellar: :any_skip_relocation, big_sur: "bc439a38b6ba822025036e2306a688b817d1fb36a335fc5581e2dfff619f7fba"
  end

  # Clang cannot find system headers if Xcode CLT is not installed
  pour_bottle? only_if: :clt_installed

  keg_only <<~EOS
    this formula is mainly used internally for bootstrapping.
    Users are advised to install the `llvm` formula instead
  EOS

  # https://llvm.org/docs/GettingStarted.html#requirement
  # We intentionally use Make instead of Ninja.
  # See: Homebrew/homebrew-core/issues/35513
  depends_on "carlocab/rpath-test/llvm-bootstrap-stage1" => :build
  depends_on "cmake" => :build
  depends_on "python@3.9" => :build

  on_linux do
    depends_on "glibc" if Formula["glibc"].any_version_installed?
    depends_on "pkg-config" => :build
    depends_on "binutils" # needed for gold

    # Apply patches slated for the 12.0.x release stream
    # to allow building with GCC 5 and 6. Upstream bug:
    # https://bugs.llvm.org/show_bug.cgi?id=50732
    patch do
      url "https://raw.githubusercontent.com/Homebrew/formula-patches/f0b8ff8b7ad4c2e1d474b214cd615a98e0caa796/llvm/llvm.patch"
      sha256 "084adce7711b07d94197a75fb2162b253186b38d612996eeb6e2bc9ce5b1e6e2"
    end
  end

  def install
    args = %W[
      -DLLVM_TARGETS_TO_BUILD=Native
      -DLLVM_ENABLE_PROJECTS=clang;compiler-rt;lld
      -DLLVM_ENABLE_FFI=OFF
      -DLLVM_INCLUDE_DOCS=OFF
      -DLLVM_ENABLE_Z3_SOLVER=OFF
      -DLLVM_OPTIMIZED_TABLEGEN=ON
      -DLLVM_CREATE_XCODE_TOOLCHAIN=OFF
      -DPACKAGE_VENDOR=#{tap.user}
      -DBUG_REPORT_URL=#{tap.issues_url}
      -DCLANG_VENDOR_UTI=org.#{tap.user.downcase}.clang
    ]

    on_macos do
      args << "-DLLVM_ENABLE_LIBCXX=ON"
      args << "-DRUNTIMES_CMAKE_ARGS=-DCMAKE_INSTALL_RPATH=#{rpath}"

      sdk = MacOS.sdk_path_if_needed
      args << "-DDEFAULT_SYSROOT=#{sdk}" if sdk
    end

    on_linux do
      ENV.append "CXXFLAGS", "-fpermissive"
      ENV.append "CFLAGS", "-fpermissive"

      args << "-DLLVM_ENABLE_ZLIB=OFF"
      args << "-DLLVM_ENABLE_LIBXML2=OFF"
      args << "-DLLVM_ENABLE_TERMINFO=OFF"
      args << "-DHAVE_HISTEDIT_H=OFF"
      args << "-DHAVE_LIBEDIT=OFF"
      args << "-DLLVM_ENABLE_LIBCXX=OFF"
      args << "-DCLANG_DEFAULT_CXX_STDLIB=libstdc++"
      # Enable llvm gold plugin for LTO
      args << "-DLLVM_BINUTILS_INCDIR=#{Formula["binutils"].opt_include}"
      runtime_args = %w[
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
      ]
      args << "-DRUNTIMES_CMAKE_ARGS=#{runtime_args.join(";")}"
    end

    cflags = ENV.cflags&.split || []
    cxxflags = ENV.cxxflags&.split || []

    # The later stage builds avoid the shims, and the build
    # will target Penryn unless otherwise specified
    if Hardware::CPU.intel?
      cflags << "-march=#{Hardware.oldest_cpu}"
      cxxflags << "-march=#{Hardware.oldest_cpu}"
    end

    # Our bootstrap Clang needs a little help finding C++ headers,
    # since the atomic and type_traits headers are not in the SDK
    # on macOS versions before Big Sur.
    on_macos do
      if MacOS.version <= :catalina && sdk
        toolchain_path = if MacOS::CLT.installed?
          MacOS::CLT::PKG_PATH
        else
          MacOS::Xcode.toolchain_path
        end

        cxxflags << "-isystem#{toolchain_path}/usr/include/c++/v1"
        cxxflags << "-isystem#{toolchain_path}/usr/include"
        cxxflags << "-isystem#{MacOS.sdk_path_if_needed}/usr/include"
      end
    end

    # Next, build an instrumented stage2 compiler
    llvmpath = buildpath/"llvm"
    bootstrap = Formula["carlocab/rpath-test/llvm-bootstrap-stage1"]
    mkdir llvmpath/"stage2" do
      # LLVM Profile runs out of static counters
      # https://reviews.llvm.org/D92669, https://reviews.llvm.org/D93281
      # Without this, the build produces many warnings of the form
      # LLVM Profile Warning: Unable to track new values: Running out of static counters.
      instrumented_cflags = cflags + ["-Xclang -mllvm -Xclang -vp-counters-per-site=6"]
      instrumented_cxxflags = cxxflags + ["-Xclang -mllvm -Xclang -vp-counters-per-site=6"]

      system "cmake", "-G", "Unix Makefiles", "..",
                      "-DCMAKE_C_COMPILER=#{bootstrap.bin}/clang",
                      "-DCMAKE_CXX_COMPILER=#{bootstrap.bin}/clang++",
                      "-DLLVM_BUILD_INSTRUMENTED=IR",
                      "-DLLVM_BUILD_RUNTIME=NO",
                      "-DLLVM_PROFILE_DATA_DIR=#{pkgshare}/profiles",
                      "-DCMAKE_C_FLAGS=#{instrumented_cflags.join(" ")}",
                      "-DCMAKE_CXX_FLAGS=#{instrumented_cxxflags.join(" ")}",
                      *args, *std_cmake_args
      system "cmake", "--build", ".", "--target", "clang", "lld"

      # We run some `check-*` targets to increase profiling
      # coverage. These do not need to succeed.
      begin
        system "cmake", "--build", ".", "--target", "check-clang", "check-llvm", "--", "--keep-going"
      rescue RuntimeError
        nil
      end
    end

    # Finally, merge the generated profile data
    system bootstrap.bin/"llvm-profdata",
           "merge",
           "-output=#{pkgshare}/pgo_profile.prof",
           *Dir[pkgshare/"profiles/*.profraw"]
  end

  test do
    assert_predicate pkgshare/"pgo_profile.prof", :exist?, "Profile data not generated"
  end
end

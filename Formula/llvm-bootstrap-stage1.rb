class LlvmBootstrapStage1 < Formula
  desc "Next-gen compiler infrastructure"
  homepage "https://llvm.org/"
  url "https://github.com/llvm/llvm-project/releases/download/llvmorg-12.0.1/llvm-project-12.0.1.src.tar.xz"
  sha256 "129cb25cd13677aad951ce5c2deb0fe4afc1e9d98950f53b51bdcfb5a73afa0e"
  # The LLVM Project is under the Apache License v2.0 with LLVM Exceptions
  license "Apache-2.0" => { with: "LLVM-exception" }
  head "https://github.com/llvm/llvm-project.git", branch: "main"

  livecheck do
    url :homepage
    regex(/LLVM (\d+\.\d+\.\d+)/i)
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
    # Apple's libstdc++ is too old to build LLVM
    ENV.libcxx if ENV.compiler == :clang

    # compiler-rt has some iOS simulator features that require i386 symbols
    # I'm assuming the rest of clang needs support too for 32-bit compilation
    # to work correctly, but if not, perhaps universal binaries could be
    # limited to compiler-rt. llvm makes this somewhat easier because compiler-rt
    # can almost be treated as an entirely different build from llvm.
    ENV.permit_arch_flags

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

    args << "-DCMAKE_C_FLAGS=#{cflags.join(" ")}" unless cflags.empty?
    args << "-DCMAKE_CXX_FLAGS=#{cxxflags.join(" ")}" unless cxxflags.empty?

    # First, build a stage1 compiler. It might be possible to skip this step on macOS
    # and use system Clang instead, but this stage does not take too long, and we want
    # to avoid incompatibilities from generating profile data with a newer Clang than
    # the one we consume the data with.
    llvmpath = buildpath/"llvm"
    mkdir llvmpath/"stage1" do
      system "cmake", "-G", "Unix Makefiles", "..", *args, *std_cmake_args
      system "cmake", "--build", ".", "--target", "clang", "llvm-profdata", "profile"
      system "cmake", "--build", ".", "--target", "install"
    end
  end

  test do
    (testpath/"test.c").write <<~EOS
      #include <stdio.h>
      int main()
      {
        printf("Hello World!\\n");
        return 0;
      }
    EOS

    (testpath/"test.cpp").write <<~EOS
      #include <iostream>
      int main()
      {
        std::cout << "Hello World!" << std::endl;
        return 0;
      }
    EOS

    # Testing default toolchain and SDK location.
    system "#{bin}/clang++", "-v",
           "-std=c++11", "test.cpp", "-o", "test++"
    on_macos { assert_includes MachO::Tools.dylibs("test++"), "/usr/lib/libc++.1.dylib" }
    assert_equal "Hello World!", shell_output("./test++").chomp
    system "#{bin}/clang", "-v", "test.c", "-o", "test"
    assert_equal "Hello World!", shell_output("./test").chomp

    # Testing Command Line Tools
    if MacOS::CLT.installed?
      toolchain_path = "/Library/Developer/CommandLineTools"
      system "#{bin}/clang++", "-v",
             "-isysroot", MacOS::CLT.sdk_path,
             "-isystem", "#{toolchain_path}/usr/include/c++/v1",
             "-isystem", "#{toolchain_path}/usr/include",
             "-isystem", "#{MacOS::CLT.sdk_path}/usr/include",
             "-std=c++11", "test.cpp", "-o", "testCLT++"
      assert_includes MachO::Tools.dylibs("testCLT++"), "/usr/lib/libc++.1.dylib"
      assert_equal "Hello World!", shell_output("./testCLT++").chomp
      system "#{bin}/clang", "-v", "test.c", "-o", "testCLT"
      assert_equal "Hello World!", shell_output("./testCLT").chomp
    end

    # Testing Xcode
    if MacOS::Xcode.installed?
      system "#{bin}/clang++", "-v",
             "-isysroot", MacOS::Xcode.sdk_path,
             "-isystem", "#{MacOS::Xcode.toolchain_path}/usr/include/c++/v1",
             "-isystem", "#{MacOS::Xcode.toolchain_path}/usr/include",
             "-isystem", "#{MacOS::Xcode.sdk_path}/usr/include",
             "-std=c++11", "test.cpp", "-o", "testXC++"
      assert_includes MachO::Tools.dylibs("testXC++"), "/usr/lib/libc++.1.dylib"
      assert_equal "Hello World!", shell_output("./testXC++").chomp
      system "#{bin}/clang", "-v",
             "-isysroot", MacOS.sdk_path,
             "test.c", "-o", "testXC"
      assert_equal "Hello World!", shell_output("./testXC").chomp
    end
  end
end

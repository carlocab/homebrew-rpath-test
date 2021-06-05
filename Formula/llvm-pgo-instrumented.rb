class LlvmPgoInstrumented < Formula
  desc "Next-gen compiler infrastructure"
  homepage "https://llvm.org/"
  url "https://github.com/llvm/llvm-project/releases/download/llvmorg-12.0.0/llvm-project-12.0.0.src.tar.xz"
  sha256 "9ed1688943a4402d7c904cc4515798cdb20080066efa010fe7e1f2551b423628"
  # The LLVM Project is under the Apache License v2.0 with LLVM Exceptions
  license "Apache-2.0" => { with: "LLVM-exception" }
  head "https://github.com/llvm/llvm-project.git", branch: "main"

  livecheck do
    url :homepage
    regex(/LLVM (\d+\.\d+\.\d+)/i)
  end

  # Clang cannot find system headers if Xcode CLT is not installed
  pour_bottle? only_if: :clt_installed

  keg_only "this is only used for bootstrapping"

  # https://llvm.org/docs/GettingStarted.html#requirement
  # We intentionally use Make instead of Ninja.
  # See: Homebrew/homebrew-core/issues/35513
  depends_on "cmake" => :build

  uses_from_macos "libedit"
  uses_from_macos "libffi", since: :catalina
  uses_from_macos "libxml2"
  uses_from_macos "ncurses"
  uses_from_macos "zlib"

  on_linux do
    depends_on "pkg-config" => :build
    depends_on "binutils" # needed for gold
    depends_on "libelf" # openmp requires <gelf.h>
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

    # PGO build adapted from:
    # https://llvm.org/docs/HowToBuildWithPGO.html#building-clang-with-pgo
    # https://github.com/llvm/llvm-project/blob/33ba8bd2/llvm/utils/collect_and_build_with_pgo.py

    # First, build a stage1 compiler
    llvmpath = buildpath/"llvm"
    mkdir llvmpath/"build-stage1" do
      system "cmake", "-G", "Unix Makefiles", "..",
                            "-DLLVM_ENABLE_PROJECTS=clang;compiler-rt;lld",
                            "-DLLVM_TARGETS_TO_BUILD=Native",
                            *std_cmake_args
      system "cmake", "--build", ".", "--target", "clang", "llvm-profdata", "profile"
    end

    # Next, build an instrumented stage2 compiler
    mkdir llvmpath/"build-stage2" do
      system "cmake", "-G", "Unix Makefiles", "..",
                            "-DCMAKE_C_COMPILER=#{llvmpath}/build-stage1/bin/clang",
                            "-DCMAKE_CXX_COMPILER=#{llvmpath}/build-stage1/bin/clang++",
                            "-DLLVM_ENABLE_PROJECTS=clang;compiler-rt;lld",
                            "-DLLVM_TARGETS_TO_BUILD=Native",
                            "-DLLVM_BUILD_INSTRUMENTED=IR",
                            "-DLLVM_BUILD_RUNTIME=OFF",
                            "-DLLVM_ENABLE_LIBCXX=ON",
                            *std_cmake_args
      system "cmake", "--build", ".", "--target", "clang", "lld"

      # We don't need this to succeed, so make sure brew doesn't fail our build when it doesn't
      (Pathname.pwd/"run-checks.sh").write <<~EOS
        #!/bin/sh
        cmake --build . --target check-clang || true
        cmake --build . --target check-llvm || true
      EOS

      system "sh", "run-checks.sh"
    end

    prefix.install buildpath.children
  end

  test do
    system prefix/"llvm/build-stage2/bin/clang", "--version"
  end
end

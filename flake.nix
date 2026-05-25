{
  description = "sioyek-core: stripped PDF rendering engine + Lisp control layer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # Supported systems. Explicitly NOT x86_64-darwin (Intel Mac):
    #   - sbcl 2.6.3 is marked broken at our pinned nixpkgs rev on that
    #     platform; would fail `nix flake check --all-systems` and block CI.
    #   - NixOS upstream is dropping x86_64-darwin after 26.05 anyway.
    # If you need Intel Mac, raise it — we can revisit once sbcl unbroken
    # there OR we switch to sbcl-bin / sbclBootstrap.
    flake-utils.lib.eachSystem [
      "aarch64-darwin"   # Apple Silicon Mac host
      "aarch64-linux"    # Apple Silicon docker default + ARM CI
      "x86_64-linux"     # x86 docker + traditional Linux CI
    ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        qt = pkgs.qt6;

        # SBCL bundled with every CL library Limn depends on at runtime.
        # Adding a new vendored library = add it here, NOT a new git submodule.
        sbclWithLibs = pkgs.sbcl.withPackages (ps: [
          ps.cl-ppcre        # v0.34 regex engine
        ]);

        # v0.37 A3: sbcl wrapper that strong-forces --no-userinit.
        # Goal: ~/.sbclrc CANNOT leak into the dev shell.  Every `sbcl`
        # invocation inside `nix develop` resolves to this script, which
        # prepends --no-userinit before user args.  This silences the
        # 18 ASDF dup-source WARNINGs (host quicklisp register clashes
        # with nix-managed contribs) and prevents any future host
        # configuration from polluting Limn's lisp environment.
        #
        # /etc/sbclrc (--no-sysinit) is NOT skipped — the nix sbcl
        # wrapper installs the ASDF source registry there, and we need
        # sb-bsd-sockets / cl-ppcre etc. to remain auto-loadable.
        #
        # Escape hatch: if you genuinely need vanilla sbcl (debugging
        # the wrapper itself, comparing behaviour), invoke
        # ${pkgs.sbcl}/bin/sbcl directly via the nix store path.
        sandboxedSbcl = pkgs.writeShellScriptBin "sbcl" ''
          exec ${sbclWithLibs}/bin/sbcl --no-userinit "$@"
        '';

        # ── shared between host devShell and docker test devShell ─────────
        # Single source of truth: any version drift between host and docker
        # is by definition impossible if both shells consume this list.
        commonPackages = [
          # Lisp control layer.  sandboxedSbcl MUST come before sbclWithLibs
          # in PATH order so `sbcl` resolves to the wrapper; sbclWithLibs is
          # still listed so its asd-registry contribs (the system init
          # path) are available to the wrapper.
          sandboxedSbcl
          sbclWithLibs
          pkgs.rlwrap              # readline wrapper for run-repl.sh

          # Qt modules sioyek needs
          qt.qtbase
          qt.qtsvg
          qt.qtdeclarative         # quickwidgets
          qt.qtspeech

          # PDF rendering. nixpkgs ships mupdf 1.27+ (fz_page_label etc.)
          # — Debian bookworm's 1.20.3 doesn't.
          pkgs.mupdf

          # mupdf's third-party deps. nixpkgs builds mupdf with
          # USE_SYSTEM_LIBS=yes, so the final binary links these dynamically.
          pkgs.openjpeg pkgs.jbig2dec pkgs.gumbo
          pkgs.harfbuzz pkgs.freetype pkgs.libjpeg

          # build tools
          pkgs.gnumake
          pkgs.cmake
          pkgs.pkg-config
          pkgs.git                 # for binary self-report (git rev-parse HEAD at qmake time)
        ];

        # ── docker-only extras ────────────────────────────────────────────
        # All Linux-only (X11, fcitx5, etc.). lib.optionals isLinux means
        # macOS evaluation of devShells.docker yields the same packages as
        # devShells.default — harmless since macOS never runs e2e natively.
        dockerExtras = lib.optionals pkgs.stdenv.isLinux [
          # X server + injection (driving Limn from outside).
          # container-entry.sh calls `Xvfb` directly (not the xvfb-run wrapper)
          # so we want xorg-server which ships the Xvfb / Xorg / Xnest / Xephyr
          # binaries. Was pkgs.xorg.xvfb pre-v0.37, renamed by nixpkgs.
          pkgs.xorg-server
          pkgs.xdotool
          pkgs.x11vnc
          pkgs.xdpyinfo            # was pkgs.xorg.xdpyinfo; renamed upstream
          pkgs.xprop               # was pkgs.xorg.xprop; renamed upstream
          pkgs.openbox             # minimal WM for ICCCM focus/mouse delivery
          pkgs.wmctrl

          # fonts — deterministic rendering across host & container
          pkgs.dejavu_fonts
          pkgs.noto-fonts
          pkgs.noto-fonts-cjk-sans
          pkgs.fontconfig

          # GL — mupdf paintGL fallback path
          pkgs.mesa
          pkgs.mesa-demos

          # CJK input (v0.16 IME pipeline e2e tests)
          pkgs.fcitx5
          pkgs.kdePackages.fcitx5-chinese-addons

          # build accelerator (inside docker only — host devs use ccache via nix)
          pkgs.ccache

          # file-notify (v0.35 — needs inotify-tools on Linux)
          pkgs.inotify-tools

          # base shell tools — explicitly pinned so PATH inside container
          # comes 100% from nix, never from the nixos/nix base image.
          pkgs.bash
          pkgs.coreutils
        ];

        commonShellHook = ''
          # expose qmake and moc on PATH
          export PATH="${qt.qtbase.dev}/bin:$PATH"

          # let the linker find Qt frameworks on macOS
          export DYLD_FRAMEWORK_PATH="${qt.qtbase}/lib:$DYLD_FRAMEWORK_PATH"
          export DYLD_LIBRARY_PATH="${qt.qtbase}/lib:$DYLD_LIBRARY_PATH"

          # Mark that we're inside the limn dev shell so scripts can
          # bail clearly if invoked outside it.
          export LIMN_NIX_SHELL=1

          echo "qmake:      $(which qmake)"
          echo "Qt version: $(qmake -query QT_VERSION)"
          # `sbcl --version` is incompatible with --no-userinit (which our
          # sandbox wrapper injects); read the version from the nix store
          # path instead.  Equivalent semantics, doesn't hit the SBCL
          # arg-parser quirk.
          echo "sbcl:       SBCL ${pkgs.sbcl.version} (sandboxed: $(which sbcl))"
        '';
      in {
        devShells = {
          # Host development shell (macOS / Linux).
          default = pkgs.mkShell {
            name = "sioyek-core";
            packages = commonPackages;
            shellHook = commonShellHook;
          };

          # E2E test container shell — superset of default.
          # Consumed by Dockerfile via `nix develop /limn#docker --command ...`.
          docker = pkgs.mkShell {
            name = "sioyek-core-docker";
            packages = commonPackages ++ dockerExtras;
            shellHook = commonShellHook;
          };
        };
      });
}

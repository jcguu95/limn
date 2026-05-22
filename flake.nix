{
  description = "sioyek-core: stripped PDF rendering engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        qt = pkgs.qt6;
      in {
        devShells.default = pkgs.mkShell {
          name = "sioyek-core";

          packages = [
            # Qt modules sioyek needs
            qt.qtbase
            qt.qtsvg
            qt.qtdeclarative      # quickwidgets
            qt.qtspeech

            # mupdf — PDF rendering. nixpkgs ships 1.27+ which has
            # fz_page_label etc. — Debian bookworm's 1.20.3 doesn't.
            pkgs.mupdf

            # mupdf's third-party deps. nixpkgs builds mupdf with
            # USE_SYSTEM_LIBS=yes, so the final binary links these
            # dynamically rather than statically through a libmupdf-third
            # like sioyek's vendored build does.
            pkgs.openjpeg pkgs.jbig2dec pkgs.gumbo
            pkgs.harfbuzz pkgs.freetype pkgs.libjpeg

            # build tools
            pkgs.gnumake
            pkgs.cmake
            pkgs.pkg-config
          ];

          shellHook = ''
            # expose qmake and moc on PATH
            export PATH="${qt.qtbase.dev}/bin:$PATH"

            # let the linker find Qt frameworks on macOS
            export DYLD_FRAMEWORK_PATH="${qt.qtbase}/lib:$DYLD_FRAMEWORK_PATH"
            export DYLD_LIBRARY_PATH="${qt.qtbase}/lib:$DYLD_LIBRARY_PATH"

            echo "qmake: $(which qmake)"
            echo "Qt version: $(qmake -query QT_VERSION)"
          '';
        };
      });
}

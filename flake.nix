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

{ pkgs ? import nixpkgs (haskellNixpkgsArgs // {
    overlays = haskellNixpkgsArgs.overlays ++ [ (import ./nix/overlays/gtk-debug.nix) ];
  } // (if system == null then {} else { inherit system; }))
, nixpkgs ? haskellNixSrc + "/nixpkgs"
, haskellNixpkgsArgs ? import haskellNixSrc
, haskellNixSrc ? builtins.fetchTarball {
    url = "https://github.com/input-output-hk/haskell.nix/archive/1917908ae9fd0ee6d5729301bd3283d7bf6c6383.tar.gz";
    sha256 = "10qssfww3zwrvqnh9jxpxqqm6fv5qz592ivpx725nk2xfwrskqfk";
  }
, haskellCompiler ? "ghc883"
, system ? null
}:
let
  frameworks = pkgs.lib.optionals pkgs.stdenv.isDarwin (
    with pkgs.darwin.apple_sdk.frameworks; [ Cocoa Carbon CoreGraphics WebKit ]);
  project = pkgs.haskell-nix.cabalProject' {
    name = "leksah";
    src = pkgs.haskell-nix.haskellLib.cleanGit { src = ./.; name = "leksah"; };
    ghc = pkgs.pkgs.haskell-nix.compiler.${haskellCompiler};
    modules = [
      { reinstallableLibGhc = true; }
      ({ config, ...}: {
        packages.haddock-api.components.library.doHaddock = false;
        # packages.leksah.components.sublibs.leksah-nogtk.doHaddock = false;
        packages.gi-gtk.components.setup.frameworks = frameworks;
        packages.gi-gtkosxapplication.components.setup.frameworks = frameworks;
        packages.gi-gtksource.components.setup.frameworks = frameworks;
        packages.gi-gtk-hs.components.library.frameworks = frameworks;
        packages.vcsgui.components.library.frameworks = frameworks;
        packages.vcsgui.components.exes.vcsgui.frameworks = frameworks;
        packages.ltk.components.library.frameworks = frameworks;
        packages.leksah.components.library.frameworks = frameworks;
        packages.leksah.components.library.libs = pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.darwin.libobjc;
        packages.vault.components.library.doHaddock = false;
      })
    ] ++
      pkgs.lib.optional (haskellCompiler == "ghc882" || haskellCompiler == "ghc883") {
        packages.haddock-api.src = pkgs.fetchgit {
          url = "https://github.com/haskell/haddock";
          rev = "be8b02c4e3cffe7d45b3dad0a0f071d35a274d65";
          sha256 = "0b6c78paq6hh8n9pasnwwmlhfk745ha84fd84500mcpjlrsm5qgf";
        } + "/haddock-api";
      };
  };
  launch-leksah-script = pkgs.writeShellScriptBin "launch-leksah" ''
    "$@"
  '';
  launch-leksah = pkgs.stdenv.mkDerivation {
      name = "launch-leksah";
      nativeBuildInputs = with pkgs; [ wrapGAppsHook makeWrapper ];
      buildInputs = with pkgs; [
        gnome3.gtk
        gnome3.dconf
        gnome3.defaultIconTheme
        gnome3.gsettings_desktop_schemas
      ];
      src = ./linux;
      buildPhase = ''
          mkdir -p $out
        '';
      installPhase = ''
        mkdir -p $out/bin
        ln -s ${launch-leksah-script}/bin/launch-leksah $out/bin
        cp launch-leksah/Info.plist $out/bin
        wrapProgram $out/bin/launch-leksah \
          --prefix 'PATH' ':' "${pkgs.cabal-install}/bin" \
          --suffix 'PATH' ':' "${project.hsPkgs.doctest.components.exes.doctest}/bin" \
          --suffix 'LD_LIBRARY_PATH' ':' "${pkgs.cairo}/lib" \
          --set 'XDG_DATA_DIRS' ""
        '';
  };
  wrapped-leksah = pkgs.stdenv.mkDerivation {
      name = "leksah";
      nativeBuildInputs = with pkgs; [ wrapGAppsHook makeWrapper ];
      buildInputs = with pkgs; [
        gnome3.gtk
        gnome3.dconf
        gnome3.defaultIconTheme
        gnome3.gsettings_desktop_schemas
      ];
      src = ./linux;
      buildPhase =
        if pkgs.stdenv.isLinux then ''
          mkdir -p $out/share
          cp -r * $out/share/
        '' else ''
          mkdir -p $out
        '';
      installPhase = ''
        mkdir -p $out/bin
        ln -s ${project.hsPkgs.leksah.components.exes.leksah}/bin/leksah $out/bin/leksah
        wrapProgram $out/bin/leksah \
          --prefix 'PATH' ':' "${project.hsPkgs.leksah-server.components.exes.leksah-server}/bin" \
          --prefix 'PATH' ':' "${project.hsPkgs.vcsgui.components.exes.vcsgui}/bin" \
          --prefix 'PATH' ':' "${pkgs.cabal-install}/bin" \
          --suffix 'PATH' ':' "${project.hsPkgs.doctest.components.exes.doctest}/bin" \
          --suffix 'LD_LIBRARY_PATH' ':' "${pkgs.cairo}/lib" \
          --set 'XDG_DATA_DIRS' ""
      '';
  };
  wrapped-leksah-warp = pkgs.stdenv.mkDerivation {
      name = "leksah-warp";
      nativeBuildInputs = with pkgs; [ makeWrapper ];
      src = ./linux;
      buildPhase =
        if pkgs.stdenv.isLinux then ''
          mkdir -p $out/share
          cp -r * $out/share/
        '' else ''
          mkdir -p $out
        '';
      installPhase = ''
        mkdir -p $out/bin
        ln -s ${project.hsPkgs.leksah.components.exes.leksah-warp}/bin/leksah-warp $out/bin/leksah
        wrapProgram $out/bin/leksah \
          --prefix 'PATH' ':' "${project.hsPkgs.leksah-server.components.exes.leksah-server}/bin" \
          --prefix 'PATH' ':' "${pkgs.cabal-install}/bin" \
          --suffix 'PATH' ':' "${project.hsPkgs.doctest.components.exes.doctest}/bin" \
          --set 'XDG_DATA_DIRS' ""
      '';
  };
  shells = {
    ghc = (project.hsPkgs.shellFor {
        packages = ps: with ps; [
          leksah-server
          leksah
          ltk ];
      }).overrideAttrs (oldAttrs: {
        buildInputs = frameworks ++ [
          pkgs.haskell-nix.cabal-install
          pkgs.stack
          pkgs.gobject-introspection
          pkgs.pkgconfig
          pkgs.gtk3
          pkgs.gtksourceview3
        ] ++ pkgs.lib.optional pkgs.stdenv.isDarwin pkgs.gtk-mac-integration;
      });
  };
in
  project // {
    inherit shells launch-leksah wrapped-leksah wrapped-leksah-warp pkgs;
  }


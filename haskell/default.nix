{
  perSystem = { config, pkgs, lib, self', ... }: {
    # TODO: rename default to something else
    haskellProjects.default = {
      autoWire = [ "packages" "checks" "apps" ];
      settings = {
        cac_client.custom = _: self'.packages.cac_client;
      };
    };
    packages.default = self'.packages.haskell-cac.overrideAttrs (oa: {
      cac_client = self'.packages.cac_client;
      nativeBuildInputs = (oa.nativeBuildInputs or []) ++ [
        pkgs.makeWrapper
      ];
      # https://gist.github.com/CMCDragonkai/9b65cbb1989913555c203f4fa9c23374
      postFixup = (oa.postFixup or "") + ''
        wrapProgram $bin/bin/haskell-cac \
          --set ${if pkgs.stdenv.isLinux then "LD_LIBRARY_PATH" else "DYLD_LIBRARY_PATH"} $cac_client/lib
      '';
    });
    apps.default.program = lib.getExe self'.packages.default;

    devShells.haskell = pkgs.mkShell {
      name = "cac-haskell";
      inputsFrom = [ 
        config.haskellProjects.default.outputs.devShell 
        config.flake-root.devShell
        self'.devShells.haskell-cac
      ];
      # TODO: set once, based on platform
      # TODO(refactor): SRID: can we do this in one place?
      # LD_LIBRARY_PATH = "${self'.packages.cac_client}/lib";
    };
    devShells.haskell-cac = pkgs.mkShell {
      name = "cac-haskell-cac";
      shellHook = ''
        export DYLD_LIBRARY_PATH="${self'.packages.cac_client}/lib"
      '';
    };
  };
}

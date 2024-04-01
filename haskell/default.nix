{
  perSystem = { config, pkgs, self', ... }: {
    haskellProjects.default = {
      autoWire = [ "packages" "checks" "apps" ];
      settings = {
        cac_client.custom = _: self'.packages.cac_client;
      };
    };

    devShells.haskell-cac = pkgs.mkShell {
      name = "cac-haskell";
      inputsFrom = [
        config.haskellProjects.default.outputs.devShell
        config.flake-root.devShell
      ];
      shellHook = ''
        export LIBRARY_PATH=${self'.packages.cac_client}/lib
      '';
    };
  };
}
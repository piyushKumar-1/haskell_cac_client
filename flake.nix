{
  inputs = {
    common.url = "github:nammayatri/common";
    nixpkgs.follows = "common/nixpkgs";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.common.lib.mkFlake { inherit inputs; } {
      imports = [
        ./haskell
        ./rust/cac_client
      ];
      perSystem = { pkgs, lib, system, self', ... }: {
        devShells.default = pkgs.mkShell {
          inputsFrom = [
            self'.devShells.haskell-cac
          ];
        };
        process-compose = { };
        # packages.default = self'.packages.haskell-cac
      };
    };
}

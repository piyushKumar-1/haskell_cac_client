{
  inputs = {
    common.url = "github:nammayatri/common";
    nixpkgs.follows = "common/nixpkgs";
  };

  outputs = inputs:
    inputs.common.lib.mkFlake { inherit inputs; } {
      imports = [
        ./haskell
        ./rust/cac_client
      ];
      perSystem = { pkgs, lib, system, self', ... }: {
        process-compose = { };
        # packages.default = self'.packages.haskell-cac
      };
    };
}

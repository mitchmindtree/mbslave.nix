{
  description = "";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs:
    let
      overlays = [ inputs.self.overlays.default ];
      perSystemPkgs =
        f:
        inputs.nixpkgs.lib.genAttrs (import inputs.systems) (
          system: f (import inputs.nixpkgs { inherit overlays system; })
        );
    in
    {
      overlays = {
        default = final: prev: {
          # Declare packages here.
        };
      };

      packages = perSystemPkgs (pkgs: { });

      devShells = perSystemPkgs (pkgs: { });

      formatter = perSystemPkgs (pkgs: pkgs.nixfmt-tree);
    };
}

{
  description = "mbslave packaged for Nix, with a NixOS module for a replicated MusicBrainz mirror";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
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
          mbslave = final.callPackage ./pkgs/mbslave.nix { };
        };
      };

      nixosModules.default = ./nixos/mbslave.nix;

      packages = perSystemPkgs (pkgs: {
        inherit (pkgs) mbslave;
        default = pkgs.mbslave;
      });

      checks = perSystemPkgs (pkgs: {
        nixos = pkgs.testers.runNixOSTest ./tests/mbslave.nix;
      });

      devShells = perSystemPkgs (pkgs: { });

      formatter = perSystemPkgs (pkgs: pkgs.nixfmt-tree);
    };
}

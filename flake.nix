{
  description = "Python environment providing spektrafilm and spectral_film_lut";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    haldclut-repo = {
      url = "github:cedeber/hald-clut";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      haldclut-repo,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      # Create a combined source tree
      # Takes art-src as an argument
      mkCombinedSource = pkgs: art-src: pkgs.runCommand "extlut-src" { } ''
        mkdir -p $out/src/extlut
        cp ${./pyproject.toml} $out/pyproject.toml
        cp ${./uv.lock} $out/uv.lock
        cp -r ${art-src}/tools/extlut/* $out/src/extlut/
        touch $out/src/extlut/__init__.py
      '';

      # Everything that depends on pkgs or system goes in here
      systemOutputs = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # NOTE: We need the release after 1.26.3, which isn't out. then we can use nixpkgs unstable
          # art-src = pkgs.art.src;

          art-src = pkgs.fetchFromGitHub {
            owner = "artraweditor";
            repo = "ART";
            rev = "2daddeb9a1951f1da9906de9d1f6f35063ee106f";
            sha256 = "sha256-ccUEGKOU33HdwZJ/toXLrlMRSQVRFwAA+wJZ1ZULF4c=";
          };
          combinedSource = mkCombinedSource pkgs art-src;
          
          workspace = uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = combinedSource;
          };

          overlay = workspace.mkPyprojectOverlay {
            sourcePreference = "wheel";
          };

          editableOverlay = workspace.mkEditablePyprojectOverlay {
            root = "$REPO_ROOT";
          };

          pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
            python = pkgs.python3;
          }).overrideScope (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              (
                final: prev:
                let
                  inherit (final) pkgs;
                  hacks = pkgs.callPackage pyproject-nix.build.hacks { };
                in
                {
                  numba = hacks.nixpkgsPrebuilt {
                    from = pkgs.python313Packages.numba;
                    prev = prev.numba;
                  };
                  pyqt6 = hacks.nixpkgsPrebuilt {
                    from = pkgs.python313Packages.pyqt6;
                  };
                  shiboken6 = hacks.nixpkgsPrebuilt {
                    from = pkgs.python313Packages.shiboken6;
                  };
                  pyside6 = hacks.nixpkgsPrebuilt {
                    from = pkgs.python313Packages.pyside6;
                  };
                }
              )
            ]
          );
        in {
          inherit workspace pythonSet editableOverlay combinedSource;
        }
      );

    in
    {
      homeManagerModules.default = { config, lib, pkgs, ... }: 
        let
          cfg = config.programs.extlut;
        in
        {
          options.programs.extlut = {
            enable = lib.mkEnableOption "extlut JSON configurations for ART";
            clutDir = lib.mkOption {
              type = lib.types.str;
              description = "Directory where the extlut JSON files should be installed (relative to home).";
              example = ".config/ART/cluts";
            };
          };

          config = lib.mkIf cfg.enable {
            home.file."${cfg.clutDir}" = {
              source = self.packages.${pkgs.stdenv.hostPlatform.system}.cluts;
              recursive = true;
            };
          };
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (systemOutputs.${system}) workspace pythonSet editableOverlay;
          
          virtualenv = (pythonSet.overrideScope editableOverlay).mkVirtualEnv "extlut-dev-env" (
            workspace.deps.all
          );
        in
        {
          default = pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = virtualenv.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
        }
      );

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (systemOutputs.${system}) workspace pythonSet combinedSource;
          
          fullEnv = pythonSet.mkVirtualEnv "extlut-full-env" (
            workspace.deps.default
          );

          spektrafilm_mklut = pkgs.writeShellScriptBin "spektrafilm_mklut" ''
            exec ${fullEnv}/bin/spektrafilm_mklut "$@"
          '';
          
          spectral_film_mklut = pkgs.writeShellScriptBin "spectral_film_mklut" ''
            exec ${fullEnv}/bin/spectral_film_mklut "$@"
          '';

          spektrafilm_json = pkgs.runCommand "spektrafilm.json" { } ''
            substitute ${combinedSource}/src/extlut/ART_agx_film.json $out \
              --replace-fail "python3 spektrafilm_mklut.py --server" "${lib.getExe spektrafilm_mklut} --server"
          '';

          spectral_film_json = pkgs.runCommand "spectral_film.json" { } ''
            substitute ${combinedSource}/src/extlut/ART_spectral_film.json $out \
              --replace-fail "python3 spectral_film_mklut.py --server" "${lib.getExe spectral_film_mklut} --server"
          '';

          haldclut = "${haldclut-repo}/HaldCLUT";
        in
        {
          inherit spektrafilm_mklut spectral_film_mklut spektrafilm_json spectral_film_json;

          cluts = pkgs.symlinkJoin {
            name = "cluts";
            paths = [
              (pkgs.linkFarm "extra-cluts" [
                {
                  name = "ART_spectral_film.json";
                  path = spectral_film_json;
                }
                {
                  name = "ART_agx_film.json";
                  path = spektrafilm_json;
                }
              ])
              haldclut
            ];
          };

          default = fullEnv;
        }
      );
    };
}

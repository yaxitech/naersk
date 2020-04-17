{ cargo
, darwin
, fetchurl
, jq
, lib
, lndir
, remarshal
, rsync
, runCommand
, rustc
, stdenv
, writeText
, zstd
, tree
}@defaultBuildAttrs:

let
  libb = import ./lib.nix { inherit tree lib writeText runCommand remarshal stdenv; };

  builtinz = builtins // import ./builtins
    { inherit lib writeText remarshal runCommand; };

  mkConfig = arg:
    import ./config.nix { inherit lib arg libb builtinz; };

  buildPackage = arg:
    let
      config = mkConfig arg;
      gitDependencies =
        libb.findGitDependencies { inherit (config) cargotomls cargolock; };
      cargoconfig =
        if builtinz.pathExists (toString config.root + "/.cargo/config")
        then (config.root + "/.cargo/config")
        else null;
      build = args: import ./build.nix (
        {
          inherit gitDependencies;
          version = config.packageVersion;
        } // config.buildConfig // defaultBuildAttrs // args
      );

      # the dependencies from crates.io
      buildDeps =
        build
          {
            pname = "${config.packageName}-deps";
            src = libb.dummySrc' {
              name = "${config.packageName}";
              src = config.root;
            };
            inherit (config) userAttrs;
            # TODO: custom cargoTestCommands should not be needed here
            cargoTestCommands = map (cmd: "${cmd} || true") config.buildConfig.cargoTestCommands;
            copyTarget = true;
            copyBins = false;
            copyBinsFilter = ".";
            copyDocsToSeparateOutput = false;
            builtDependencies = [];
          };

      buildDep = name: members: built:
        build
          {
            pname = "${config.packageName}-${name}";
            src = libb.dummySrc' {
              inherit name;
              src = config.root;
              keepMembers = members;
            };
            inherit (config) userAttrs;
            # TODO: custom cargoTestCommands should not be needed here
            cargoTestCommands = map (cmd: "${cmd} || true") config.buildConfig.cargoTestCommands;
            copyTarget = true;
            copyBins = false;
            copyBinsFilter = ".";
            copyDocsToSeparateOutput = false;
            builtDependencies = built;
          };

      # the top-level build
      buildTopLevel =
        build
          {
            pname = config.packageName;
            inherit (config) userAttrs src;
            builtDependencies =
              let
                deps =
                  { crate-a = [];
                    crate-b = [ "crate-a" ];
                    crate-c = [ "crate-a" "crate-b" ];
                  };
                builtDeps = lib.mapAttrs (k: v: buildDep k ([ k ] ++ v) (map (x: builtDeps.${x}) v)) deps;
              in
            lib.optionals (! config.isSingleStep)
            [
              buildDeps
              #crate-c
            ] ++
            # TODO: we don't need to pre-install all the deps, we only need the
            # roots of the DAG. but for simplicity...
            builtins.attrValues builtDeps;
          };
    in
      buildTopLevel;
in
{ inherit buildPackage; }

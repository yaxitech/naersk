{ src
, bash
, nix
, incremental
, coreutils
, preBuild
  #| What command to run during the build phase
, cargoBuild
, #| What command to run during the test phase
  cargoTestCommands
, copyTarget
  #| Whether or not to compress the target when copying it
, compressTarget
  #| Whether or not to copy binaries to $out/bin
, copyBins
, doCheck
, doDoc
, doDocFail
, copyDocsToSeparateOutput
  #| Whether to remove references to source code from the generated cargo docs
  #  to reduce Nix closure size. By default cargo doc includes snippets like the
  #  following in the generated highlighted source code in files like: src/rand/lib.rs.html:
  #
  #    <meta name="description" content="Source to the Rust file `/nix/store/mdwpqciww926xayfasl85i4wvvpbgb9a-crates-io/rand-0.7.0/src/lib.rs`.">
  #
  #  The reference to /nix/store/...-crates-io/... causes a run-time dependency
  #  to the complete source code blowing up the Nix closure size for no good
  #  reason. If this argument is set to true (which is the default) the latter
  #  will be replaced by:
  #
  #    <meta name="description" content="Source to the Rust file removed to reduce Nix closure size.">
  #
  #  Which drops the run-time dependency on the crates-io source thereby
  #  significantly reducing the Nix closure size.
, removeReferencesToSrcFromDocs
, gitDependencies
, pname
, version
, rustc
, cargo
, override
, buildInputs
, builtDependencies
, release
, cargoOptions
, stdenv
, lib
, rsync
, jq
, darwin
, writeText
, writeScript
, symlinkJoin
, runCommand
, remarshal
, crateDependencies
, zstd
, fetchurl
, findutils
}:

let
  builtinz =
    builtins // import ./builtins
      { inherit lib writeText remarshal runCommand; };

  # All the git dependencies, as a list
  gitDependenciesList =
    lib.concatLists (lib.mapAttrsToList (_: ds: ds) gitDependencies);

  # This unpacks all git dependencies:
  #   $out/rand
  #   $out/rand/Cargo.toml
  #   $out/rand_core
  #   ...
  # It does so by discovering all the `Cargo.toml`s and creating a directory in
  # $out for each one.
  # NOTE:
  #   Only non-virtual manifests are taken into account. That is, only cargo
  #   tomls that have a [package] sections with a `name = ...`. The
  #   implementation is a bit tricky and basically akin to parsing TOML with
  #   bash. The reason is that there is no lightweight jq-equivalent available
  #   in nixpkgs (rq fails to build).
  #   We discover the name (in any) in three steps:
  #     * grab anything that comes after `[package]`
  #     * grab the first line that contains `name = ...`
  #     * grab whatever is surrounded with `"`s.
  #   The last step is very, very slow.
  unpackedGitDependencies = runCommand "git-deps"
    { nativeBuildInputs = [ jq ]; }
    ''
      mkdir -p $out

      while read -r dep; do
        checkout=$(echo "$dep" | jq -cMr '.checkout')
        url=$(echo "$dep" | jq -cMr '.url')
        tomls=$(find $checkout -name Cargo.toml)
        while read -r toml; do
          name=$(cat $toml \
            | sed -n -e '/\[package\]/,$p' \
            | grep -m 1 "^name\W" \
            | grep -oP '(?<=").+(?=")' \
            || true)
          if [ -n "$name" ]; then
            echo "$url Found crate '$name'"
            cp -r $(dirname $toml) $out/$name
            chmod +w $out/$name
            echo '{"package":null,"files":{}}' > $out/$name/.cargo-checksum.json
          fi
        done <<< "$tomls"
      done < <(cat ${
        builtins.toFile "git-deps-json" (builtins.toJSON gitDependenciesList)
        } | jq -cMr '.[]')
    '';

  drv = stdenv.mkDerivation {
    name = "${pname}-${version}";
    inherit
      src
      doCheck
      version
      preBuild
      ;

    # The cargo config with source replacement. Replaces both crates.io crates
    # and git dependencies.
    cargoconfig = builtinz.toTOML {
      source = {
        crates-io = { replace-with = "nix-sources"; };
        nix-sources = {
          directory = symlinkJoin {
            name = "crates-io";
            paths = map (v: unpackCrate v.name v.version v.sha256)
              crateDependencies ++ [ unpackedGitDependencies ] ;
          };
        };
      } // lib.listToAttrs ( map
          (e:
            { name = e.url; value =
                { git = e.url;
                  rev = e.rev;
                  replace-with = "nix-sources";
                };
            })
          gitDependenciesList
          );
    };

    outputs = [ "out" ] ++ lib.optional (doDoc && copyDocsToSeparateOutput) "doc";
    preInstallPhases = lib.optional doDoc [ "docPhase" ];

    # Otherwise specifying CMake as a dep breaks the build
    dontUseCmakeConfigure = true;

    nativeBuildInputs = [
      cargo
      # needed at various steps in the build
      jq
      rsync
    ];

    buildInputs = stdenv.lib.optionals stdenv.isDarwin [
      darwin.Security
      darwin.apple_sdk.frameworks.CoreServices
      darwin.cf-private
    ] ++ buildInputs;

    # iff not in a shell
    inherit builtDependencies;

    RUSTC = if ! incremental then "${rustc}/bin/rustc" else
      let
        inner = writeScript "rustc-inner"
        ''
        #!${bash}/bin/bash
        set -euo pipefail

        target_dir=$out/target

        ${coreutils}/bin/mkdir -p $out/target
        ${coreutils}/bin/ls $out/target
        ${rsync}/bin/rsync -ah \
          --no-owner \
          --no-perms \
          "$CARGO_TARGET_DIR/" \
          "$target_dir/" \
          >/dev/null 2>/dev/null

        ${coreutils}/bin/chmod -R +w $target_dir
        ${coreutils}/bin/ls $out/target

        export CARGO_TARGET_DIR=$target_dir

        set -euo pipefail
        for k in $envdir/*; do
          export $(${coreutils}/bin/basename $k)="$(${coreutils}/bin/cat $k)"
        done

        mkdir -p $out
        source $argsfile
        for i in ''${!args[@]}; do
          arg="''${args[i]}"
          args[$i]="''${arg/CARGO_TARGET_DIR/$CARGO_TARGET_DIR}"
          #echo "$arg -> ''${args[i]}"
        done
        echo "ACTUALLY BUILDING rustc" "''${args[@]}"
        ${rustc}/bin/rustc "''${args[@]}" \
          >$out/sout 2>$out/serr || echo "$?" >$out/rc

        if [ ! -f $out/rc ]; then
          echo "0" > $out/rc
        fi

        #echo "RC is "
        #cat $out/rc

        #echo and out is $out
        #echo "Leaving inner."
        '';

        fakerust = writeScript "rustc"
        ''
        #!${bash}/bin/bash

        # this is cargo just asking for the version
        if [ $# -eq 1 ]; then
          ${rustc}/bin/rustc "$@"
          exit $?
        fi

        args=( )

        declare -A store_paths

        target_dir=$(mktemp -d)/target

        argsfile=$(mktemp -d)/args
        args=( )
        while [[ $# -gt 0 ]]; do
          #echo "ARG: $1" >&2
          if [ -f "$1" ]; then
            if [[ "$1" =~ ^/ ]]; then
              echo "FILE $1 EXISTS BUT ABSOLUTE" >&2
            else
              echo "FILE $1 EXISTS" >&2
            fi
          else
            echo "NO SUCH FILE: $1" >&2
          fi
          args+=( "''${1/$CARGO_TARGET_DIR/CARGO_TARGET_DIR}" )
          shift
        done

        declare -p args > $argsfile

        # TODO: this fails on concurrent builds

        envdir=$(mktemp -d)/env
        mkdir -p $envdir

        # TODO: reset CARGO_TARGET_DIR
        while IFS='=' read -r -d "" k v; do
          if [[ $v =~ $NIX_BUILD_TOP ]]; then
            #echo "Skipping env variable $k" >&2
            true
          elif [[ $k = "out" ]]; then
            #echo "Skipping env variable $k" >&2
            true
          else
            while IFS= read -r sp; do
              store_paths["$sp"]=1
            done < <(echo "$v" | grep -o '/nix/store/[a-zA-Z0-9_+.\-]*' || true)
            echo "$v" > $envdir/$k
          fi
        done < <(env -0)

        #echo "syncing... " >&2
        ${rsync}/bin/rsync \
          -ah \
          --no-owner \
          --no-perms \
          "$CARGO_TARGET_DIR/" \
          "$target_dir/" \
          >/dev/null 2>/dev/null

        # TODO: add store_paths

        result=$(mktemp -d)/res

        #echo "Inner build" >&2
        # TODO: forward local files
        ${nix}/bin/nix build -o $result -L '(
          derivation
            { name = "rustc-inner";
              system = "${builtins.currentSystem}";
              builder = /bin/sh;
              args = [
                "-c"
                (builtins.storePath ${inner})
              ];
              envdir = '$envdir';
              argsfile = '$argsfile';
              CARGO_TARGET_DIR = '$target_dir';
            }
          )' >&2

        if [ -f $result/sout ]; then
          cat $result/sout
        fi

        if [ -f $result/serr ]; then
          cat $result/serr >&2
        fi

        if [ -d $result/target ]; then
          #echo "Syncing back" >&2
          ${rsync}/bin/rsync \
            -ah \
            --no-owner \
            --no-perms \
            "$result/target/" \
            "$CARGO_TARGET_DIR/" \
            >/dev/null 2>/dev/null
          #echo "Done syncing" >&2
        fi


        exit "$(< $result/rc)"
        ''; in fakerust;

    configurePhase = ''
      export CARGO_TARGET_DIR=$(mktemp -d)
      export _NIX_TEST_NO_SANDBOX=1
      cargo_release=( ${lib.optionalString release "--release" } )
      cargo_options=( ${lib.escapeShellArgs cargoOptions} )

      runHook preConfigure

      logRun() {
        echo "$@"
        eval "$@"
      }

      mkdir -p target

      for dep in $builtDependencies; do
          echo pre-installing dep $dep
          if [ -d "$dep/target" ]; then
            rsync -rl \
              --no-perms \
              --no-owner \
              --no-group \
              --chmod=+w \
              --executability $dep/target/ target
          fi
          if [ -f "$dep/target.tar.zst" ]; then
            ${zstd}/bin/zstd -d "$dep/target.tar.zst" --stdout | tar -x
          fi

          if [ -d "$dep/target" ]; then
            chmod +w -R target
          fi
        done

      export CARGO_HOME=''${CARGO_HOME:-$PWD/.cargo-home}
      mkdir -p $CARGO_HOME

      echo "$cargoconfig" > $CARGO_HOME/config

      # TODO: figure out why "1" works whereas "0" doesn't
      find . -type f -exec touch --date=@1 {} +

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      logRun ${cargoBuild}

      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck

      ${lib.concatMapStringsSep "\n" (cmd: "logRun ${cmd}") cargoTestCommands}

      runHook postCheck
    '';


    docPhase = lib.optionalString doDoc ''
      runHook preDoc

      logRun cargo doc --offline "''${cargo_release[*]}" || ${if doDocFail then "false" else "true" }

      ${lib.optionalString removeReferencesToSrcFromDocs ''
      # Remove references to the source derivation to reduce closure size
            match='<meta name="description" content="Source to the Rust file `${builtins.storeDir}[^`]*`.">'
      replacement='<meta name="description" content="Source to the Rust file removed to reduce Nix closure size.">'
      find target/doc -name "*\.rs\.html" -exec sed -i "s|$match|$replacement|" {} +
    ''}

      runHook postDoc
    '';

    installPhase =
      ''
        runHook preInstall

        ${lib.optionalString copyBins ''
        if [ -d out ]; then
          mkdir -p $out/bin
          find out -type f -executable -exec cp {} $out/bin \;
        fi
      ''}

        ${lib.optionalString copyTarget ''
        mkdir -p $out
        ${if compressTarget then
        ''
          tar -c target | ${zstd}/bin/zstd -o $out/target.tar.zst
        '' else
        ''
          cp -r target $out
        ''}
      ''}

        ${lib.optionalString (doDoc && copyDocsToSeparateOutput) ''
        cp -r target/doc $doc
      ''}

        runHook postInstall
      '';
    passthru = {
      # Handy for debugging
      inherit builtDependencies;
    };
  };

  # XXX: the actual crate format is not documented but in practice is a
  # gzipped tar; we simply unpack it and introduce a ".cargo-checksum.json"
  # file that cargo itself uses to double check the sha256
  unpackCrate = name: version: sha256:
    let
      crate = fetchurl {
        url = "https://crates.io/api/v1/crates/${name}/${version}/download";
        inherit sha256;
      };
    in
      runCommand "unpack-${name}-${version}" {}
        ''
          mkdir -p $out
          tar -xzf ${crate} -C $out
          echo '{"package":"${sha256}","files":{}}' > $out/${name}-${version}/.cargo-checksum.json
        '';
in
drv.overrideAttrs override

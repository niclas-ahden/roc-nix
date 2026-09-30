{
  description = "The Roc compiler, built from source, shared by our Roc repos";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # roc keeps its flake in `src/`. Taking it as a flake gives us both the
    # source tree and the nixpkgs that revision locked for itself. Consumers
    # override this input with their own revision.
    roc-src.url = "github:roc-lang/roc?dir=src";
  };

  outputs = { nixpkgs, flake-utils, roc-src, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
      let
        # Only for this flake's own tooling (not the compiler build).
        ownPkgs = import nixpkgs { inherit system; };

        # Fails early on `flake = false` or a missing `?dir=src`.
        rocFlakeOf = f:
          if f ? sourceInfo && f ? inputs then f
          else
            throw ''
              roc-nix: the `roc-src` input has to be roc's own flake.
              Use url = "github:roc-lang/roc/<rev>?dir=src" and no `flake = false`.
            '';

        # Read the Zig version from the revision's `build.zig.zon`, so older
        # revisions keep building with the Zig they need. roc's own flake said
        # plain `pkgs.zig` for a long time, so here we'll parse it out.
        zigAttrFor = lib: src:
          let
            zon = "${src}/build.zig.zon";
            hits = lib.filter (m: m != null)
              (map
                (builtins.match ''[[:space:]]*\.minimum_zig_version = "([0-9]+)\.([0-9]+)\.[^"]*".*'')
                (lib.splitString "\n" (builtins.readFile zon)));
          in
          if hits == [ ] then
            throw "roc-nix: no .minimum_zig_version in ${zon}, pass `zig` to mkRoc"
          else
            let m = builtins.head hits; in
            "zig_${builtins.elemAt m 0}_${builtins.elemAt m 1}";

        # roc's `build.zig.zon.nix` is generated (zon2nix) and upstream has
        # bumped the roc-bootstrap release in `build.zig.zon` without
        # regenerating it (roc 89f0d679b2, 2026-09-06). The prebuilts are lazy
        # dependencies, so a build only misses the one for its own host. When
        # the lock lacks it, mkRoc fetches the tarball `build.zig.zon` names
        # instead. Nix needs the tarball's own hash for that, keyed here by the
        # zig package hash `build.zig.zon` gives it. To add a release:
        #
        #   nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url <url>)"
        #
        # Entries stay harmless once upstream's lock catches up.
        bootstrapSha256 = {
          # llvm-21.1.8-scaling-2
          "N-V-__8AAGRcMhjhLwO3ey8ICFyBlvCT3_7XhM1xrEzWIBRD" = "sha256-ybfR6i8Sk5dWJfOltkz1Rj2GcHoLOtVB49Td+eeZwm0="; # x86_64-linux-musl
          "N-V-__8AAHzIKhc4RFMeZgW2iBmdo3tsRO5ZpNElA4Fm7THu" = "sha256-LCLbPdwOOMeWV9t9KERXEG6Y9AJPQ1yoEO4rxbcQGQI="; # aarch64-linux-musl
          "N-V-__8AANLT0hHDnp788OOENaNTO0osBQU25xaf6WT4g75U" = "sha256-V1UrvlWJSAbU4ezWs9cLiWjFCLZcgeh1yZ2PXRbnrJ0="; # x86_64-macos-none
          "N-V-__8AAI7KVRG6J1Tp9i70olobTIwsFtoF_O54b2H3PnHZ" = "sha256-MB+Zw15SuQMZHbpixXLXTw77dlXdvw6Jf2gpOOFPNuU="; # aarch64-macos-none
        };

        # Repos passing the same arguments share one compiler build.
        #
        # ReleaseFast is what upstream ships as nightlies. ReleaseSafe is
        # useful for reproducing a suspected compiler fault.
        mkRoc =
          { rocFlake ? roc-src
          , src ? (rocFlakeOf rocFlake).sourceInfo
          , nixpkgs ? (rocFlakeOf rocFlake).inputs.nixpkgs
          , optimize ? "ReleaseFast"
          , cpu ? "baseline"
          , patches ? [ ]
          , zig ? null
          }:
          let
            pkgs = import nixpkgs { inherit system; };
            inherit (pkgs) lib;

            zigPkg =
              if zig != null then zig
              else
                let attr = zigAttrFor lib src; in
                  pkgs.${attr} or (throw "roc-nix: ${src} wants ${attr}, which this nixpkgs does not have");

            inherit (pkgs.stdenv) hostPlatform;
            isDarwin = hostPlatform.isDarwin;

            # Upstream's generated lock. It pins every dependency, the
            # roc-bootstrap prebuilts (LLVM, LLD, Binaryen, zlib) included,
            # as long as upstream regenerates it (see hostBootstrap below).
            vendored = pkgs.callPackage "${src}/build.zig.zon.nix" { zig = zigPkg; };

            # The roc-bootstrap entry for this host in `build.zig.zon`, as
            # `{ url, hash }`, or null on revisions that have none.
            hostBootstrap =
              let
                os = if isDarwin then "macos_none" else "linux_musl";
                entry = ".roc_deps_${hostPlatform.parsed.cpu.name}_${os} = .{";
                parts = lib.splitString entry (builtins.readFile "${src}/build.zig.zon");
                block = builtins.head (lib.splitString "}" (lib.last parts));
                m = builtins.match ''.*\.url = "([^"]*)".*\.hash = "([^"]*)".*'' block;
              in
              if builtins.length parts < 2 || m == null then null
              else { url = builtins.elemAt m 0; hash = builtins.elemAt m 1; };

            lockHasHostBootstrap =
              hostBootstrap == null
              || lib.hasInfix hostBootstrap.hash (builtins.readFile "${src}/build.zig.zon.nix");

            # Laid out the way `zig build --system` looks packages up: one
            # directory per package hash holding the extracted tree.
            hostBootstrapPkg = pkgs.runCommand "roc-bootstrap-${hostBootstrap.hash}"
              {
                src = pkgs.fetchurl {
                  inherit (hostBootstrap) url;
                  hash = bootstrapSha256.${hostBootstrap.hash} or (throw ''
                    roc-nix: build.zig.zon.nix in ${src} lacks the roc-bootstrap
                    package ${hostBootstrap.hash} that its build.zig.zon names, and
                    roc-nix has no hash for that tarball. Add one to bootstrapSha256:
                      nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url ${hostBootstrap.url})"
                  '');
                };
              } ''
              mkdir -p "$out/${hostBootstrap.hash}"
              tar -xf "$src" -C "$out/${hostBootstrap.hash}" --strip-components=1
            '';

            roc-deps =
              if lockHasHostBootstrap then vendored
              else
                pkgs.symlinkJoin {
                  name = "zig-packages";
                  paths = [ vendored hostBootstrapPkg ];
                };

            rev = src.shortRev or "dirty";

            # roc names its cache root (`~/.cache/roc/<version>`) after its
            # version string, which build.zig reads from git. A nix build has
            # no `.git`, so every revision would report `release-fast-no-git`
            # and share one cache root. Patched builds get a content hash tag
            # so they don't share a cache with the commit they came from.
            compilerVersion =
              let
                mode = {
                  Debug = "debug";
                  ReleaseSafe = "release-safe";
                  ReleaseFast = "release-fast";
                  ReleaseSmall = "release-small";
                }.${optimize};
                patchTag = lib.optionalString (patches != [ ])
                  "-p${builtins.substring 0 8 (builtins.hashString "sha256"
                    (lib.concatMapStrings builtins.readFile patches))}";
              in
              "${mode}-${rev}${patchTag}";

            # build.zig's default target leaves aarch64 on the build machine's
            # own CPU, so a build from a newer Mac could hit SIGILL on an older
            # one through the shared cache. Pin the floor instead.
            #
            # On Linux `-Dcpu` alone makes Zig drop roc's default target, musl
            # ABI included, so the triple has to be spelled out as well.
            targetFlags =
              lib.optional (!isDarwin) "-Dtarget=${hostPlatform.parsed.cpu.name}-linux-musl"
              ++ [ "-Dcpu=${cpu}" ];
          in
          pkgs.stdenv.mkDerivation {
            pname = "roc";
            version = rev;

            inherit src patches;

            nativeBuildInputs = [ zigPkg pkgs.removeReferencesTo ];

            dontConfigure = true;

            # `--system` points Zig at the prevendored dependencies, so the
            # build is offline. Keep notes out here, text inside the '' block
            # is part of the store path.
            #
            # Zig finds macOS frameworks through xcrun, which nix builds don't
            # have, but it also reads these two nixpkgs variables. Point them
            # at the SDK the darwin stdenv provides. `--sysroot` would turn
            # this detection off.
            buildPhase = ''
              export HOME=$TMPDIR
            '' + lib.optionalString isDarwin ''
              export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -iframework $SDKROOT/System/Library/Frameworks"
              export NIX_LDFLAGS="''${NIX_LDFLAGS:-} -L$SDKROOT/usr/lib"
            '' + ''
              zig build roc -Doptimize=${optimize} ${lib.concatStringsSep " " targetFlags} \
                -Dcompiler-version=${compilerVersion} \
                --system ${roc-deps} \
                --cache-dir $TMPDIR/zig-local-cache \
                --global-cache-dir $TMPDIR/zig-global-cache
            '';

            # roc looks for the libSystem.tbd stub it ships next to the binary,
            # same layout as the official nightlies.
            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/roc $out/bin/
            '' + lib.optionalString isDarwin ''
              cp -R src/cli/darwin $out/bin/darwin
            '';

            # The embedded builtins carry DWARF that names Zig's store path,
            # which pulls all of Zig, LLVM included, into the runtime closure.
            # Nothing reads those paths, so scrub the reference. Keep the
            # coreutils one, roc's native target detection runs its `env`.
            postFixup = ''
              remove-references-to -t ${zigPkg} $out/bin/roc
            '';

            passthru = { inherit roc-deps optimize cpu nixpkgs compilerVersion; zig = zigPkg; };

            meta = {
              description = "Roc";
              homepage = "https://github.com/roc-lang/roc";
              license = lib.licenses.upl;
              mainProgram = "roc";
              platforms = lib.platforms.unix;
            };
          };
      in
      {
        formatter = ownPkgs.nixpkgs-fmt;

        lib = { inherit mkRoc zigAttrFor; };

        packages = {
          default = mkRoc { };
          roc = mkRoc { };
          roc-safe = mkRoc { optimize = "ReleaseSafe"; };
          roc-deps = (mkRoc { }).roc-deps;
        };
      });
}

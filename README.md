# roc-nix

A Nix flake for the Roc compiler, capable of building the latest version or
a given commit which you're extra fond of.

Using `roc-nix` makes it easy to move your projects in lock-step and share
cached builds of the compiler.

## Use it

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Set your desired Roc revision (make sure to keep the `?dir=src` at the end)
    roc-src.url = "github:roc-lang/roc/53fa9b7659a739c9262606a4c4daf21828c2397e?dir=src";

    roc-nix = {
      url = "github:niclas-ahden/roc-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.roc-src.follows = "roc-src";
    };
  };

  outputs = { nixpkgs, flake-utils, roc-nix, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; }; in {
        devShells.default = pkgs.mkShell {
          buildInputs = [ roc-nix.packages.${system}.roc ];
        };
      });
}
```

`roc-nix.packages.${system}.roc` then builds the revision you pinned above.

Your `nixpkgs` above is used for your dev shell, but not for building the Roc
compiler (which uses the `nixpkgs` Roc's own flake locked for itself). That makes
it easier to re-use the same Roc compiler build across projects, since it doesn't
depend on which `nixpkgs` version your own project is using.

Binaries are pinned to the baseline CPU of their architecture, so one build
runs on every machine of that architecture.

## Build options

You can customize the build using `lib.${system}.mkRoc`:

```nix
roc-nix.lib.${system}.mkRoc {
  optimize = "ReleaseSafe";
  patches = [ ./nix/roc-pr-12345.patch ];
}
```

If you just want `ReleaseFast` using the `roc-src` you pinned you can use
`packages.roc` (which is just `mkRoc { }`). For `ReleaseSafe` you can use
`packages.roc-safe`.

Repos passing the same arguments share the same compiler build. Each build
reports its own version, e.g. `release-fast-53fa9b7`, and since Roc names its
on-disk cache after that string, projects on different revisions never share
cached artifacts.

| Argument | Default | What it does |
| --- | --- | --- |
| `rocFlake` | the `roc-src` input | A whole other Roc checkout to build, inputs and all. |
| `src` | `rocFlake.sourceInfo` | Just the source tree, keeping `rocFlake`'s toolchain. |
| `optimize` | `"ReleaseFast"` | Zig optimize mode. |
| `cpu` | `"baseline"` | Instruction set floor, passed as `-Dcpu`. |
| `patches` | `[ ]` | Patch files, as paths from the calling flake. |
| `nixpkgs` | `rocFlake.inputs.nixpkgs` | The nixpkgs the compiler is built against. |
| `zig` | from `build.zig.zon` | The Zig package to build with. |

`nixpkgs`, `zig` and `cpu` are worth passing only when you want a compiler
built against something other than what its own revision asks for.

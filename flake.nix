{
  description = "Torture test flake for buildbot-nix UI: many builds with varied outcomes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Salt forces fresh derivations on every commit so repeated
          # pushes schedule real builds instead of cache hits.
          salt = if self ? rev then self.rev else "dirty";

          # Quick builds that always succeed; bulk of the 2500 attrs per
          # system to stress the scheduler and UI, not the builders.
          fast = builtins.listToAttrs (
            map (i: {
              name = "fast-${toString i}";
              value = pkgs.runCommand "fast-${toString i}" { inherit salt; } ''
                echo "fast build ${toString i} $salt" > $out
              '';
            }) (nixpkgs.lib.range 1 2467)
          );

          # Builds that sleep to simulate long-running jobs
          slow = builtins.listToAttrs (
            map (i: {
              name = "slow-${toString i}";
              value = pkgs.runCommand "slow-${toString i}" { inherit salt; } ''
                sleep ${toString (i * 10)}
                echo done > $out
              '';
            }) (nixpkgs.lib.range 1 10)
          );

          # Builds that always fail
          fail = builtins.listToAttrs (
            map (i: {
              name = "fail-${toString i}";
              value = pkgs.runCommand "fail-${toString i}" { inherit salt; } ''
                echo "this build is supposed to fail" >&2
                exit 1
              '';
            }) (nixpkgs.lib.range 1 5)
          );

          # Builds producing huge logs to stress log rendering
          bigLog = builtins.listToAttrs (
            map (i: {
              name = "big-log-${toString i}";
              value = pkgs.runCommand "big-log-${toString i}" { inherit salt; } ''
                for n in $(seq 1 100000); do
                  echo "log line $n: lorem ipsum dolor sit amet consectetur"
                done
                echo done > $out
              '';
            }) (nixpkgs.lib.range 1 3)
          );

          # Build chains to exercise dependency scheduling
          mkChain =
            name: depth:
            let
              go =
                n: prev:
                if n > depth then
                  prev
                else
                  go (n + 1) (
                    pkgs.runCommand "${name}-link-${toString n}" { inherit prev; } ''
                      cat $prev > $out
                      echo "link ${toString n}" >> $out
                    ''
                  );
            in
            go 1 (pkgs.runCommand "${name}-root" { inherit salt; } "echo root > $out");

          chains = builtins.listToAttrs (
            map (i: {
              name = "chain-${toString i}";
              value = mkChain "chain-${toString i}" 20;
            }) (nixpkgs.lib.range 1 5)
          );

          # CPU-burning builds to occupy build slots
          burn = builtins.listToAttrs (
            map (i: {
              name = "burn-${toString i}";
              value = pkgs.runCommand "burn-${toString i}" { inherit salt; } ''
                timeout 60 sh -c 'while :; do :; done' || true
                echo done > $out
              '';
            }) (nixpkgs.lib.range 1 5)
          );

          # Non-deterministic: fails ~50% of the time (impure via $RANDOM-ish)
          flaky = builtins.listToAttrs (
            map (i: {
              name = "flaky-${toString i}";
              value = pkgs.runCommand "flaky-${toString i}" { inherit salt; } ''
                # Pseudo-random based on build start time
                if [ $(( $(date +%N | sed 's/^0*//') % 2 )) -eq 0 ]; then
                  echo "flaky failure" >&2
                  exit 1
                fi
                echo lucky > $out
              '';
            }) (nixpkgs.lib.range 1 5)
          );
        in
        fast // slow // fail // bigLog // chains // burn // flaky
      );
    };
}

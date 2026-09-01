{
  description = "Torture test flake for buildbot-nix UI: many builds with varied outcomes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixbot.url = "github:Mic92/nixbot/on-event";
  inputs.nixbot.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    {
      self,
      nixpkgs,
      nixbot,
      ...
    }:
    let
      fxPkgs = nixpkgs.legacyPackages.x86_64-linux;
      inherit (nixbot.lib.effects { pkgs = fxPkgs; }) mkEffect;
      # Effects talk a lot so the effect log viewer has something to stream.
      chatty =
        name: seconds: extra:
        mkEffect (
          {
            inherit name;
            effectScript = ''
              echo "event: ''${NIXBOT_EVENT_KIND:-push} actor=''${NIXBOT_ACTOR:-} pr=''${NIXBOT_PR_NUMBER:-}"
              if [ -n "''${NIXBOT_EVENT_JSON:-}" ]; then jq . "$NIXBOT_EVENT_JSON"; fi
              for i in $(seq 1 ${toString seconds}); do echo "${name}: step $i/${toString seconds}"; sleep 1; done
            '';
          }
          // extra
        );
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

          # Quick builds that always succeed; bulk of the 25000 attrs per
          # system (Hydra-scale: nixpkgs jobset has ~25k jobs per system)
          # to stress the scheduler and UI, not the builders.
          fast = builtins.listToAttrs (
            map (i: {
              name = "fast-${toString i}";
              value = pkgs.runCommand "fast-${toString i}" { inherit salt; } ''
                echo "fast build ${toString i} $salt" > $out
              '';
            }) (nixpkgs.lib.range 1 24967)
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

          # Multi-phase failures: real stdenv phases (patch/configure/
          # build) so the log viewer has phase dividers to render, then a
          # failing buildPhase. "long" stays under the viewer's render cap.
          phased = {
            this-will-fail = pkgs.stdenv.mkDerivation {
              name = "this-will-fail";
              inherit salt;
              dontUnpack = true;
              buildPhase = ''
                echo "this is a phased test failure"
                echo "error: intentional failure in buildPhase" 1>&2
                exit 1
              '';
              installPhase = "true";
            };
            this-will-fail-long = pkgs.stdenv.mkDerivation {
              name = "this-will-fail-long";
              inherit salt;
              dontUnpack = true;
              configurePhase = ''
                runHook preConfigure
                for i in $(seq 1 1500); do echo "configure: step $i of 1500"; done
                runHook postConfigure
              '';
              buildPhase = ''
                runHook preBuild
                for i in $(seq 1 3000); do echo "build: compiling object $i of 3000"; done
                echo "error: intentional failure after a long build log" 1>&2
                exit 1
              '';
              installPhase = "true";
            };
          };

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

          # Builds that emit log lines steadily over minutes so the live
          # log view has to stream, tail and lazy-load while running.
          streamingLog = builtins.listToAttrs (
            map (i: {
              name = "streaming-log-${toString i}";
              value = pkgs.stdenv.mkDerivation {
                name = "streaming-log-${toString i}";
                inherit salt;
                dontUnpack = true;
                configurePhase = ''
                  runHook preConfigure
                  for n in $(seq 1 60); do
                    echo "checking for feature $n... yes"
                    sleep 0.1
                  done
                  runHook postConfigure
                '';
                # ~50 lines/s for i minutes, with a 2000-line burst every
                # 300 steps to mix trickle and flood.
                buildPhase = ''
                  runHook preBuild
                  total=$(( ${toString i} * 5 * 60 ))
                  for s in $(seq 1 $total); do
                    for k in $(seq 1 10); do
                      echo "[$s/$total] CC object_''${s}_''${k}.o"
                    done
                    if [ $(( s % 60 )) -eq 0 ]; then
                      for k in $(seq 1 2000); do
                        echo "warning: burst $s line $k: unused variable 'x' [-Wunused-variable]" >&2
                      done
                    fi
                    sleep 0.2
                  done
                  runHook postBuild
                '';
                installPhase = "echo done > $out";
              };
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
        # Small green set so PR builds succeed and event effects fire.
        # Full torture: fast // slow // fail // phased // bigLog // streamingLog // chains // burn // flaky
        {
          inherit (fast) fast-1 fast-2 fast-3;
          inherit (chains) chain-1;
        }
      );

      herculesCI =
        { ... }:
        {
          onPush.default.outputs.effects = {
            deploy = chatty "deploy" 30 { lock = "deploy"; };
            # Runs after deploy, exercising `after` hold-back.
            smoke = chatty "smoke" 5 {
              after = [
                [
                  "default"
                  "deploy"
                ]
              ];
            };
            broken = mkEffect {
              name = "broken";
              effectScript = ''
                echo "about to fail" >&2
                exit 1
              '';
            };
          };

          onEvent = {
            # PR build went green: comment, share the deploy lock.
            pull_request = {
              plan = chatty "plan" 10 {
                when.permission = "write";
                lock = "deploy";
                checkout = true;
                inputs = [ fxPkgs.git ];
                effectScript = ''
                  cd "$NIXBOT_EFFECT_CHECKOUT"
                  {
                    echo "### plan for $(git rev-parse --short HEAD)"
                    echo
                    echo '```'
                    git log --oneline -5
                    echo '```'
                  } | nixbot-pr-comment --replace-marker plan
                '';
              };
              needs-label = chatty "needs-label" 1 { when.labels = [ "preview" ]; };
            };
            comment = {
              ping = mkEffect {
                name = "ping";
                when.commands = [ "ping" ];
                # Deliberately broken input: the PR build must go red.
                inputs = [ (fxPkgs.runCommand "broken-input" { } "exit 1") ];
                effectScript = ''
                  nixbot-pr-comment "pong $NIXBOT_COMMAND_ARGS (from $NIXBOT_ACTOR)"
                '';
              };
              apply = chatty "apply" 20 {
                when = {
                  commands = [ "apply" ];
                  permission = "write";
                };
                lock = "deploy";
              };
            };
            pull_request_closed.teardown = chatty "teardown" 3 { lock = "preview-{pr}"; };
            build_finished = {
              always = chatty "always" 1 { };
              broke = chatty "broke" 1 { when.transition = "broke"; };
              fixed = chatty "fixed" 1 { when.transition = "fixed"; };
            };
          };
        };
    };
}

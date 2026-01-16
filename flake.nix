{
  description = "Free Attic server (fly.io + supabase + rclone to s3)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        atticConfig = import ./attic-config.nix { };
        atticConfigFile = (pkgs.formats.toml { }).generate "attic.toml" atticConfig;

        sedBin = "${pkgs.gnused}/bin/sed";
        timeoutBin = "${pkgs.coreutils}/bin/timeout";
        sleepBin = "${pkgs.coreutils}/bin/sleep";
        ncBin = "${pkgs.netcat}/bin/nc";
        rcloneBin = "${pkgs.rclone}/bin/rclone";
        atticdBin = "${pkgs.attic-server}/bin/atticd";
        shBin = "${pkgs.bash}/bin/sh";

        entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
          set -euo pipefail
          # set -x

          shutdown() {
            echo "Received SIGTERM/SIGINT, shutting down..."
            [ -n "''${ATTIC_PID:-}" ] && kill -TERM "$ATTIC_PID" && wait "$ATTIC_PID"
            [ -n "''${RCLONE_PID:-}" ] && kill -TERM "$RCLONE_PID" && wait "$RCLONE_PID"
            exit 0
          }
          trap shutdown SIGTERM SIGINT

          echo "=== Starting Attic Entrypoint ==="

          if [ -z "$ATTIC_SERVER_DATABASE_URL" ]; then echo "Error: ATTIC_SERVER_DATABASE_URL is missing"; exit 1; fi
          if [ -z "$ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64" ]; then echo "Error: ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64 is missing"; exit 1; fi

          echo "--- Starting Rclone S3 Gateway ---"
          ${rcloneBin} serve s3 remote:attic \
            --addr 127.0.0.1:9000 \
            --auth-key rcloneadmin,rcloneadmin \
            --vfs-cache-mode full \
            --vfs-cache-max-size 5G \
            --vfs-read-chunk-size 16M \
            --vfs-write-back 5s \
            --buffer-size 0M \
            --transfers 1 \
            --no-modtime \
            --onedrive-no-versions \
            --log-level INFO \
            --stats 1m \
            2>&1 | ${sedBin} -u 's/^/[RCLONE] /' &
          RCLONE_PID=$!

          echo "Waiting for Rclone..."
          ${timeoutBin} 30 ${shBin} -c "until ${ncBin} -z 127.0.0.1 9000; do ${sleepBin} 1; done"
          echo "Rclone is up."

          echo "--- Starting Attic Server ---"
          ${atticdBin} -f ${atticConfigFile} --mode api-server \
            2>&1 | ${sedBin} -u 's/^/[ATTIC]  /' &
          ATTIC_PID=$!

          wait -n $ATTIC_PID $RCLONE_PID
        '';

        dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "attic-server-fly";
          tag = "latest";

          fakeRootCommands = ''
            mkdir -p ./app
            mkdir -p ./tmp
            mkdir -p ./root/.cache/rclone
          '';

          contents = [
            entrypoint
            pkgs.attic-client
            pkgs.attic-server
            pkgs.bash
            pkgs.cacert
            pkgs.coreutils
            pkgs.gnused
            pkgs.netcat
            pkgs.rclone
          ];

          config = {
            Cmd = [ "${entrypoint}/bin/entrypoint" ];
            ExposedPorts = {
              "8080/tcp" = { };
            };
            Env = [
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "RUST_LOG=attic=info,error"
              "XDG_CACHE_HOME=/tmp"
            ];
            WorkingDir = "/app";
          };
        };

      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            attic-client
            attic-server
            flyctl
            git
            postgresql
            rclone
          ];
        };

        packages.dockerImage = dockerImage;
        packages.default = dockerImage;

        formatter = pkgs.nixfmt;
        checks = {
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt.enable = true;
              statix.enable = true;
            };
          };
        };
      }
    );
}

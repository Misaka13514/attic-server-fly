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

        inherit (pkgs) attic-server busybox rclone;
        shBin = "${busybox}/bin/sh";

        entrypoint = pkgs.writeScriptBin "entrypoint" ''
          #!${shBin}
          set -e

          shutdown() {
            echo "Received SIGTERM/SIGINT, shutting down..."
            [ -n "''${ATTIC_PID:-}" ] && kill -TERM "$ATTIC_PID"
            [ -n "''${RCLONE_PID:-}" ] && kill -TERM "$RCLONE_PID"
            wait
            exit 0
          }
          trap shutdown SIGTERM SIGINT

          echo "=== Starting Attic Entrypoint ==="

          if [ -z "$ATTIC_SERVER_DATABASE_URL" ]; then echo "Error: ATTIC_SERVER_DATABASE_URL is missing"; exit 1; fi
          if [ -z "$ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64" ]; then echo "Error: ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64 is missing"; exit 1; fi

          echo "--- Starting Rclone S3 Gateway ---"
          ${rclone}/bin/rclone serve s3 remote:attic \
            --addr 127.0.0.1:9000 \
            --auth-key rcloneadmin,rcloneadmin \
            --vfs-cache-mode full \
            --vfs-cache-max-size 2G \
            --vfs-read-chunk-size 1M \
            --vfs-write-back 5s \
            --buffer-size 0M \
            --transfers 1 \
            --checkers 1 \
            --no-modtime \
            --onedrive-no-versions \
            --log-level INFO \
            --stats 1m \
            2>&1 | ${busybox}/bin/sed 's/^/[RCLONE] /' &
          RCLONE_PID=$!

          echo "Waiting for Rclone..."
          ${busybox}/bin/timeout 30 ${shBin} -c "until ${busybox}/bin/nc -z 127.0.0.1 9000; do ${busybox}/bin/sleep 1; done"
          echo "Rclone is up."

          echo "--- Starting Attic Server ---"
          ${attic-server}/bin/atticd -f ${atticConfigFile} --mode api-server \
            2>&1 | ${busybox}/bin/sed 's/^/[ATTIC]  /' &
          ATTIC_PID=$!

          wait
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
            attic-server
            busybox
            entrypoint
            pkgs.cacert
            rclone
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
              "GOGC=20"
              "PATH=/bin:${busybox}/bin"
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

        packages = {
          inherit dockerImage;
          default = dockerImage;
          inherit (pkgs) flyctl;
        };

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

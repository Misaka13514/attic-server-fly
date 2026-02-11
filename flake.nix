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

        inherit (pkgs) attic-server busybox nginx;
        rclone = pkgs.rclone.override {
          enableCmount = false;
        };
        shBin = "${busybox}/bin/sh";

        nginxConf = pkgs.writeText "nginx.conf" ''
          user root root;
          pid /tmp/nginx.pid;
          error_log /dev/stderr warn;
          daemon off;
          worker_processes auto;

          events {
            worker_connections 1024;
          }

          http {
            include ${pkgs.nginx}/conf/mime.types;
            default_type application/octet-stream;

            set_real_ip_from 172.16.0.0/12;
            set_real_ip_from fdaa::/16;
            real_ip_header Fly-Client-IP;

            client_max_body_size 0;
            client_body_temp_path /tmp/nginx_body;
            proxy_temp_path       /tmp/nginx_proxy;
            access_log /dev/stdout;

            map $http_authorization $auth_header {
              # 1. ALLOW: Standard S3 Signature (used by Attic Server proxy & Uploads)
              "~^AWS4-HMAC-SHA256" $http_authorization;

              # 2. DENY: Everything else (Basic, Bearer, etc.)
              # This strips the conflicting user tokens so Rclone uses the URL query params.
              default "";
            }

            server {
              listen 8080;
              server_name _;

              location = /healthz {
                access_log off;
                return 200 "OK";
              }

              location / {
                if ($request_method = GET) {
                  rewrite ^/$ https://github.com/Misaka13514/attic-server-fly redirect;
                }

                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;

                proxy_set_header Content-Type $content_type;
                proxy_set_header Content-Length $content_length;

                proxy_buffering off;
                proxy_request_buffering off;
                proxy_http_version 1.1;
                proxy_set_header Connection "";
                proxy_read_timeout 600s;
                proxy_send_timeout 600s;
                send_timeout 600s;
                client_body_timeout 600s;

                proxy_pass http://127.0.0.1:8081;
              }

              location /attic-storage/ {
                proxy_set_header Authorization $auth_header;
                proxy_set_header Accept-Encoding "";
                sub_filter_types text/xml;
                sub_filter '<InitiateMultipartUpload>' '<InitiateMultipartUploadResult>';
                sub_filter '</InitiateMultipartUpload>' '</InitiateMultipartUploadResult>';
                sub_filter_once off;

                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;

                proxy_set_header Content-Type $content_type;
                proxy_set_header Content-Length $content_length;

                proxy_buffering off;
                proxy_request_buffering off;
                proxy_http_version 1.1;
                proxy_set_header Connection "";
                proxy_read_timeout 600s;
                proxy_send_timeout 600s;
                send_timeout 600s;
                client_body_timeout 600s;

                proxy_pass http://127.0.0.1:9000;
              }
            }
          }
        '';

        entrypoint = pkgs.writeScriptBin "entrypoint" ''
          #!${shBin}
          set -e

          shutdown() {
            echo "Received SIGTERM/SIGINT, shutting down..."
            [ -n "''${NGINX_PID:-}" ] && kill -TERM "$NGINX_PID"
            [ -n "''${ATTIC_PID:-}" ] && kill -TERM "$ATTIC_PID"
            [ -n "''${RCLONE_PID:-}" ] && kill -TERM "$RCLONE_PID"
            wait
            exit 0
          }
          trap shutdown SIGTERM SIGINT

          echo "=== Starting Attic Entrypoint ==="

          echo "Generating random internal S3 credentials..."
          export AWS_ACCESS_KEY_ID=$(${busybox}/bin/head -c 16 /dev/urandom | ${busybox}/bin/hexdump -v -e '1/1 "%02x"')
          export AWS_SECRET_ACCESS_KEY=$(${busybox}/bin/head -c 32 /dev/urandom | ${busybox}/bin/hexdump -v -e '1/1 "%02x"')
          export RCLONE_AUTH_KEY="\"$AWS_ACCESS_KEY_ID,$AWS_SECRET_ACCESS_KEY\""
          echo "Internal S3 credentials generated: $RCLONE_AUTH_KEY"

          if [ -z "$ATTIC_SERVER_DATABASE_URL" ]; then echo "Error: ATTIC_SERVER_DATABASE_URL is missing"; exit 1; fi
          if [ -z "$ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64" ]; then echo "Error: ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64 is missing"; exit 1; fi

          echo "--- Starting Rclone S3 Gateway (Port 9000) ---"
          ${rclone}/bin/rclone serve s3 remote:attic \
            --addr 127.0.0.1:9000 \
            --vfs-cache-mode writes \
            --vfs-cache-max-size 4G \
            --vfs-read-chunk-size 8M \
            --vfs-write-back 5s \
            --buffer-size 0M \
            --transfers 1 \
            --checkers 1 \
            --no-modtime \
            --onedrive-no-versions \
            --log-level NOTICE \
            --stats 10m \
            --stats-one-line \
            --stats-log-level NOTICE \
            2>&1 | ${busybox}/bin/awk '{ print "[RCLONE] " $0; fflush(); }' &
          RCLONE_PID=$!

          echo "Waiting for Rclone..."
          ${busybox}/bin/timeout 30 ${shBin} -c "until ${busybox}/bin/nc -z 127.0.0.1 9000; do ${busybox}/bin/sleep 1; done"
          echo "Rclone is up."

          echo "--- Starting Attic Server (Port 8081) ---"
          ${attic-server}/bin/atticd -f ${atticConfigFile} --mode api-server \
            2>&1 | ${busybox}/bin/awk '{ print "[ATTIC]  " $0; fflush(); }' &
          ATTIC_PID=$!

          echo "Waiting for Attic..."
          ${busybox}/bin/timeout 30 ${shBin} -c "until ${busybox}/bin/nc -z 127.0.0.1 8081; do ${busybox}/bin/sleep 1; done"
          echo "Attic is up."

          echo "--- Starting Nginx (Port 8080) ---"
          ${nginx}/bin/nginx -c ${nginxConf} &
          NGINX_PID=$!

          echo "All services started. Listening on 8080."
          wait
        '';

        dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "attic-server-fly";
          tag = "latest";

          fakeRootCommands = ''
            mkdir -p ./app
            mkdir -p ./tmp
            mkdir -p ./root/.cache/rclone
            mkdir -p ./var/log/nginx
            mkdir -p ./var/run
            mkdir -p ./tmp/nginx_body
            mkdir -p ./tmp/nginx_proxy
          '';

          contents = [
            attic-server
            busybox
            entrypoint
            nginx
            pkgs.cacert
            pkgs.dockerTools.fakeNss # For fly ssh console
            pkgs.tcpdump # debug
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
            nginx
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

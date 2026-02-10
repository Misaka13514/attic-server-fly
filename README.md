# Attic Server on Fly.io with Rclone (OneDrive) & Supabase

This project deploys an [Attic](https://github.com/zhaofengli/attic) binary cache server on **Fly.io**. It is designed to be a highly cost-effective solution for personal Nix caching by leveraging the free/low-cost tiers of multiple cloud providers:

- **Compute**: Fly.io Micro VM (running a single container).
- **Storage**: Microsoft OneDrive (via Rclone acting as an S3 gateway).
- **Database**: PostgreSQL hosted on **Supabase**.

## Architecture Overview

The system packages multiple processes into a single, minimal Nix-built container (`dockerTools.buildLayeredImage`). Nginx acts as the central process manager and reverse proxy, routing internal traffic between the Attic application server and the Rclone storage gateway.

A key feature of this setup is the automatic handling of S3 credentials. On container startup, an entrypoint script generates ephemeral S3 access and secret keys. These keys are passed to Rclone to secure its local S3 gateway interface, and Attic is configured to use them.

### Components

1. **Fly Edge (External):** Handles public TLS termination (Port 443) and forwards plain HTTP traffic to the container's port 8080.
2. **Nginx (Port 8080 - Internal):** The main entrypoint inside the container. It routes traffic based on URL paths and performs critical HTTP header manipulations to satisfy different authentication requirements for uploads versus downloads.
3. **Attic Server (Port 8081 - Internal):** The core Attic application.
   - **Configuration**: The `attic-config.nix` used here is modified from the official [config-template.toml](https://github.com/zhaofengli/attic/blob/main/server/src/config-template.toml).
   - **Database**: It connects to an external **Supabase PostgreSQL** instance via the `ATTIC_SERVER_DATABASE_URL` environment variable.
4. **Rclone (Port 9000 - Internal):** Runs in `serve s3` gateway mode. It translates S3 API calls into Microsoft OneDrive API calls. It is secured by the ephemeral credentials generated on startup.

### Architecture Diagram

```mermaid
graph TD
    user[User / Attic Client] -->|https:443| fly[Fly.io Edge Load Balancer]

    subgraph "Fly Machine (Single Container)"
        fly -->|http:8080| nginx[Nginx Reverse Proxy]

        note[Ephemeral S3 Keys Generated on Startup] -.-> attic
        note -.-> rclone

        nginx -->|"/(API Routes)"| attic[Attic Server :8081]
        nginx -->|"/attic-storage/ (S3 Gateway)"| rclone[Rclone S3 Gateway :9000]

        attic --"Generates Presigned URLs pointing to Nginx"--> nginx
    end

    rclone -->|encrypted| onedrive[Microsoft OneDrive API]
    attic -->|Postgres Protocol| supabase[(Supabase Database)]

    style note fill:#f9f,stroke:#333,stroke-width:2px,color:black
```

---

## Request Flow & The Authentication Solution

The most complex aspect of this setup is handling the conflicting authentication mechanisms required for S3 uploads vs. downloads when using Attic Client through a proxy.

- **The Conflict:** Attic Client sends its own `Authorization: Bearer <token>` header on almost all requests.
- For S3 **uploads (PUT)**, the client _replaces_ this header with a valid `Authorization: AWS4-HMAC-SHA256...` signature header. This must be passed through.
- For S3 **downloads (GET)**, the client uses a presigned URL (authentication via query parameters) but _still sends_ its Attic Bearer token header. Rclone receives two conflicting auth methods and fails.

- **The Solution (Nginx Map):** We use Nginx to dynamically modify the `Authorization` header based on the request method.
- If `GET`: The `Authorization` header is stripped before reaching Rclone, forcing Rclone to rely only on the valid presigned URL query parameters.
- If `PUT`/`DELETE`: The `Authorization` header (containing the necessary S3 signature) is passed through.

### Sequence Diagram: Push and Pull Operations

```mermaid
sequenceDiagram
    participant C as Attic Client
    participant N as Nginx (:8080)
    participant A as Attic Server (:8081)
    participant R as Rclone S3 (:9000)
    participant O as OneDrive

    note over C, O: === ATTIC PUSH (UPLOAD) ===
    C->>N: POST /_api/v1/upload-path (Auth: Bearer Token)
    N->>A: Proxy Request
    A-->>N: Return Upload Instructions (S3 Targets via Nginx)
    N-->>C: 200 OK

    par Streaming Upload
        C->>N: PUT /attic-storage/blob.chunk (Auth: S3 AWS4-HMAC...)
        note right of N: Nginx Action: Pass-through Auth Header for PUT
        N->>R: PUT /attic-storage/blob.chunk (Auth: S3 AWS4-HMAC...)
        R->>O: Upload Stream
        O-->>R: OK
        R-->>N: 200 OK
        N-->>C: 200 OK
    end

    C->>N: POST /_api/v1/finish-upload (Auth: Bearer Token)
    N->>A: Proxy Request
    A-->>N: 200 OK
    N-->>C: 200 OK

    note over C, O: === ATTIC PULL (DOWNLOAD) ===
    C->>N: GET /nar/xyz.narinfo (Auth: Bearer Token)
    N->>A: Proxy Request
    note right of A: Attic generates Presigned S3 URL pointing to Nginx
    A-->>N: 307 Redirect location: /attic-storage/xyz.nar?...&Signature=...
    N-->>C: 307 Redirect

    C->>N: GET /attic-storage/xyz.nar?...&Signature=... (Auth: Bearer Token)
    critical Nginx Intelligent Header Handling
        note right of N: Request method is GET.
        note right of N: Nginx strips 'Authorization: Bearer...' header to prevent Rclone conflict.
    end
    N->>R: GET /attic-storage/xyz.nar?...&Signature=... (Auth: (empty))
    note right of R: Rclone validates request using only URL Query Params.
    R->>O: Download Stream
    O-->>R: Data Stream
    R-->>N: Data Stream
    N-->>C: Data Stream
```

## Deployment & Configuration

### 1. Update Domain Name

Before deploying, ensure you update `attic-config.nix` and `fly.toml` with your actual Fly.io app name.

### 2. Set Secrets

This flake expects configuration to be passed via environment variables. Use `fly secrets set` to configure them safely.

#### Attic Configuration

- `ATTIC_SERVER_DATABASE_URL`: Connection string for the Supabase PostgreSQL database.
- `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64` (or HS256): The Base64 encoded secret key used for signing Attic authentication tokens.

#### Rclone Configuration

Rclone is configured entirely via environment variables. Since the internal remote name is hardcoded as `remote`, you must use the prefix `RCLONE_CONFIG_REMOTE_` followed by the config option (case-insensitive).

Common variables include:

- `RCLONE_CONFIG_REMOTE_TYPE` (e.g., `onedrive`)
- `RCLONE_CONFIG_REMOTE_TOKEN` (The JSON token blob)
- `RCLONE_CONFIG_REMOTE_DRIVE_ID`
- `RCLONE_CONFIG_REMOTE_CLIENT_ID` / `_SECRET`

For a full list of how to convert `rclone.conf` options to environment variables, see the [Rclone Documentation: Config File](https://rclone.org/docs/#config-file).

**Example Command:**

```bash
fly secrets set \
  ATTIC_SERVER_DATABASE_URL="postgres://..." \
  ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="..." \
  RCLONE_CONFIG_REMOTE_TYPE="onedrive" \
  RCLONE_CONFIG_REMOTE_TOKEN='{"access_token":"..."}'
```

## Administration (SSH Console)

Since the container runs multiple processes, you can use Fly.io's SSH console to access the running machine for administrative tasks, such as creating users or running garbage collection.

1. **Connect to the container:**

```bash
fly ssh console
```

2. **Run administrative commands:**
   The `atticd` binary is available in the path.

- **Garbage Collection:**

```bash
atticd -f /nix/store/...-attic.toml --mode garbage-collector-once
```

- **Generate a new token:**

```bash
atticadm -f /nix/store/...-attic.toml make-token --sub "alice" --validity "2y" --pull "*" --push "*"
```

## License

[DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE](https://www.wtfpl.net/)

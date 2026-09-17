FROM mcr.microsoft.com/devcontainers/base:trixie

ENV PATH="/opt/zig:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl xz-utils ripgrep clang libclang-rt-dev \
    python3 python3-pil djvulibre-bin libdjvulibre-dev libjpeg-turbo-progs \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Official Zig 0.16.0 archives; update hashes together with the version.
# https://ziglang.org/download/index.json
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) zig_arch=x86_64; zig_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
      arm64) zig_arch=aarch64; zig_sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
      *) exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 "https://ziglang.org/download/0.16.0/zig-${zig_arch}-linux-0.16.0.tar.xz" -o /tmp/zig.tar.xz; \
    printf '%s  /tmp/zig.tar.xz\n' "$zig_sha" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    zig version

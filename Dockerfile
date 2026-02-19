FROM crystallang/crystal:1 AS build
WORKDIR /app

# Create a non-privileged user, defaults are appuser:10001
ARG IMAGE_UID="10001"
ENV UID=$IMAGE_UID
ENV USER=appuser

RUN groupadd --gid "${UID}" "${USER}" \
  && useradd \
    --uid "${UID}" \
    --gid "${UID}" \
    --home-dir "/nonexistent" \
    --shell "/usr/sbin/nologin" \
    --no-create-home \
    "${USER}"

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Install Crystal build dependencies and pigpio client libraries.
# On Raspberry Pi OS this is usually "apt install pigpio".
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    ca-certificates \
    curl \
    git \
    libevent-dev \
    libgmp-dev \
    liblz4-dev \
    libpcre2-dev \
    libssl-dev \
    libtool \
    libunwind-dev \
    libxml2-dev \
    libyaml-dev \
    patch \
    pkg-config \
    tzdata \
    zlib1g-dev \
  && if [ "$(apt-cache policy pigpio | awk '/Candidate:/ {print $2}')" != "(none)" ]; then \
       apt-get install -y --no-install-recommends pigpio; \
     else \
       apt-get install -y --no-install-recommends libpigpiod-if-dev libpigpiod-if2-1 pigpio-tools; \
     fi \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.lock shard.lock
RUN shards install --production --ignore-crystal-version --skip-postinstall --skip-executables

# Add src
COPY ./src /app/src

# Build dynamically and collect runtime shared-library dependencies.
RUN mkdir -p /app/deps \
  && shards build --production --release --error-trace \
  && for binary in /app/bin/*; do \
       ldd "$binary" | \
         tr -s '[:blank:]' '\n' | \
         grep '^/' | \
         xargs -I % sh -c 'mkdir -p "$(dirname /app/deps%)"; cp % /app/deps%;'; \
     done

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/

# Copy the user information over
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group

# Required for networking, TLS and timezone support
COPY --from=build /etc/hosts /etc/hosts
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is your application
COPY --from=build /app/deps /
COPY --from=build /app/bin /

# Use an unprivileged user.
USER appuser:appuser

ENTRYPOINT ["/rangehood"]

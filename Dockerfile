FROM crystallang/crystal:1 AS build
WORKDIR /app

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Install Crystal build dependencies.
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

# Required for networking, TLS and timezone support
COPY --from=build /etc/hosts /etc/hosts
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /usr/share/zoneinfo/ /usr/share/zoneinfo/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# This is your application
COPY --from=build /app/deps /
COPY --from=build /app/bin /

# SPI device access is simpler as root in containerized deployments.
USER root

ENTRYPOINT ["/rangehood"]

# Node.js comes from the official image (Debian's nodejs package is the
# upstream-EOL 20.x line). bookworm-slim is the variant that still ships
# linux/arm/v7; the binary runs unchanged on the trixie-based Ruby image.
FROM node:22.23.4-bookworm-slim AS node

# Runtime libraries for the prebuilt maplibre-native Node binding
# (vendor/poster_renderer). The binary is built on Ubuntu 24.04 and links
# lib versions Debian doesn't ship (libicu74, libjpeg8) — vendor exactly
# those .so files and load them via LD_LIBRARY_PATH scoped to the renderer.
FROM ubuntu:24.04 AS mbgl_libs
# Only 64-bit targets ship the prebuilt maplibre-native binding (see the armv7
# skip below), so vendor these libs there only. On 32-bit armhf, Ubuntu 24.04's
# 64-bit time_t transition renamed libuv1/libpng16-16 to *t64, which would break
# the install for libraries armv7 never loads anyway — emit an empty /out.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
    apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libicu74 libjpeg-turbo8 libuv1 libwebp7 libpng16-16 libxext6 \
    && mkdir /out \
    && cp -a /usr/lib/*/libicu*.so* /usr/lib/*/libjpeg.so.8* /usr/lib/*/libuv.so.1* \
       /usr/lib/*/libwebp.so.7* /usr/lib/*/libsharpyuv.so* /usr/lib/*/libpng16.so.16* \
       /usr/lib/*/libXext.so.6* /out/; \
    else mkdir /out; fi

# Shared by the build and runtime stages so both agree on paths and settings.
FROM ruby:4.0.9-slim AS base

ARG RAILS_ENV=production

ENV APP_PATH=/var/app
ENV BUNDLE_PATH=/usr/local/bundle/gems
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_PORT=3000

WORKDIR $APP_PATH

# ---------------------------------------------------------------------------
# build: compilers, -dev headers, npm and git live here and never reach the
# final image. Produces the installed gems and the precompiled assets.
# ---------------------------------------------------------------------------
FROM base AS build

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libpq-dev \
    libxml2-dev \
    libxslt-dev \
    libyaml-dev \
    zlib1g-dev \
    libgeos-dev libgeos++-dev \
    cmake \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY ../Gemfile ../Gemfile.lock ../.ruby-version ../vendor ./

# tzf2 ships no prebuilt gem for 32-bit ARM, so armv7 compiles it from
# source; rb-sys' bindgen needs libclang for that.
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm" ]; then \
    apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libclang-dev \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# Install production gems only
RUN bundle config set --local path 'vendor/bundle' \
    && bundle config set --local without 'development test' \
    && bundle install --jobs 4 --retry 3 \
    && rm -rf vendor/bundle/ruby/*/cache/*.gem \
       vendor/bundle/ruby/*/gems/*/ext/*/.rb-sys vendor/bundle/ruby/*/gems/*/ext/*/target

COPY ../. ./

# Node deps (tailwind plugins like daisyui) are needed by assets:precompile.
# Install them here so the build does not depend on a host-side `npm install`
# having populated node_modules in the build context.
RUN npm ci --no-audit --no-fund && rm -rf ~/.npm

# Poster renderer dependencies — prebuilt maplibre-native binaries exist for
# x64/arm64 only (Node 22 = ABI 127, which the release ships). On
# armv7 the renderer is skipped; server-side poster rendering is unavailable
# there.
RUN if [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "aarch64" ]; then \
    cd vendor/poster_renderer \
    && npm ci --no-audit --no-fund \
    && rm -rf ~/.npm; \
    fi

# Precompile assets
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rake assets:precompile \
    && rm -rf node_modules tmp/cache

# Stage a pristine copy of public/ for the entrypoint to sync into the
# persistent volume at runtime. Lives under the app dir, not /tmp, so
# tmpfs-mounted /tmp cannot make the sync silently skip.
RUN cp -r public $APP_PATH/public_dist

# ---------------------------------------------------------------------------
# app-files: the application tree as the app image ships it. The renderer's
# node_modules live in the renderer image, and the test suite is not needed.
# Writable paths belong to the image's non-root user (65532, Distroless
# "nonroot"); tmp and log are also world-writable so a custom PUID works.
# There is no shell in the final image, so permissions are set here.
# ---------------------------------------------------------------------------
FROM build AS app-files

RUN rm -rf vendor/poster_renderer/node_modules spec \
    && mkdir -p tmp/pids tmp/cache tmp/sockets tmp/imports/watched log storage \
    && chown -R 65532:65532 public storage tmp log \
    && chmod -R 1777 tmp log

# ---------------------------------------------------------------------------
# runtime-libs: collects the shared libraries Ruby and the native gems link
# against, plus the entrypoint files, into /rootfs for the Distroless image.
# glibc, libstdc++, libgcc and OpenSSL come from the Distroless base instead.
# The one extra binary is coreutils' env (glibc only, not a shell): the app's
# bin/* binstubs start with `#!/usr/bin/env ruby`, so without it
# `docker exec dawarich_app bin/rails console` would fail.
# ---------------------------------------------------------------------------
FROM base AS runtime-libs

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libpq5 \
    libxml2 \
    libxslt1.1 \
    libyaml-0-2 \
    libgeos-c1t64 \
    libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build $APP_PATH/vendor/bundle $APP_PATH/vendor/bundle

# Fails the build if any library is missing, so a gem that gains a new native
# dependency cannot ship an image that crashes at boot.
RUN set -eu; \
    jemalloc="$(ls /usr/lib/*/libjemalloc.so.2)"; \
    find /usr/local/bin/ruby /usr/local/lib $APP_PATH/vendor/bundle -type f \
      \( -name ruby -o -name '*.so' -o -name '*.so.*' \) > /tmp/elf-files; \
    echo "$jemalloc" >> /tmp/elf-files; \
    xargs -a /tmp/elf-files ldd 2>/dev/null > /tmp/ldd.out || true; \
    if grep -q 'not found' /tmp/ldd.out; then grep 'not found' /tmp/ldd.out; exit 1; fi; \
    { awk '$2 == "=>" && $3 ~ /^\// { print $3 }' /tmp/ldd.out; echo "$jemalloc"; } \
      | sort -u \
      | grep -vE '/(libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|libstdc\+\+|libssl|libcrypto)\.so|/ld-linux' \
      | grep -v '^/usr/local/' \
      | while read -r lib; do \
          dir="$(readlink -f "$(dirname "$lib")")"; \
          mkdir -p "/rootfs$dir"; \
          cp -L "$lib" "/rootfs$dir/$(basename "$lib")"; \
        done; \
    mkdir -p /rootfs/etc /rootfs/usr/bin; \
    if ldd /usr/bin/env | awk '$2 == "=>" { print $1 }' | grep -vqE '^(libc|ld-linux)'; then \
      echo "/usr/bin/env links more than glibc"; exit 1; \
    fi; \
    cp /usr/bin/env /rootfs/usr/bin/env; \
    echo "$(readlink -f "$(dirname "$jemalloc")")/libjemalloc.so.2" > /rootfs/etc/ld.so.preload; \
    ldconfig && cp /etc/ld.so.cache /rootfs/etc/ld.so.cache

# One Ruby entrypoint replaces the shell scripts; the old names stay as
# symlinks so compose files that reference them keep working.
COPY --chmod=755 ./docker/entrypoint.rb /rootfs/usr/local/bin/dawarich-entrypoint
COPY --chmod=755 ./docker/healthcheck.rb /rootfs/usr/local/bin/dawarich-healthcheck
RUN for name in web-entrypoint.sh sidekiq-entrypoint.sh cloud-entrypoint.sh; do \
      ln -s dawarich-entrypoint "/rootfs/usr/local/bin/$name"; \
    done

# ---------------------------------------------------------------------------
# renderer: sidecar image for posters and achievement share images (Node,
# maplibre-native, Mesa, a virtual X display and rsvg-convert). The app image
# calls it over HTTP via RENDERER_URL. Build with --target renderer.
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS renderer

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4t64 \
    librsvg2-bin fonts-dejavu-core fonts-noto-cjk \
    libegl1 libgles2 libgbm1 libglx0 libopengl0 libx11-6 xvfb xauth \
    && (apt-get install -y --no-install-recommends mesa-libgallium 2>/dev/null || true) \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -m 1777 -p /tmp/.X11-unix

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=mbgl_libs /out /opt/mbgl-libs

# render.mjs imports the app's own poster_studio modules (see loader.mjs), so
# keep the app's directory layout.
WORKDIR /var/app
COPY --from=build /var/app/app/javascript app/javascript
COPY --from=build /var/app/vendor/poster_renderer vendor/poster_renderer

# Vendored Ubuntu libs for the maplibre-native binding; the server strips
# this for rsvg-convert.
ENV LD_LIBRARY_PATH=/opt/mbgl-libs
ENV HOME=/tmp
ENV PORT=3100

USER 65532:65532

EXPOSE 3100

ENTRYPOINT ["xvfb-run", "-a", "node", "vendor/poster_renderer/server.mjs"]

# ---------------------------------------------------------------------------
# runtime (default target): Distroless. No shell, package manager, compilers
# or coreutils; runs as the non-root user 65532. Ruby comes from the official
# image, the gems' shared libraries from runtime-libs.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/cc-debian13:nonroot AS runtime

ENV LANG=C.UTF-8
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_APP_CONFIG=/usr/local/bundle
ENV BUNDLE_SILENCE_ROOT_WARNING=1
ENV PATH=/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV APP_PATH=/var/app
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_PORT=3000
# Bundler and friends need a writable home; any PUID can write /tmp.
ENV HOME=/tmp

# Return freed pages to the OS quickly instead of holding them in the
# allocator, and cap arena count — keeps idle RSS low on small hosts.
ENV MALLOC_CONF="narenas:2,dirty_decay_ms:1000,muzzy_decay_ms:1000"

# Enable YJIT
ENV RUBY_YJIT_ENABLE=1

COPY --from=base /usr/local/bin /usr/local/bin
COPY --from=base /usr/local/lib /usr/local/lib
# The base image points BUNDLE_APP_CONFIG at /usr/local/bundle, so the
# `bundle config --local` settings (path, without) live here, not in .bundle/.
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=runtime-libs /rootfs/ /
COPY --from=app-files $APP_PATH $APP_PATH

WORKDIR $APP_PATH

USER 65532:65532

EXPOSE $RAILS_PORT

STOPSIGNAL SIGINT

ENTRYPOINT [ "bundle", "exec" ]

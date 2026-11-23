# Runtime image: the patched Darling .debs, Mesa's Vulkan drivers (RADV, lavapipe) and the
# official macOS x86_64 Julia.
#
# Needs BuildKit (for RUN --mount). Build context (see the workflow's image job):
#   debs/*.deb                  the release's packages
#   runtime-libs.sha256         from scripts/runtime-libs.sh
#   julia-<version>-mac64.tar.gz
ARG BASE=ubuntu:26.04
FROM ${BASE}

ARG JULIA_VERSION
ENV DEBIAN_FRONTEND=noninteractive

COPY runtime-libs.sha256 /etc/metaldarling/runtime-libs.sha256

# Every package but darling-cli-devenv, which conflicts with darling-gui. --force-overwrite:
# darling-gui and darling-cli-gui-common both ship CoreData.framework. The packages are
# bind-mounted, so no layer keeps a copy.
RUN --mount=type=bind,source=debs,target=/tmp/debs \
    for f in /tmp/debs/*.deb; do \
        [ "$(dpkg-deb -f "$f" Package)" = darling-cli-devenv ] || echo "$f"; \
    done > /tmp/debs.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-overwrite \
        $(cat /tmp/debs.list) \
        mesa-vulkan-drivers vulkan-tools ca-certificates xz-utils && \
    rm -rf /var/lib/apt/lists/* /tmp/debs.list && \
    sha256sum -c --quiet /etc/metaldarling/runtime-libs.sha256 && \
    dpkg-query -W -f '${Package}:${Architecture} ${Version} source ${source:Package} ${source:Version}\n' \
        > /etc/metaldarling/packages.txt

# /usr/libexec/darling is the lower layer of every Darling prefix, so this shows up inside
# Darling as /opt/julia-<version>. ADD unpacks the tarball without keeping a copy in a layer.
ADD julia-${JULIA_VERSION}-mac64.tar.gz /usr/libexec/darling/opt/
RUN test -x /usr/libexec/darling/opt/julia-${JULIA_VERSION}/bin/julia
ENV DARLING_JULIA=/opt/julia-${JULIA_VERSION}/bin/julia

# keep this in sync with aurora or else you will not get any updates
ARG FEDORA_VERSION=44
ARG AURORA_TAG=stable
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx

FROM scratch AS ctx
COPY build_files /

# we need this for additional common kmods like v4l2loopback and xone
# you can omit this and get the kernel-rpms from the akmods-zfs image instead
FROM ghcr.io/ublue-os/akmods:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods

# If this breaks because there is a new major kernel release and zfs isn't
# available yet for that kernel then congratulations you found out why Aurora
# dropped it. to pin replace with something like
# ghcr.io/ublue-os/akmods-zfs:coreos-stable-43-6.18.13-200.fc43.x86_64
# https://github.com/ublue-os/akmods/pkgs/container/akmods-zfs
# if you have to pin keep this in sync with the above if you use it
FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods-zfs

FROM ${AURORA_IMAGE}:${AURORA_TAG} AS base
ARG FEDORA_VERSION
ARG AURORA_IMAGE
ARG AURORA_TAG

RUN test "$(rpm -E %fedora)" = "${FEDORA_VERSION}" || \
    { echo "ERROR: ${AURORA_IMAGE}:${AURORA_TAG} is Fedora $(rpm -E %fedora), but FEDORA_VERSION=${FEDORA_VERSION}"; exit 1; }

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=bind,from=akmods,src=/kernel-rpms,dst=/tmp/kernel-rpms \
    --mount=type=bind,from=akmods,src=/rpms/common,dst=/tmp/rpms/common \
    --mount=type=bind,from=akmods,src=/rpms/kmods,dst=/tmp/rpms/kmods \
    --mount=type=bind,from=akmods,src=/rpms/ublue-os,dst=/tmp/rpms/ublue-os \
    --mount=type=bind,from=akmods-zfs,src=/rpms/kmods/zfs,dst=/tmp/rpms/kmods/zfs \
    /ctx/kernel-akmods.sh && \
    /ctx/zfs.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/post-check.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint

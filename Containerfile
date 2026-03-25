# Allow build scripts to be referenced without being copied into the final image
ARG FEDORA_VERSION=43
FROM scratch AS ctx
COPY build_files /

# we need this for additional common kmods like v4l2loopback and xone
# you can omit this and get the kernel-rpms from the akmods-zfs image instead
FROM ghcr.io/ublue-os/akmods:coreos-stable-${FEDORA_VERSION} AS akmods

FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-${FEDORA_VERSION} AS akmods-zfs

# change the tag to whatever you need here
# using :latest for demonstration for now because it doesn't have ZFS/coreos-stable kernel
FROM ghcr.io/ublue-os/aurora:latest AS base

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods,src=/kernel-rpms,dst=/tmp/kernel-rpms \
    --mount=type=bind,from=akmods,src=/rpms/common,dst=/tmp/rpms/common \
    --mount=type=bind,from=akmods,src=/rpms/kmods,dst=/tmp/rpms/kmods \
    --mount=type=bind,from=akmods-zfs,src=/rpms/kmods/zfs,dst=/tmp/rpms/kmods/zfs \
    /ctx/zfs.sh

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint

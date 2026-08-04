FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git pkg-config ninja-build ca-certificates curl \
      asn1c automake bison libtool \
      libarchive-dev libboost-dev libboost-log-dev libboost-program-options-dev \
      libboost-system-dev libboost-thread-dev libcurl4-openssl-dev libglib2.0-dev \
      libostree-dev libp11-dev libsodium-dev libsqlite3-dev libssl-dev ostree \
 && rm -rf /var/lib/apt/lists/*
ARG AKTUALIZR_REF=master
# Full clone of the main repo (shallow clone has no tags, so `git describe` -> version fails);
# submodules stay shallow for speed.
RUN git clone --recursive --shallow-submodules -b ${AKTUALIZR_REF} \
      https://github.com/uptane/aktualizr.git /src
WORKDIR /src/build
RUN cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SOTA_TOOLS=OFF -DBUILD_DEB=OFF -DBUILD_TESTING=OFF \
      -DWARNING_AS_ERROR=OFF -DBUILD_OSTREE=ON .. \
 && ninja aktualizr aktualizr-info \
 && find /src/build -maxdepth 4 -type f -name aktualizr -perm -u+x -exec cp {} /usr/local/bin/ \; \
 && find /src/build -maxdepth 4 -type f -name aktualizr-info -perm -u+x -exec cp {} /usr/local/bin/ \; \
 && aktualizr --version
WORKDIR /device
ENTRYPOINT ["aktualizr"]

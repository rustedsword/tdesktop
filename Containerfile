FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Pin the sources explicitly rather than trusting whatever the base image
# ships: universe is required for most of the build-deps. amd64 host only — an
# arm64 host would need ports.ubuntu.com here.
RUN . /etc/os-release \
 && printf '%s\n' \
    'Types: deb' \
    'URIs: http://archive.ubuntu.com/ubuntu/' \
    "Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates ${VERSION_CODENAME}-security" \
    'Components: main restricted universe multiverse' \
    'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
    > /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    debhelper \
    devscripts \
    gnupg2 \
    lintian \
    software-properties-common \
    ubuntu-dev-tools \
 && rm -rf /var/lib/apt/lists/*
# ubuntu-dev-tools pulls in dput-ng, which provides the `dput` command used for
# PPA uploads. The standalone dput package conflicts with it.

# libtgowt-dev, libtde2e-dev and librnnoise-dev exist in no distribution — they
# come from our own PPA, so --test-build needs it enabled here. Launchpad's
# builders get it automatically as the archive being uploaded to.
RUN add-apt-repository -y ppa:lightofmysoul/tg \
 && rm -rf /var/lib/apt/lists/*

CMD ["bash"]

# Refreshes a released image: the Debian security updates published since it
# was built, as one layer on top of it. Everything else -- the kividb binary,
# user, entrypoint, CMD, labels -- is the released image's, unchanged.
# Used by .github/workflows/refresh-images.yml; BASE is a per-arch image by
# digest.
ARG BASE
FROM ${BASE}

USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
USER kividb

# syntax=docker/dockerfile:1.7

FROM ubuntu:25.10 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Jakarta

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        software-properties-common \
        gpg-agent \
        lsb-release \
        ca-certificates \
        wget \
        curl \
        git \
    ; \
    # Attempt to add PPAs, but don't fail if they are invalid for this arch/version
    add-apt-repository -y ppa:jcfp/ppa || true; \
    add-apt-repository -y ppa:qbittorrent-team/qbittorrent-stable || true; \
    apt-get update; \
    \
    # List of desired packages
    pkgs="build-essential libssl-dev zlib1g-dev libncurses5-dev libnss3-dev \
          libreadline-dev libffi-dev libsqlite3-dev libbz2-dev libcurl4-openssl-dev \
          libxml2-dev libxslt1-dev libjpeg-dev liblzma-dev libbluetooth-dev \
          libmagic1t64 tk-dev uuid-dev libzstd-dev ffmpeg aria2 p7zip-full \
          jq openssl bc xxd nodejs openjdk-21-jre-headless sabnzbdplus \
          qbittorrent-nox par2 unrar locales tzdata netbase unzip"; \
    \
    for pkg in $pkgs; do \
        if apt-cache show "$pkg" >/dev/null 2>&1; then \
            echo "Installing $pkg..."; \
            apt-get install -y --no-install-recommends "$pkg" || echo "Failed to install $pkg, skipping..."; \
        else \
            echo "Package $pkg not found for this architecture, skipping..."; \
        fi; \
    done; \
    \
    rm -rf /var/lib/apt/lists/*; \
    \
    locale-gen en_US.UTF-8; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV PYTHON_VERSION 3.14.2

RUN set -eux; \
        savedAptMark="$(apt-mark showmanual)"; \
        apt-get update; \
        apt-get install -y --no-install-recommends libzstd-dev || true; \
        \
        wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz"; \
        mkdir -p /usr/src/python; \
        tar --extract --directory /usr/src/python --strip-components=1 --file python.tar.xz; \
        rm python.tar.xz; \
        \
        cd /usr/src/python; \
        gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
        ./configure \
                --build="$gnuArch" \
                --enable-loadable-sqlite-extensions \
                --enable-optimizations \
                --enable-option-checking=fatal \
                --enable-shared \
                $(test "${gnuArch%%-*}" != 'riscv64' && echo '--with-lto') \
                --with-ensurepip \
        ; \
        nproc="$(nproc)"; \
        EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)"; \
        LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"; \
                arch="$(dpkg --print-architecture)"; arch="${arch##*-}"; \
                case "$arch" in \
                        amd64|arm64) \
                                EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"; \
                                ;; \
                        i386) \
                                ;; \
                        *) \
                                EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer"; \
                                ;; \
                esac; \
        make -j "$nproc" \
                "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
                "LDFLAGS=${LDFLAGS:-}" \
        ; \
        rm python; \
        make -j "$nproc" \
                "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
                "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
                python \
        ; \
        make install; \
        \
        bin="$(readlink -ve /usr/local/bin/python3)"; \
        dir="$(dirname "$bin")"; \
        mkdir -p "/usr/share/gdb/auto-load/$dir"; \
        cp -vL Tools/gdb/libpython.py "/usr/share/gdb/auto-load/$bin-gdb.py"; \
        \
        cd /; \
        rm -rf /usr/src/python; \
        \
        find /usr/local -depth \
                \( \
                        \( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
                        -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name 'libpython*.a' \) \) \
                \) -exec rm -rf '{}' + \
        ; \
        \
        ldconfig; \
        \
        apt-mark auto '.*' > /dev/null; \
        apt-mark manual $savedAptMark; \
        # Restore manual flags for packages we kept
        for pkg in $pkgs; do \
            apt-mark manual "$pkg" 2>/dev/null || true; \
        done; \
        apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
        apt-get dist-clean; \
        \
        export PYTHONDONTWRITEBYTECODE=1; \
        python3 --version; \
        pip3 --version

RUN set -eux; \
        for src in idle3 pip3 pydoc3 python3 python3-config; do \
                dst="$(echo "$src" | tr -d 3)"; \
                [ -s "/usr/local/bin/$src" ]; \
                [ ! -e "/usr/local/bin/$dst" ]; \
                ln -svT "$src" "/usr/local/bin/$dst"; \
        done

ARG TARGETARCH
ARG TARGETVARIANT

RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) \
            RCLONE_ARCH="amd64"; \
            ;; \
        arm64) \
            RCLONE_ARCH="arm64"; \
            ;; \
        arm) \
            if [ "$TARGETVARIANT" = "v7" ]; then \
                RCLONE_ARCH="arm-v7"; \
            else \
                RCLONE_ARCH="arm"; \
            fi \
            ;; \
        *) \
            RCLONE_ARCH="unknown"; \
            ;; \
    esac; \
    \
    if [ "$RCLONE_ARCH" != "unknown" ]; then \
        curl -O "https://downloads.rclone.org/rclone-current-linux-${RCLONE_ARCH}.zip"; \
        unzip "rclone-current-linux-${RCLONE_ARCH}.zip"; \
        cp rclone-*-linux-${RCLONE_ARCH}/rclone /usr/bin/; \
        chown root:root /usr/bin/rclone; \
        chmod 755 /usr/bin/rclone; \
        rm -rf rclone-*-linux-${RCLONE_ARCH} "rclone-current-linux-${RCLONE_ARCH}.zip"; \
    else \
        # Attempt to install via apt if zip not found, but don't fail if missing
        apt-get update; \
        apt-get install -y rclone || echo "Rclone not available for this arch, skipping"; \
        rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /JDownloader
RUN wget -O JDownloader.jar http://installer.jdownloader.org/JDownloader.jar \
    && chmod 777 -R /JDownloader


FROM scratch

COPY --from=builder / /

CMD ["bash"]

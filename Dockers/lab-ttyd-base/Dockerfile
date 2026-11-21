
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        net-tools \
        netcat-openbsd \
        john \
        nmap \
        vim-tiny \
        hydra \
        zip \
        unzip \
        telnet \
        ftp \
        steghide \
        traceroute \
        mariadb-client \
        libimage-exiftool-perl \
        nano \
        tshark \
        dirb \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
              /var/cache/apt/archives/* \
              /tmp/*

# ttyd: absent de Debian trixie (seulement forky/sid) -> binaire statique officiel
ADD --chmod=755 https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 /usr/local/bin/ttyd

# User yolo
RUN useradd -ms /bin/bash  -u 3022 yolo 

USER yolo
WORKDIR /home/yolo
CMD ["ttyd", "-p", "3000", "-t", "disableLeaveAlert=true", "/bin/bash"]

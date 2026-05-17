FROM debian:bookworm-slim

# Note: glibc-based. Alpine + musl + sshd privsep had a known "invalid user
# at preauth" issue that bit our two-host CI; switching to Debian sidesteps it.

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash tmux openssh-server openssh-client rsync python3 git sudo \
      iproute2 ca-certificates procps \
 && rm -rf /var/lib/apt/lists/* \
 && ssh-keygen -A \
 && useradd -m -s /bin/bash mesh \
 && echo 'mesh ALL=(root) NOPASSWD: /usr/sbin/sshd' > /etc/sudoers.d/mesh \
 && mkdir -p /run/sshd \
 && printf '%s\n' \
      'Port 22' \
      'PubkeyAuthentication yes' \
      'PasswordAuthentication no' \
      'PermitEmptyPasswords no' \
      'PermitRootLogin no' \
      'StrictModes no' \
      'LogLevel VERBOSE' \
      'AuthorizedKeysFile .ssh/authorized_keys' \
      'UsePAM yes' \
      'Subsystem sftp /usr/lib/openssh/sftp-server' \
    > /etc/ssh/sshd_config

# One keypair baked into the image — every container inherits the same key and
# the same authorized_keys, so SSH between containers works out of the box.
# CI-only convenience; do NOT publish this image.
USER mesh
WORKDIR /home/mesh
RUN ssh-keygen -t ed25519 -N '' -f /home/mesh/.ssh/id_ed25519 -q \
 && cp /home/mesh/.ssh/id_ed25519.pub /home/mesh/.ssh/authorized_keys \
 && chmod 600 /home/mesh/.ssh/authorized_keys

USER root
COPY --chown=mesh:mesh . /opt/agent-mesh
RUN chmod +x /opt/agent-mesh/ci/*.sh

USER mesh
WORKDIR /home/mesh
ENTRYPOINT ["/opt/agent-mesh/ci/entrypoint.sh"]

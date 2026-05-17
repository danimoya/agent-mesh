FROM alpine:3.20

RUN apk add --no-cache bash tmux openssh openssh-server rsync python3 git sudo coreutils \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash mesh \
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
      'UsePAM no' \
      'Subsystem sftp /usr/lib/ssh/sftp-server' \
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

# Run as mesh user with sshd started in background.
USER mesh
WORKDIR /home/mesh
ENTRYPOINT ["/opt/agent-mesh/ci/entrypoint.sh"]

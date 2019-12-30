FROM archlinux

RUN pacman -Syyu --noconfirm \
  && pacman -Scc --noconfirm \
  && rm -rf \
    /var/cache/pacman/pkg/* \
    /var/lib/pacman/sync/* \
  && pacman-key --init \
  && pacman-key --populate archlinux

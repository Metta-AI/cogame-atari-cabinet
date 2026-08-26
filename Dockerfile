# Build Docker. ONE image, TWO entrypoints: /bin/atari-cabinet (the game
# server) and /bin/atari-cabinet-player (the thin seat registrar). The policy
# set is env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED),
# which is what keeps a champion and a scripted filler byte-identical apart
# from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/cabinet
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The committed nim.cfg pins nothing but --path:src; the dependency paths are
# regenerated from THIS container's package tree (the same recipe ci.yml runs).
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  cat nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c $NimFlags --threads:on \
  --nimcache:/tmp/cabinet-nimcache \
  --out:atari-cabinet \
  src/atari_cabinet.nim && \
  nim c $NimFlags \
  --nimcache:/tmp/cabinet-player-nimcache \
  --out:atari-cabinet-player \
  src/atari_cabinet_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/cabinet
COPY --from=build /workspace/cabinet/atari-cabinet /bin/atari-cabinet
COPY --from=build /workspace/cabinet/atari-cabinet-player \
  /bin/atari-cabinet-player
COPY --from=build /workspace/cabinet/*.json ./
COPY --from=build /workspace/cabinet/data ./data
COPY --from=build /workspace/cabinet/client ./client

CMD ["/bin/atari-cabinet"]

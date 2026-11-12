# TETHERBOUND dedicated server
# Runs the exact same project headless; no export step needed.
# Keep GODOT_VERSION equal to the Godot version your players run.
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2
ENV TETHERBOUND_PORT=7777

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/* \
 && wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /tmp \
 && mv "/tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm /tmp/godot.zip

WORKDIR /app
COPY . /app

# Build the resource cache once so the first start is fast.
RUN godot --headless --path /app --import || true

EXPOSE 7777/udp
CMD ["godot", "--headless", "--path", "/app", "--", "--server"]

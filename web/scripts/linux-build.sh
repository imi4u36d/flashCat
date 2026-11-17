set -e
docker run --rm -v "$(cd "$(dirname "$0")/../.." && pwd)":/src -w /src/web ubuntu:24.04 bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl build-essential cmake pkg-config libssl-dev \
  libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev \
  libclang-dev clang xz-utils ca-certificates > /tmp/apt.log 2>&1
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /tmp/node.log 2>&1
apt-get install -y -qq nodejs > /tmp/node2.log 2>&1
npm i -g pnpm@12 > /tmp/pnpm.log 2>&1
curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal > /tmp/rustup.log 2>&1
. "$HOME/.cargo/env"
pnpm install --frozen-lockfile > /tmp/pnpm_i.log 2>&1
pnpm build > /tmp/web_build.log 2>&1
pnpm tauri build > /tmp/tauri_build.log 2>&1
ls -la src-tauri/target/release/bundle/deb src-tauri/target/release/bundle/appimage 2>/dev/null
'
echo LINUX_BUILD_EXIT=$?

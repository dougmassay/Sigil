#!/bin/bash -e

# This script is for building AppImage
# Please run this script in docker image: ubuntu:20.04
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build ubuntu:20.04 /build/.github/workflows/build_appimage.sh
# If you need keep store build cache in docker volume, just like:
#   $ docker volume create sigil-cache
#   $ docker run --rm -v `git rev-parse --show-toplevel`:/build -v sigil-cache:/var/cache/apt -v sigil-cache:/usr/src ubuntu:20.04 /build/.github/workflows/build_appimage.sh
# Artifacts will copy to the same directory.

set -o pipefail

export PYTHON_VER="3.13.2"
# match qt version E.g 6.8.2, 6.8.3
export QT_MAJOR_VER="6.8"
export QT_VER="6.8.2"
export LC_ALL="C.UTF-8"
export DEBIAN_FRONTEND=noninteractive
export PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig
SELF_DIR="$(dirname "$(readlink -f "${0}")")"

retry() {
  # max retry 5 times
  try=5
  # sleep 1 min every retry
  sleep_time=60
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

# join array to string. E.g join_by ',' "${arr[@]}"
join_by() {
  local separator="$1"
  shift
  local first="$1"
  shift
  printf "%s" "$first" "${@/#/$separator}"
}

prepare_baseenv() {
  rm -f /etc/apt/sources.list.d/*.list*

  # keep debs in container for store cache in docker volume
  rm -f /etc/apt/apt.conf.d/*
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
  echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

  # Since cmake 3.23.0 CMAKE_INSTALL_LIBDIR will force set to lib/<multiarch-tuple> on Debian
  echo '/usr/local/lib/x86_64-linux-gnu' >/etc/ld.so.conf.d/x86_64-linux-gnu-local.conf
  echo '/usr/local/lib64' >/etc/ld.so.conf.d/lib64-local.conf

  retry apt update
  retry apt install -y software-properties-common apt-transport-https
  # retry apt-add-repository -yn ppa:savoury1/backports
  retry apt-add-repository -yn ppa:savoury1/gcc-11

  retry apt update
  retry apt install -y \
    make \
    build-essential \
    lld \
    curl \
    desktop-file-utils \
    g++-11 \
    git \
    libbrotli-dev \
    libbz2-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libgdbm-dev \
    libgl1-mesa-dev \
    libgtk-3-dev \
    libicu-dev \
    liblzma-dev \
    libncursesw5-dev \
    libreadline-dev \
    libsqlite3-dev \
    libssl-dev \
    libwayland-dev \
    libwayland-egl-backend-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxcb1-dev \
    libxcb1-dev \
    libxcb-cursor-dev \
    libxcb-glx0-dev \
    libxcb-icccm4-dev \
    libxcb-image0-dev \
    libxcb-keysyms1-dev \
    libxcb-randr0-dev \
    libxcb-render-util0-dev \
    libxcb-shape0-dev \
    libxcb-shm0-dev \
    libxcb-sync-dev \
    libxcb-util-dev \
    libxcb-xfixes0-dev \
    libxcb-xinerama0-dev \
    libxcb-xkb-dev \
    libxext-dev \
    libxfixes-dev \
    libxi-dev \
    libxkbcommon-dev \
    libxkbcommon-x11-dev \
    libxrender-dev \
    libzstd-dev \
    pkg-config \
    python3-tk \
    tk-dev \
    unzip \
    zip \
    zlib1g-dev \
    zsync

  update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 100
  update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 100

  apt autoremove --purge -y
  # strip all compiled files by default
  export CFLAGS='-s'
  export CXXFLAGS='-s'
  # Force refresh ld.so.cache
  ldconfig
}

prepare_buildenv() {
  # install cmake and ninja-build
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry curl -ksSL --compressed https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd /usr/src
      cmake_sha256="$(retry curl -ksSL --compressed "${cmake_sha256_url}" \| grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz")"
      if ! echo "${cmake_sha256}" | sha256sum -c; then
        rm -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry curl -kLo "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "/usr/src/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry curl -ksSL --compressed https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ ! -f "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok" ]; then
      rm -f "/usr/src/ninja-${ninja_ver}-linux.zip"
      retry curl -kLC- -o "/usr/src/ninja-${ninja_ver}-linux.zip" "${ninja_binary_url}"
      touch "/usr/src/ninja-${ninja_ver}-linux.zip.download_ok"
    fi
    unzip -d /usr/local/bin "/usr/src/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_python() {
  python_url="https://www.python.org/ftp/python/${PYTHON_VER}/Python-${PYTHON_VER}.tar.xz"
  echo "Python version: ${PYTHON_VER}"
  mkdir -p "/usr/src/python3-${PYTHON_VER}/"
  if [ ! -f "/usr/src/python3-${PYTHON_VER}/.unpack_ok" ]; then
    retry curl -kSL "${python_url}" \| tar Jxf - -C "/usr/src/python3-${PYTHON_VER}/" --strip-components 1
    touch "/usr/src/python3-${PYTHON_VER}/.unpack_ok"
  fi
  cd "/usr/src/python3-${PYTHON_VER}"
  ./configure --enable-shared --enable-optimizations --enable-loadable-sqlite-extensions
  make -j$(nproc)
  make DESTDIR=/tmp/stage install
  cd /tmp/stage
  zip -r "${SELF_DIR}/python${PYTHON_VER}.zip" .
  ldconfig
}

prepare_ssl() {
  openssl_filename="$(retry curl -ksSL --compressed https://www.openssl.org/source/ \| grep -o "'>openssl-3\(\.[0-9]*\)*tar.gz<'" \| grep -o "'[^>]*.tar.gz'" \| head -1)"
  openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
  echo "openssl version: ${openssl_ver}"
  openssl_latest_url="https://github.com/openssl/openssl/archive/refs/tags/${openssl_filename}"
  mkdir -p "/usr/src/openssl-${openssl_ver}/"
  if [ ! -f "/usr/src/openssl-${openssl_ver}/.unpack_ok" ]; then
    retry curl -kSL "${openssl_latest_url}" \| tar zxf - -C "/usr/src/openssl-${openssl_ver}/" --strip-components 1
    touch "/usr/src/openssl-${openssl_ver}/.unpack_ok"
  fi
  cd "/usr/src/openssl-${openssl_ver}"
  ./Configure no-tests --openssldir=/etc/ssl
  make -j$(nproc)
  make install_sw
  ldconfig
}

prepare_qt() {
  # install qt
  #qt_major_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  #qt_ver="$(retry curl -ksSL --compressed https://download.qt.io/official_releases/qt/${qt_major_ver}/ \| sed -nr "'s@.*href=\"([0-9]+(\.[0-9]+)*)/\".*@\1@p'" \| grep \"^${QT_VER_PREFIX}\" \| head -1)"
  echo "Using qt version: ${QT_VER}"
  mkdir -p "/usr/src/qtbase-${QT_VER}" \
    "/usr/src/qttools-${QT_VER}" \
    "/usr/src/qtsvg-${QT_VER}" \
    "/usr/src/qtwayland-${QT_VER}"
  if [ ! -f "/usr/src/qtbase-${QT_VER}/.unpack_ok" ]; then
    qtbase_url="https://download.qt.io/official_releases/qt/${QT_MAJOR_VER}/${QT_VER}/submodules/qtbase-everywhere-src-${QT_VER}.tar.xz"
    retry curl -kSL --compressed "${qtbase_url}" \| tar Jxf - -C "/usr/src/qtbase-${QT_VER}" --strip-components 1
    touch "/usr/src/qtbase-${QT_VER}/.unpack_ok"
  fi
  cd "/usr/src/qtbase-${QT_VER}"
  rm -fr CMakeCache.txt CMakeFiles
  ./configure \
    -linker lld \
    -release \
    -optimize-size \
    -openssl-runtime \
    -no-directfb \
    -no-linuxfb \
    -no-eglfs \
    -no-feature-testlib \
    -no-feature-vnc \
    -feature-optimize_full \
    -nomake examples \
    -nomake tests
  echo "========================================================"
  echo "Qt configuration:"
  cat config.summary
  cmake --build . --parallel
  cmake --install .
  export QT_BASE_DIR="$(ls -rd /usr/local/Qt-* | head -1)"
  export LD_LIBRARY_PATH="${QT_BASE_DIR}/lib:${LD_LIBRARY_PATH}"
  export PATH="${QT_BASE_DIR}/bin:${PATH}"
  if [ ! -f "/usr/src/qtsvg-${QT_VER}/.unpack_ok" ]; then
    qtsvg_url="https://download.qt.io/official_releases/qt/${QT_MAJOR_VER}/${QT_VER}/submodules/qtsvg-everywhere-src-{$QT_VER}.tar.xz"
    retry curl -kSL --compressed "${qtsvg_url}" \| tar Jxf - -C "/usr/src/qtsvg-${QT_VER}" --strip-components 1
    touch "/usr/src/qtsvg-${QT_VER}/.unpack_ok"
  fi
  cd "/usr/src/qtsvg-${QT_VER}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cmake --build . --parallel
  cmake --install .
  if [ ! -f "/usr/src/qttools-${QT_VER}/.unpack_ok" ]; then
    qttools_url="https://download.qt.io/official_releases/qt/${QT_MAJOR_VER}/${QT_VER}/submodules/qttools-everywhere-src-${QT_VER}.tar.xz"
    retry curl -kSL --compressed "${qttools_url}" \| tar Jxf - -C "/usr/src/qttools-${QT_VER}" --strip-components 1
    touch "/usr/src/qttools-${QT_VER}/.unpack_ok"
  fi
  cd "/usr/src/qttools-${QT_VER}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cat config.summary
  cmake --build . --parallel
  cmake --install .

  # Remove qt-wayland until next release: https://bugreports.qt.io/browse/QTBUG-104318
  # qt-wayland
  if [ ! -f "/usr/src/qtwayland-${qt_ver}/.unpack_ok" ]; then
    qtwayland_url="https://download.qt.io/official_releases/qt/${QT_MAJOR_VER}/${QT_VER}/submodules/qtwayland-everywhere-src-${QT_VER}.tar.xz"
    retry curl -kSL --compressed "${qtwayland_url}" \| tar Jxf - -C "/usr/src/qtwayland-${QT_VER}" --strip-components 1
    touch "/usr/src/qtwayland-${QT_VER}/.unpack_ok"
  fi
  cd "/usr/src/qtwayland-${QT_VER}"
  rm -fr CMakeCache.txt
  "${QT_BASE_DIR}/bin/qt-configure-module" .
  cat config.summary
  cmake --build . --parallel
  cmake --install .
}


build_sigil() {
  # build qbittorrent
  cd "${SELF_DIR}/../../"
  rm -fr build/CMakeCache.txt
  cmake \
    -B build \
    -G "Ninja" \
    -DCMAKE_PREFIX_PATH="${QT_BASE_DIR}/lib/cmake/" \
    -DPKG_SYSTEM_PYTHON=1 \
    -DAPPIMAGE_BUILD=1 \
    -DCMAKE_BUILD_TYPE=Release \
    -DINSTALL_HICOLOR_ICONS=1 \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_SKIP_RPATH=ON
  cmake --build build

  cmake --install build
}

build_appimage() {
  # build AppImage
  linuxdeploy_qt_download_url="https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage"
  [ -x "/tmp/linuxdeployqt-continuous-x86_64.AppImage" ] || retry curl -kSLC- -o /tmp/linuxdeployqt-continuous-x86_64.AppImage "${linuxdeploy_qt_download_url}"
  chmod -v +x '/tmp/linuxdeployqt-continuous-x86_64.AppImage'
  cd "/tmp/qbee"
  ln -svf usr/share/icons/hicolor/scalable/apps/qbittorrent.svg /tmp/qbee/AppDir/
  ln -svf qbittorrent.svg /tmp/qbee/AppDir/.DirIcon
  cat >/tmp/qbee/AppDir/AppRun <<EOF
#!/bin/bash -e

this_dir="\$(readlink -f "\$(dirname "\$0")")"
export XDG_DATA_DIRS="\${this_dir}/usr/share:\${XDG_DATA_DIRS}:/usr/share:/usr/local/share"
export QT_QPA_PLATFORMTHEME=gtk3
unset QT_STYLE_OVERRIDE

# Force set openssl config directory to an invalid directory to fallback to use default openssl config.
# This can avoid some distributions (mainly Fedora) having some strange patches or configurations
# for openssl that make the libssl in Appimage bundle unavailable.
export OPENSSL_CONF="\${this_dir}"

# Find the system certificates location
# https://gitlab.com/probono/platformissues/blob/master/README.md#certificates
possible_locations=(
  "/etc/ssl/certs/ca-certificates.crt"                # Debian/Ubuntu/Gentoo etc.
  "/etc/pki/tls/certs/ca-bundle.crt"                  # Fedora/RHEL
  "/etc/ssl/ca-bundle.pem"                            # OpenSUSE
  "/etc/pki/tls/cacert.pem"                           # OpenELEC
  "/etc/ssl/certs"                                    # SLES10/SLES11, https://golang.org/issue/12139
  "/usr/share/ca-certs/.prebuilt-store/"              # Clear Linux OS; https://github.com/knapsu/plex-media-player-appimage/issues/17#issuecomment-437710032
  "/system/etc/security/cacerts"                      # Android
  "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem" # CentOS/RHEL 7
  "/etc/ssl/cert.pem"                                 # Alpine Linux
)

for location in "\${possible_locations[@]}"; do
  if [ -r "\${location}" ]; then
    export SSL_CERT_FILE="\${location}"
    break
  fi
done

exec "\${this_dir}/usr/bin/qbittorrent" "\$@"
EOF
  chmod 755 -v /tmp/qbee/AppDir/AppRun

  extra_plugins=(
    iconengines
    imageformats
    platforminputcontexts
    platforms
    platformthemes
    sqldrivers
    styles
    tls
    wayland-decoration-client
    wayland-graphics-integration-client
    wayland-shell-integration
  )
  exclude_libs=(
    libatk-1.0.so.0
    libatk-bridge-2.0.so.0
    libatspi.so.0
    libblkid.so.1
    libboost_filesystem.so.1.58.0
    libboost_system.so.1.58.0
    libboost_system.so.1.65.1
    libbsd.so.0
    libcairo-gobject.so.2
    libcairo.so.2
    libcapnp-0.5.3.so
    libcapnp-0.6.1.so
    libdatrie.so.1
    libdbus-1.so.3
    libepoxy.so.0
    libffi.so.6
    libgcrypt.so.20
    libgdk-3.so.0
    libgdk_pixbuf-2.0.so.0
    libgdk-x11-2.0.so.0
    libgio-2.0.so.0
    libglib-2.0.so.0
    libgmodule-2.0.so.0
    libgobject-2.0.so.0
    libgraphite2.so.3
    libgtk-3.so.0
    libgtk-x11-2.0.so.0
    libkj-0.5.3.so
    libkj-0.6.1.so
    liblz4.so.1
    liblzma.so.5
    libmirclient.so.9
    libmircommon.so.7
    libmircore.so.1
    libmirprotobuf.so.3
    libmount.so.1
    libpango-1.0.so.0
    libpangocairo-1.0.so.0
    libpangoft2-1.0.so.0
    libpcre2-8.so.0
    libpcre.so.3
    libpixman-1.so.0
    libprotobuf-lite.so.9
    libselinux.so.1
    libsystemd.so.0
    libthai.so.0
    libwayland-client.so.0
    libwayland-cursor.so.0
    libwayland-egl.so.1
    libwayland-server.so.0
    libX11-xcb.so.1
    libXau.so.6
    libxcb-cursor.so.0
    libxcb-glx.so.0
    libxcb-icccm.so.4
    libxcb-image.so.0
    libxcb-keysyms.so.1
    libxcb-randr.so.0
    libxcb-render.so.0
    libxcb-render-util.so.0
    libxcb-shape.so.0
    libxcb-shm.so.0
    libxcb-sync.so.1
    libxcb-util.so.1
    libxcb-xfixes.so.0
    libxcb-xkb.so.1
    libXcomposite.so.1
    libXcursor.so.1
    libXdamage.so.1
    libXdmcp.so.6
    libXext.so.6
    libXfixes.so.3
    libXinerama.so.1
    libXi.so.6
    libxkbcommon.so.0
    libxkbcommon-x11.so.0
    libXrandr.so.2
    libXrender.so.1
  )

  # fix AppImage output file name, maybe not needed anymore since appimagetool lets you set output file name?
  sed -i 's/Name=qBittorrent.*/Name=qBittorrent-Enhanced-Edition/;/SingleMainWindow/d' /tmp/qbee/AppDir/usr/share/applications/*.desktop

  export APPIMAGE_EXTRACT_AND_RUN=1
  /tmp/linuxdeployqt-continuous-x86_64.AppImage \
    /tmp/qbee/AppDir/usr/share/applications/*.desktop \
    -always-overwrite \
    -bundle-non-qt-libs \
    -no-copy-copyright-files \
    -extra-plugins="$(join_by ',' "${extra_plugins[@]}")" \
    -exclude-libs="$(join_by ',' "${exclude_libs[@]}")"

  # Workaround to use the static runtime with the appimage
  ARCH="$(arch)"
  appimagetool_download_url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
  [ -x "/tmp/appimagetool-${ARCH}.AppImage" ] || retry curl -kSLC- -o /tmp/appimagetool-"${ARCH}".AppImage "${appimagetool_download_url}"
  chmod -v +x "/tmp/appimagetool-${ARCH}.AppImage"
  /tmp/appimagetool-"${ARCH}".AppImage --comp zstd --mksquashfs-opt -Xcompression-level --mksquashfs-opt 20 \
    -u "zsync|https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/qBittorrent-Enhanced-Edition-${ARCH}.AppImage.zsync" \
    /tmp/qbee/AppDir /tmp/qbee/qBittorrent-Enhanced-Edition-"${ARCH}".AppImage
}

move_artifacts() {
  # output file name should be qBittorrent-Enhanced-Edition-x86_64.AppImage
  cp -fv /tmp/qbee/qBittorrent-Enhanced-Edition*.AppImage* "${SELF_DIR}/"
}

prepare_baseenv
prepare_buildenv
# compile openssl 3.x. qBittorrent >= 5.0 required openssl 3.x
#prepare_ssl
prepare_python
#prepare_qt
#preapare_libboost
#prepare_libtorrent
#build_sigil
#build_appimage
#move_artifacts

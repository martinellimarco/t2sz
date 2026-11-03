# Contributor: Marco Martinelli <marco+t2sz@13byte.com>
# Maintainer: Marco Martinelli <marco+t2sz@13byte.com>
pkgname=t2sz
pkgver=1.2.5
pkgrel=0
pkgdesc="t2sz compresses a file into a seekable zstd with special handling for tar archives."
url="https://github.com/martinellimarco/t2sz"
arch="all"
license="GPL-3.0-or-later"
makedepends="cmake samurai zstd-dev"
checkdepends="bash grep tar zstd"
source="$pkgname-$pkgver.tar.gz::https://github.com/martinellimarco/t2sz/archive/refs/tags/v$pkgver.tar.gz"
builddir="$srcdir/"

build() {
        if [ "$CBUILD" != "$CHOST" ]; then
                CMAKE_CROSSOPTS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_HOST_SYSTEM_NAME=Linux"
        fi

        cd "$srcdir/$pkgname-$pkgver"

        cmake -B build \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DCMAKE_INSTALL_LIBDIR=lib \
                -DBUILD_SHARED_LIBS=True \
                -DCMAKE_BUILD_TYPE=None \
                $CMAKE_CROSSOPTS .

        cmake --build build
}

check() {
        cd "$srcdir/$pkgname-$pkgver"
        cmake -B build_test -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
        cmake --build build_test
        ctest --test-dir build_test --output-on-failure
}

package() {
        cd "$srcdir/$pkgname-$pkgver"
        DESTDIR="$pkgdir" cmake --install build
}

sha512sums="
e2aa383d59c3b510e0f53e22a3a9941710472f1840859295a5d4ee181d8486a83029cfa1ef345d9bf6e44841d5cb16f9ffff5d00fd8a2ac4067d4f139cd2adf7  t2sz-1.2.5.tar.gz
"

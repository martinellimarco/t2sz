# Contributor: Marco Martinelli <marco+t2sz@13byte.com>
# Maintainer: Marco Martinelli <marco+t2sz@13byte.com>
pkgname=t2sz
pkgver=1.1.2
pkgrel=0
pkgdesc="t2sz compress a file into a seekable zstd with special handling for tar archives."
url="https://github.com/martinellimarco/t2sz"
arch="all"
license="GPL-3.0-or-later"
depends="zstd-dev"
makedepends="git cmake"
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
        :
}

package() {
        cd "$srcdir/$pkgname-$pkgver/build"
        make DESTDIR="$pkgdir/" install
}

sha512sums=""

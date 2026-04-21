# Maintainer: fnrhombus <fnrhombus@users.noreply.github.com>
pkgname=azure-ddns
pkgver=0.1.0
pkgrel=1
pkgdesc='Dynamic DNS updater for Azure DNS (A + AAAA records)'
arch=('any')
url='https://github.com/fnrhombus/azure-ddns'
license=('MIT')
depends=('bash' 'curl' 'jq' 'systemd')
optdepends=(
    'networkmanager: update-on-link-up dispatcher hook'
)
backup=('etc/azure-ddns.env')
source=("$pkgname-$pkgver.tar.gz::https://github.com/fnrhombus/$pkgname/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
    cd "$pkgname-$pkgver"

    install -Dm755 bin/azure-ddns                "$pkgdir/usr/bin/azure-ddns"
    install -Dm644 systemd/azure-ddns.service    "$pkgdir/usr/lib/systemd/system/azure-ddns.service"
    install -Dm644 systemd/azure-ddns.timer      "$pkgdir/usr/lib/systemd/system/azure-ddns.timer"
    install -Dm755 dispatcher.d/90-azure-ddns    "$pkgdir/usr/lib/NetworkManager/dispatcher.d/90-azure-ddns"
    install -Dm600 azure-ddns.env.template       "$pkgdir/etc/azure-ddns.env"

    install -Dm644 LICENSE                       "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
    install -Dm644 README.md                     "$pkgdir/usr/share/doc/$pkgname/README.md"
}

#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "nexiliumos" > /etc/hostname

cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   nexiliumos
HOSTS

apt-get update

echo "==> Carregando lista de pacotes..."
# shellcheck source=packages.list
source /tmp/packages.list

echo "==> Instalando todos os pacotes do NexiliumOS (${#PACKAGES[@]} pacotes)..."
apt-get install -y "${PACKAGES[@]}"

echo "==> Removendo o SDDM que veio junto do KDE (usamos GDM como display manager)..."
systemctl disable sddm 2>/dev/null || true
apt-get purge -y sddm 2>/dev/null || true

echo "==> Removendo calamares-settings-debian e aplicando nossa config do Calamares..."
# Esse pacote briga com nossos arquivos em /etc/calamares (o post-install
# dele espera gerenciar settings.conf/branding sozinho). Purga ele e só
# então copia nossa config, garantindo que não sobra nada do branding
# padrão do Debian por cima.
apt-get purge -y calamares-settings-debian 2>/dev/null || true
rm -rf /etc/calamares
mkdir -p /etc/calamares
if [ -d /tmp/calamares-config ]; then
    cp -r /tmp/calamares-config/. /etc/calamares/
    rm -rf /tmp/calamares-config
else
    echo "AVISO: /tmp/calamares-config não encontrado, Calamares ficará com config incompleta." >&2
fi

echo "gdm3 shared/default-x-display-manager select gdm3" | debconf-set-selections
dpkg-reconfigure gdm3

echo "==> Gerando locales (sem isso o KDE/GDM podem crashar ao subir a sessão)..."
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(pt_BR.UTF-8 UTF-8\)/\1/' /etc/locale.gen
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
fi
if ! grep -q "^pt_BR.UTF-8 UTF-8" /etc/locale.gen; then
    echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen
fi
locale-gen
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en

echo "==> Criando atalho do instalador na área de trabalho..."
mkdir -p /etc/skel/Desktop
if [ -f /usr/share/applications/calamares.desktop ]; then
    cp /usr/share/applications/calamares.desktop /etc/skel/Desktop/calamares.desktop
    # Troca o nome exibido no ícone/menu de "Install Debian" pra
    # "Install NexiliumOS" (o pacote calamares do Debian traz esse Name=
    # hardcoded no .desktop; sobrescrevemos aqui).
    sed -i 's/^Name=.*/Name=Install NexiliumOS/' /etc/skel/Desktop/calamares.desktop
    sed -i '/^Name\[.*\]=/d' /etc/skel/Desktop/calamares.desktop
    chmod +x /etc/skel/Desktop/calamares.desktop
    # Faz o mesmo no launcher do menu de aplicativos, não só no atalho da área de trabalho
    sed -i 's/^Name=.*/Name=Install NexiliumOS/' /usr/share/applications/calamares.desktop
    sed -i '/^Name\[.*\]=/d' /usr/share/applications/calamares.desktop
fi

echo "==> Liberando o Calamares sem pedir senha (usuários do grupo sudo)..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-nexilium-calamares.rules << 'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program").indexOf("calamares") !== -1 &&
        subject.isInGroup("sudo")) {
        return polkit.Result.YES;
    }
});
POLKIT

echo "==> Criando usuário liveuser..."
useradd -m -s /bin/bash liveuser
echo "liveuser:live" | chpasswd
usermod -aG sudo,audio,video,plugdev liveuser

echo "==> Habilitando login sem senha para liveuser via PAM (grupo nopasswdlogin)..."
# IMPORTANTE: ao contrário do Ubuntu, o Debian NÃO reconhece o grupo
# "nopasswdlogin" nativamente. Sem essa regra no PAM do GDM, o AutomaticLogin
# ainda funciona para o primeiro boot, mas qualquer prompt de senha do GDM
# (troca de usuário, tela de bloqueio, etc.) continuaria pedindo senha
# mesmo com o usuário no grupo. Por isso adicionamos a regra manualmente.
groupadd -f nopasswdlogin
usermod -aG nopasswdlogin liveuser

for pamfile in gdm-password gdm-autologin; do
    if [ -f "/etc/pam.d/${pamfile}" ] && ! grep -q "pam_succeed_if.so user ingroup nopasswdlogin" "/etc/pam.d/${pamfile}"; then
        sed -i '0,/^auth/s//auth\tsufficient\tpam_succeed_if.so user ingroup nopasswdlogin\nauth/' "/etc/pam.d/${pamfile}"
    fi
done

echo "==> Configurando autologin no GDM..."
mkdir -p /etc/gdm3
cat > /etc/gdm3/daemon.conf << 'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=liveuser
WaylandEnable=true

[security]

[xdmcp]

[chooser]

[debug]
GDMCONF

echo "==> Definindo sessão padrão do liveuser (Plasma Wayland, com fallback X11)..."
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/liveuser << 'ACCOUNTS'
[User]
Session=plasma
XSession=plasmax11
SystemAccount=false
ACCOUNTS

echo "==> Habilitando serviços de boot..."
# CORREÇÃO: o pacote gdm3 no Debian/trixie não fornece mais uma unit chamada
# "gdm3.service" — a unit real chama-se "gdm.service" (gdm3.service, quando
# existe, é apenas um alias). "systemctl enable gdm3" falhava aqui com
# "Unit gdm3.service could not be found", o que abortava o build inteiro
# por causa do "set -e". Agora detectamos o nome correto da unit.
if systemctl list-unit-files | grep -q '^gdm\.service'; then
    systemctl enable gdm.service
elif systemctl list-unit-files | grep -q '^gdm3\.service'; then
    systemctl enable gdm3.service
else
    echo "AVISO: nenhuma unit do GDM encontrada para habilitar." >&2
fi

systemctl enable NetworkManager
systemctl enable accounts-daemon
systemctl enable dbus

echo "==> Identidade do sistema..."
cat > /etc/os-release << 'OSRELEASE'
NAME="NexiliumOS"
VERSION="1.0"
ID=nexiliumos
ID_LIKE=debian
PRETTY_NAME="NexiliumOS 1.0"
HOME_URL="https://github.com/zanfss0/NexiliumOS"
OSRELEASE

echo "==> Garantindo sources.list correto no live..."
cat > /etc/apt/sources.list << 'SOURCES'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main
deb http://deb.debian.org/debian trixie-updates main
SOURCES

echo "==> Instalando VirtualBox Guest Additions (aceleração gráfica em VM)..."
apt-get install -y \
    virtualbox-guest-utils \
    virtualbox-guest-x11 \
    virtualbox-guest-dkms
# O virtualbox-guest-dkms compila o módulo do kernel usando linux-headers-amd64
# (já incluso em packages.sh). Isso dá aceleração 3D de verdade via VMSVGA,
# em vez de forçar renderização por software - que é o que travava o Plasma.
# Em hardware real esses pacotes simplesmente não fazem nada (o serviço só
# ativa se detectar que está rodando dentro do VirtualBox).

systemctl enable vboxadd 2>/dev/null || true
systemctl enable vboxadd-service 2>/dev/null || true
systemctl enable vboxadd-x11 2>/dev/null || true

echo "==> Forçando target gráfico..."
systemctl set-default graphical.target

echo "==> Corrigindo machine-id (essencial para dbus/logind funcionarem no live-boot)..."
rm -f /etc/machine-id
touch /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
# Deixa vazio de propósito: o live-boot/systemd gera um novo machine-id
# a cada boot da ISO. Se o arquivo não existisse (ou viesse copiado do
# host de build), dbus e systemd-logind falham silenciosamente e a
# sessão gráfica cai numa tela de erro logo após o login.

echo "==> Guardando cópia permanente da lista de pacotes no sistema..."
mkdir -p /etc/nexiliumos
cp /tmp/packages.list /etc/nexiliumos/packages.list
chmod 644 /etc/nexiliumos/packages.list

echo "==> Limpando..."
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm -f /tmp/chroot-setup.sh /tmp/packages.list

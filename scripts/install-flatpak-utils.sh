#/bin/bash

# install flakpak & GNOME Software Flatpak plugin
sudo apt update
sudo apt install -y flatpak gnome-software-plugin-flatpak

# add the Flathub repo
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# install deskflow
flatpak install -y flathub org.deskflow.deskflow

# set deskflow autostart
mkdir -p ~/.config/autostart
cp /var/lib/flatpak/exports/share/applications/org.deskflow.deskflow.desktop ~/.config/autostart

# isntall Extension Manager
flatpak install -y flathub com.mattjakeman.ExtensionManager

# install Ptyxis
flatpak install -y flathub app.devsuite.Ptyxis

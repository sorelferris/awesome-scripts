#/bin/bash

# install flakpak & GNOME Software Flatpak plugin
sudo apt update
sudo apt install flatpak
sudo apt install gnome-software-plugin-flatpak

# add the Flathub repo
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# install deskflow
flatpak install flathub org.deskflow.deskflow

# set autostart
mkdir -p ~/.config/autostart
cp /var/lib/flatpak/exports/share/applications/org.deskflow.deskflow.desktop ~/.config/autostart

# run deskflow for the first time (Deskflow will autostart at next restart)
flatpak run org.deskflow.deskflow

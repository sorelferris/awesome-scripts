#/bin/bash

# install flakpak & GNOME Software Flatpak plugin
sudo apt update
sudo apt install flatpak gnome-software-plugin-flatpak -y

# add the Flathub repo
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# install ptyxis
flatpak install flathub app.devsuite.Ptyxis

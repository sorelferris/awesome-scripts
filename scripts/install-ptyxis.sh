#/bin/bash

# install flakpak & GNOME Software Flatpak plugin
sudo apt update
sudo apt install flatpak
sudo apt install gnome-software-plugin-flatpak
# add the Flathub repo
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# install ptyxis
flatpak install flathub app.devsuite.Ptyxis

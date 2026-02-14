#/bin/bash

# install Flatpak
sudo apt install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# isntall Extension Manager
flatpak install -y flathub com.mattjakeman.ExtensionManager

# run
flatpak run com.mattjakeman.ExtensionManager
